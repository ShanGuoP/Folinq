#[cfg(windows)]
use anyhow::Context;
use anyhow::Result;
pub use document_core::{OcrResult, OcrWord};

pub fn recognize(path: &str, language: &str) -> Result<OcrResult> {
    recognize_cancellable(
        path,
        language,
        std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
    )
}

pub fn recognize_cancellable(
    path: &str,
    language: &str,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> Result<OcrResult> {
    let path = std::fs::canonicalize(path)?
        .to_string_lossy()
        .to_string()
        .trim_start_matches(r"\\?\")
        .to_string();
    let language = language.to_owned();
    std::thread::spawn(move || recognize_platform(&path, &language, &cancelled))
        .join()
        .map_err(|_| anyhow::anyhow!("OCR_WORKER_FAILED"))?
}

#[cfg(windows)]
fn recognize_platform(
    path: &str,
    language: &str,
    cancelled: &std::sync::atomic::AtomicBool,
) -> Result<OcrResult> {
    use std::sync::atomic::Ordering;
    anyhow::ensure!(!cancelled.load(Ordering::Relaxed), "TASK_CANCELLED");
    use windows::{
        Globalization::Language,
        Graphics::Imaging::{BitmapAlphaMode, BitmapDecoder, BitmapPixelFormat},
        Media::Ocr::OcrEngine,
        Storage::{FileAccessMode, StorageFile},
        Win32::System::WinRT::{RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize},
        core::HSTRING,
    };
    unsafe {
        RoInitialize(RO_INIT_MULTITHREADED)?;
    }
    struct Apartment;
    impl Drop for Apartment {
        fn drop(&mut self) {
            unsafe {
                RoUninitialize();
            }
        }
    }
    let _apartment = Apartment;
    let engine = if language.is_empty() {
        OcrEngine::TryCreateFromUserProfileLanguages()
    } else {
        OcrEngine::TryCreateFromLanguage(&Language::CreateLanguage(&HSTRING::from(language))?)
    }
    .context("OCR_LANGUAGE_UNAVAILABLE: install the requested Windows OCR language")?;
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.join()?;
    let stream = file.OpenAsync(FileAccessMode::Read)?.join()?;
    let decoder = BitmapDecoder::CreateAsync(&stream)?.join()?;
    let width = decoder.PixelWidth()?;
    let height = decoder.PixelHeight()?;
    anyhow::ensure!(
        width <= OcrEngine::MaxImageDimension()? && height <= OcrEngine::MaxImageDimension()?,
        "OCR_IMAGE_LIMIT"
    );
    let bitmap = decoder
        .GetSoftwareBitmapConvertedAsync(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore)?
        .join()?;
    let request = engine.RecognizeAsync(&bitmap)?;
    while request.Status()? == windows_future::AsyncStatus::Started {
        if cancelled.load(Ordering::Relaxed) {
            request.Cancel()?;
            anyhow::bail!("TASK_CANCELLED");
        }
        std::thread::sleep(std::time::Duration::from_millis(15));
    }
    anyhow::ensure!(!cancelled.load(Ordering::Relaxed), "TASK_CANCELLED");
    let result = request.GetResults()?;
    let mut words = Vec::new();
    for line in result.Lines()? {
        for word in line.Words()? {
            let bounds = word.BoundingRect()?;
            words.push(OcrWord {
                text: word.Text()?.to_string_lossy(),
                x: bounds.X,
                y: bounds.Y,
                width: bounds.Width,
                height: bounds.Height,
            });
        }
    }
    let result = OcrResult {
        provider: "windows_ocr".into(),
        language: engine
            .RecognizerLanguage()?
            .LanguageTag()?
            .to_string_lossy(),
        text: result.Text()?.to_string_lossy(),
        width,
        height,
        words,
    };
    bitmap.Close()?;
    stream.Close()?;
    Ok(result)
}

#[cfg(not(windows))]
fn recognize_platform(_: &str, _: &str, _: &std::sync::atomic::AtomicBool) -> Result<OcrResult> {
    anyhow::bail!("OCR_PROVIDER_UNAVAILABLE: Windows OCR is only available on Windows")
}
