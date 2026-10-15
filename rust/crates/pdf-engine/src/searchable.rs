use super::*;
use document_core::OcrResult;

pub fn add_search_layer(
    bytes: &[u8],
    page_index: u16,
    result: &OcrResult,
    font_path: Option<&str>,
) -> Result<Vec<u8>> {
    ensure!(
        !result.words.is_empty()
            && result.words.len() < 50000
            && result.width > 0
            && result.height > 0,
        "OCR_EMPTY_RESULT"
    );
    with_pdfium(|pdfium| {
        let mut document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        ensure!(document.signatures().is_empty(), "SIGNED_DOCUMENT");
        let font = if result.words.iter().all(|w| w.text.is_ascii()) {
            document.fonts_mut().helvetica()
        } else {
            let path = font_path
                .context("FONT_MISSING_GLYPH: specify a font supporting the recognized text")?;
            let data = std::fs::read(path)?;
            let face = ttf_parser::Face::parse(&data, 0).context("INVALID_FONT")?;
            ensure!(
                result
                    .words
                    .iter()
                    .flat_map(|w| w.text.chars())
                    .all(|c| c.is_whitespace() || face.glyph_index(c).is_some()),
                "FONT_MISSING_GLYPH"
            );
            document
                .fonts_mut()
                .load_true_type_from_bytes(&data, true)?
        };
        let mut page = document.pages().get(i32::from(page_index))?;
        ensure!(
            page.text()?.all().trim().is_empty(),
            "NATIVE_TEXT_PRESENT: do not add duplicate OCR layers"
        );
        let config = PdfRenderConfig::new()
            .set_fixed_width(result.width as i32)
            .set_fixed_height(result.height as i32);
        let before = page.render_with_config(&config)?.as_raw_bytes();
        for word in &result.words {
            ensure!(
                [word.x, word.y, word.width, word.height]
                    .iter()
                    .all(|v| v.is_finite())
                    && word.x >= 0.
                    && word.y >= 0.
                    && word.width > 0.
                    && word.height > 0.
                    && word.x + word.width <= result.width as f32 + 1.
                    && word.y + word.height <= result.height as f32 + 1.,
                "INVALID_OCR_BOUNDS"
            );
            if word.text.trim().is_empty() {
                continue;
            }
            let mut text =
                PdfPageTextObject::new(&document, &word.text, font, PdfPoints::new(12.))?;
            let bounds = text.bounds()?.to_rect();
            ensure!(
                bounds.width().value > 0. && bounds.height().value > 0.,
                "OCR_FONT_MAPPING_FAILED"
            );
            let point =
                |x: f32, y: f32| page.pixels_to_points(x.round() as i32, y.round() as i32, &config);
            let (x, y) = point(word.x, word.y + word.height)?;
            let (right_x, right_y) = point(word.x + word.width, word.y + word.height)?;
            let (top_x, top_y) = point(word.x, word.y)?;
            let a = (right_x.value - x.value) / bounds.width().value;
            let b = (right_y.value - y.value) / bounds.width().value;
            let c = (top_x.value - x.value) / bounds.height().value;
            let d = (top_y.value - y.value) / bounds.height().value;
            text.reset_matrix(PdfMatrix::new(
                a,
                b,
                c,
                d,
                x.value - bounds.left().value * a - bounds.bottom().value * c,
                y.value - bounds.left().value * b - bounds.bottom().value * d,
            ))?;
            text.set_render_mode(PdfPageTextRenderMode::Invisible)?;
            page.objects_mut().add_text_object(text)?;
        }
        page.regenerate_content()?;
        let output = document.save_to_bytes()?;
        drop(page);
        drop(document);
        let reopened = pdfium.load_pdf_from_byte_slice(&output, None)?;
        let page = reopened.pages().get(i32::from(page_index))?;
        let extracted = page.text()?.all();
        ensure!(
            !extracted.trim().is_empty(),
            "OCR_LAYER_TEXT_VERIFICATION_FAILED"
        );
        for word in &result.words {
            ensure!(
                word.text
                    .chars()
                    .filter(|c| !c.is_whitespace())
                    .all(|c| extracted.contains(c)),
                "OCR_LAYER_TEXT_VERIFICATION_FAILED"
            );
        }
        ensure!(
            before == page.render_with_config(&config)?.as_raw_bytes(),
            "OCR_VISUAL_CHANGED"
        );
        drop(page);
        drop(reopened);
        Ok(output)
    })
}
