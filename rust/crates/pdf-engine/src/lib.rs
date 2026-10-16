use anyhow::{Context, Result, ensure};
use document_core::{ImageObject, PageInfo, Rect, TextEditOptions, TextObject};
use pdfium_render::prelude::*;
use std::{
    path::Path,
    sync::{Mutex, OnceLock},
};

// PDFium initialization, document access and destruction all live under this lock.
// No native handle escapes an operation or crosses an FFI boundary.
static PDF_WORKER: Mutex<()> = Mutex::new(());
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();
pub mod annotations;
pub mod conversion;
pub mod editable_docx;
pub mod operations;
pub mod redaction;
pub mod searchable;

fn with_pdfium<T>(operation: impl FnOnce(&Pdfium) -> Result<T>) -> Result<T> {
    let _guard = PDF_WORKER
        .lock()
        .map_err(|_| anyhow::anyhow!("PDF_WORKER_POISONED"))?;
    if PDFIUM.get().is_none() {
        let library = std::env::var_os("PDFIUM_LIBRARY_PATH")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| {
                let deployed = std::env::current_exe()
                    .ok()
                    .and_then(|p| p.parent().map(|p| p.join("pdfium.dll")));
                if let Some(path) = deployed.filter(|p| p.exists()) {
                    return path;
                }
                if cfg!(target_os = "android") {
                    return "libpdfium.so".into();
                }
                Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../native/windows/bin/pdfium.dll")
            });
        let bindings = Pdfium::bind_to_library(&library)
            .with_context(|| format!("PDFIUM_UNAVAILABLE: {}", library.display()))?;
        let _ = PDFIUM.set(Pdfium::new(bindings));
    }
    operation(PDFIUM.get().context("PDFIUM_INITIALIZATION_FAILED")?)
}

fn rect(value: PdfRect) -> Rect {
    Rect {
        left: value.left().value,
        bottom: value.bottom().value,
        right: value.right().value,
        top: value.top().value,
    }
}

fn display_rect(
    page: &PdfPage,
    bounds: &Rect,
    config: &PdfRenderConfig,
    width: f32,
    height: f32,
) -> Result<Rect> {
    let mut xs = Vec::new();
    let mut ys = Vec::new();
    for x in [bounds.left, bounds.right] {
        for y in [bounds.bottom, bounds.top] {
            let (px, py) = page.points_to_pixels(PdfPoints::new(x), PdfPoints::new(y), config)?;
            xs.push(px as f32);
            ys.push(py as f32);
        }
    }
    Ok(Rect {
        left: xs.iter().copied().fold(f32::INFINITY, f32::min),
        right: xs.iter().copied().fold(f32::NEG_INFINITY, f32::max),
        bottom: height - ys.iter().copied().fold(f32::NEG_INFINITY, f32::max),
        top: height - ys.iter().copied().fold(f32::INFINITY, f32::min),
    })
    .map(|mut r| {
        r.left = r.left / width * page.width().value;
        r.right = r.right / width * page.width().value;
        r.bottom = r.bottom / height * page.height().value;
        r.top = r.top / height * page.height().value;
        r
    })
}

fn font_supports(font: &PdfFont, value: &str, original: &str) -> bool {
    if font.is_built_in() {
        return value.chars().all(|c| (' '..='~').contains(&c));
    }
    if let Ok(data) = font.data()
        && let Ok(face) = ttf_parser::Face::parse(&data, 0)
    {
        return value
            .chars()
            .all(|c| c.is_whitespace() || face.glyph_index(c).is_some());
    }
    value.chars().all(|c| original.contains(c))
}

pub fn inspect(bytes: &[u8], page_ids: Option<&[String]>) -> Result<Vec<PageInfo>> {
    with_pdfium(|pdfium| {
        let document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        if let Some(ids) = page_ids {
            ensure!(
                ids.len() == document.pages().len() as usize,
                "PAGE_MAPPING_CHANGED"
            );
        }
        ensure!(
            document.pages().len() <= 1000,
            "PAGE_LIMIT: maximum 1000 pages in P0"
        );
        let mut pages = Vec::new();
        for (index, page) in document.pages().iter().enumerate() {
            ensure!(
                page.width().value.is_finite()
                    && page.height().value.is_finite()
                    && page.width().value > 0.
                    && page.height().value > 0.,
                "INVALID_PAGE_SIZE"
            );
            let id = page_ids
                .map(|ids| ids[index].clone())
                .unwrap_or_else(|| format!("page-{index}"));
            ensure!(page.objects().len() <= 50_000, "OBJECT_LIMIT");
            let mut text_objects = Vec::new();
            let mut image_objects = Vec::new();
            for (object_index, object) in page.objects().iter().enumerate() {
                if object.as_image_object().is_some() {
                    let bounds = rect(object.bounds()?.to_rect());
                    image_objects.push(ImageObject {
                        id: format!("{id}:image:{object_index}"),
                        page_id: id.clone(),
                        object_index: object_index as u32,
                        display_bounds: display_rect(
                            &page,
                            &bounds,
                            &PdfRenderConfig::new()
                                .set_fixed_width(10000)
                                .set_fixed_height(10000),
                            10000.,
                            10000.,
                        )?,
                        bounds,
                    });
                }
                if let Some(text) = object.as_text_object() {
                    text_objects.push(TextObject {
                        id: format!("{id}:text:{object_index}"),
                        page_id: id.clone(),
                        object_index: object_index as u32,
                        text: text.text(),
                        bounds: rect(text.bounds()?.to_rect()),
                        layout_bounds: Some(rect(text.bounds()?.to_rect())),
                        display_bounds: display_rect(
                            &page,
                            &rect(text.bounds()?.to_rect()),
                            &PdfRenderConfig::new()
                                .set_fixed_width(10000)
                                .set_fixed_height(10000),
                            10000.,
                            10000.,
                        )?,
                        font_size: text.unscaled_font_size().value,
                        editable: text.is_visible(),
                    });
                }
            }
            pages.push(PageInfo {
                id,
                index: index as u16,
                width: page.width().value,
                height: page.height().value,
                text_objects,
                text_content: page.text()?.all(),
                image_objects,
            });
        }
        ensure!(!pages.is_empty(), "EMPTY_DOCUMENT");
        Ok(pages)
    })
}

pub fn replace_text(
    bytes: &[u8],
    page_index: u16,
    object_index: u32,
    expected_text: &str,
    replacement: &str,
    original_bounds: &Rect,
) -> Result<Vec<u8>> {
    replace_text_with_options(
        bytes,
        page_index,
        object_index,
        expected_text,
        replacement,
        original_bounds,
        &TextEditOptions::default(),
    )
}

pub fn replace_text_with_options(
    bytes: &[u8],
    page_index: u16,
    object_index: u32,
    expected_text: &str,
    replacement: &str,
    original_bounds: &Rect,
    options: &TextEditOptions,
) -> Result<Vec<u8>> {
    ensure!(
        !replacement.trim().is_empty() && replacement.len() <= 16_384,
        "INVALID_TEXT: provide 1 to 16384 bytes of visible text"
    );
    ensure!(
        !replacement.chars().any(char::is_control),
        "UNSUPPORTED_TEXT: single line only"
    );
    with_pdfium(|pdfium| {
        let mut document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        ensure!(
            document.signatures().is_empty(),
            "SIGNED_DOCUMENT: P0 edits disabled; preserve original"
        );
        let replacement_font = if let Some(path) = &options.font_path {
            let data = std::fs::read(path)?;
            let face = ttf_parser::Face::parse(&data, 0).context("INVALID_FONT")?;
            ensure!(
                replacement
                    .chars()
                    .all(|c| c.is_whitespace() || face.glyph_index(c).is_some()),
                "FONT_MISSING_GLYPH"
            );
            Some(
                document
                    .fonts_mut()
                    .load_true_type_from_bytes(&data, true)?,
            )
        } else {
            None
        };
        let mut page = document.pages().get(i32::from(page_index))?;
        let mut object = page.objects().get(object_index as usize)?;
        let text = object.as_text_object_mut().context("NOT_TEXT_OBJECT")?;
        ensure!(
            text.is_visible(),
            "INVISIBLE_TEXT_LAYER: OCR search text is not visible page content"
        );
        ensure!(text.text() == expected_text, "OBJECT_CHANGED");
        let font_size = text.unscaled_font_size().value;
        if let Some(font) = replacement_font {
            let matrix = text.matrix()?;
            let fill = text.fill_color()?;
            let mode = text.render_mode();
            drop(object);
            let mut new_text =
                PdfPageTextObject::new(&document, replacement, font, PdfPoints::new(font_size))?;
            new_text.reset_matrix(matrix)?;
            new_text.set_fill_color(fill)?;
            new_text.set_render_mode(mode)?;
            drop(
                page.objects_mut()
                    .remove_object_at_index(object_index as usize)?,
            );
            drop(
                page.objects_mut()
                    .insert_object_at_index(object_index as usize, PdfPageObject::Text(new_text))?,
            );
            object = page.objects().get(object_index as usize)?;
        } else {
            ensure!(
                font_supports(&text.font(), replacement, expected_text),
                "FONT_MISSING_GLYPH: choose a font containing the replacement characters"
            );
            text.set_text(replacement)?;
        }
        let text = object.as_text_object_mut().context("NOT_TEXT_OBJECT")?;
        let mut updated_bounds = rect(text.bounds()?.to_rect());
        let original_width = original_bounds.right - original_bounds.left;
        let updated_width = updated_bounds.right - updated_bounds.left;
        if updated_width > original_width + 0.5 && options.shrink_to_fit {
            let size = font_size * original_width / updated_width;
            ensure!(
                size >= (font_size * 0.5).max(4.),
                "LAYOUT_OVERFLOW: required font size is below the allowed minimum"
            );
            text.set_unscaled_font_size(PdfPoints::new(size))?;
            text.set_text(replacement)?;
            updated_bounds = rect(text.bounds()?.to_rect());
        }
        // Glyph ink bounds vary with the letters. Keep the original baseline and
        // width, but allow normal ascenders/descenders inside the font line box.
        ensure!(
            updated_bounds.right - updated_bounds.left <= original_width + 0.5,
            "LAYOUT_OVERFLOW: replacement is wider than the original line area"
        );
        let allowed = Rect {
            bottom: original_bounds.bottom - font_size * 0.3,
            top: original_bounds.top + font_size * 0.3,
            left: original_bounds.left - font_size * 0.3,
            right: original_bounds.right + font_size * 0.3,
        };
        ensure!(
            allowed.contains(&updated_bounds, 0.5),
            "LAYOUT_OVERFLOW: replacement exceeds the line area; enable shrink-to-fit or shorten the text"
        );
        for (index, other) in page.objects().iter().enumerate() {
            if index == object_index as usize {
                continue;
            }
            let bounds = rect(other.bounds()?.to_rect());
            ensure!(
                !updated_bounds.intersects(&bounds) || original_bounds.intersects(&bounds),
                "LAYOUT_COLLISION: new glyphs intersect a neighboring object"
            );
        }
        drop(object);
        page.regenerate_content()?;
        let output = document.save_to_bytes()?;
        drop(page);
        drop(document);
        let reopened = pdfium.load_pdf_from_byte_slice(&output, None)?;
        let page = reopened.pages().get(i32::from(page_index))?;
        let object = page.objects().get(object_index as usize)?;
        ensure!(
            object
                .as_text_object()
                .context("OBJECT_MAPPING_CHANGED")?
                .text()
                .trim_end_matches([' ', '\r', '\n'])
                == replacement.trim_end_matches([' ', '\r', '\n']),
            "SAVE_VERIFICATION_FAILED: text did not survive reopening"
        );
        let source = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        let original_page = source.pages().get(i32::from(page_index))?;
        let config = PdfRenderConfig::new()
            .set_target_width(800)
            .set_maximum_height(1200);
        let before = original_page
            .render_with_config(&config)?
            .as_image()?
            .into_rgba8();
        let after = page.render_with_config(&config)?.as_image()?.into_rgba8();
        ensure!(
            before.dimensions() == after.dimensions(),
            "VISUAL_SIZE_CHANGED"
        );
        let native_mask = Rect {
            left: original_bounds.left.min(updated_bounds.left),
            right: original_bounds.right.max(updated_bounds.right),
            bottom: original_bounds.bottom.min(updated_bounds.bottom),
            top: original_bounds.top.max(updated_bounds.top),
        };
        let mask = display_rect(
            &original_page,
            &native_mask,
            &config,
            before.width() as f32,
            before.height() as f32,
        )?;
        let sx = before.width() as f32 / original_page.width().value;
        let sy = before.height() as f32 / original_page.height().value;
        ensure!(
            original_page.objects().len() == page.objects().len(),
            "OBJECT_MAPPING_CHANGED"
        );
        for (index, original) in original_page.objects().iter().enumerate() {
            if index == object_index as usize {
                continue;
            }
            let current = page.objects().get(index)?;
            ensure!(
                original.object_type() == current.object_type(),
                "OBJECT_MAPPING_CHANGED"
            );
            if let Some(text) = original.as_text_object() {
                ensure!(
                    current
                        .as_text_object()
                        .is_some_and(|other| other.text().trim_end_matches([' ', '\r', '\n'])
                            == text.text().trim_end_matches([' ', '\r', '\n'])),
                    "UNEDITED_TEXT_CHANGED"
                );
            }
            let a = rect(original.bounds()?.to_rect());
            let b = rect(current.bounds()?.to_rect());
            ensure!(
                [
                    (a.left - b.left),
                    (a.right - b.right),
                    (a.top - b.top),
                    (a.bottom - b.bottom)
                ]
                .iter()
                .all(|v| v.abs() <= 0.25),
                "UNEDITED_OBJECT_MOVED"
            );
        }
        let mut antialias_pixels = 0usize;
        for (x, y, pixel) in before.enumerate_pixels() {
            // PDF origin is bottom-left; image origin is top-left. Allow a 2 px
            // antialiasing fringe around the original editing region only.
            let inside = x as f32 >= mask.left * sx - 2.
                && x as f32 <= mask.right * sx + 2.
                && y as f32 >= before.height() as f32 - mask.top * sy - 2.
                && y as f32 <= before.height() as f32 - mask.bottom * sy + 2.;
            if !inside && pixel != after.get_pixel(x, y) {
                ensure!(
                    is_edge_antialias_change(&before, &after, x, y),
                    "VISUAL_OUTSIDE_REGION: content changed outside original text bounds"
                );
                antialias_pixels += 1;
            }
        }
        ensure!(
            antialias_pixels <= (before.width() as usize * before.height() as usize / 1000).max(8),
            "VISUAL_OUTSIDE_REGION: too many edge differences"
        );
        drop(object);
        drop(page);
        drop(reopened);
        Ok(output)
    })
}

fn is_edge_antialias_change(
    before: &image::RgbaImage,
    after: &image::RgbaImage,
    x: u32,
    y: u32,
) -> bool {
    let a = before.get_pixel(x, y).0;
    let b = after.get_pixel(x, y).0;
    if a[3] != b[3] || (0..3).any(|c| a[c].abs_diff(b[c]) > 64) {
        return false;
    }
    (0..3).all(|channel| {
        let mut low = u8::MAX;
        let mut high = u8::MIN;
        for ny in y.saturating_sub(2)..=(y + 2).min(before.height() - 1) {
            for nx in x.saturating_sub(2)..=(x + 2).min(before.width() - 1) {
                low = low.min(before.get_pixel(nx, ny).0[channel]);
                high = high.max(before.get_pixel(nx, ny).0[channel]);
            }
        }
        high.saturating_sub(low) >= 96 && (low..=high).contains(&b[channel])
    })
}

pub fn render_png(bytes: &[u8], page_index: u16, destination: &Path) -> Result<()> {
    render_png_at_width(bytes, page_index, destination, 1200)
}

pub fn render_png_at_width(
    bytes: &[u8],
    page_index: u16,
    destination: &Path,
    width: u32,
) -> Result<()> {
    ensure!((512..=4096).contains(&width), "RENDER_PIXEL_LIMIT");
    with_pdfium(|pdfium| {
        let document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        document
            .pages()
            .get(i32::from(page_index))?
            .render_with_config(
                &PdfRenderConfig::new()
                    .set_target_width(width as i32)
                    .set_maximum_height(if width <= 1200 { 1600 } else { 4096 }),
            )?
            .as_image()?
            .save(destination)?;
        Ok(())
    })
}

pub fn create_fixture() -> Result<Vec<u8>> {
    with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let font = document.fonts_mut().helvetica();
        let mut page = document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        page.objects_mut().create_text_object(
            PdfPoints::new(60.),
            PdfPoints::new(740.),
            "Hello PDF Editor",
            font,
            PdfPoints::new(20.),
        )?;
        page.objects_mut().create_text_object(
            PdfPoints::new(60.),
            PdfPoints::new(640.),
            "Unchanged reference text",
            font,
            PdfPoints::new(14.),
        )?;
        page.regenerate_content()?;
        drop(page);
        Ok(document.save_to_bytes()?)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn antialias_tolerance_rejects_real_content_changes() {
        let before = image::RgbaImage::from_pixel(10, 10, image::Rgba([255, 255, 255, 255]));
        let mut after = before.clone();
        after.put_pixel(5, 5, image::Rgba([220, 220, 220, 255]));
        assert!(!is_edge_antialias_change(&before, &after, 5, 5));
        after.put_pixel(5, 5, image::Rgba([0, 0, 0, 255]));
        assert!(!is_edge_antialias_change(&before, &after, 5, 5));
        let mut edge = before.clone();
        edge.put_pixel(4, 5, image::Rgba([0, 0, 0, 255]));
        let mut after = edge.clone();
        after.put_pixel(5, 5, image::Rgba([220, 220, 220, 255]));
        assert!(is_edge_antialias_change(&edge, &after, 5, 5));
    }
    #[test]
    fn direct_transform_moves_and_resizes_rotated_text() -> Result<()> {
        for rotated in [false, true] {
            let source = if rotated {
                operations::page_operation(
                    &create_fixture()?,
                    &operations::PageOperation::Rotate {
                        page: 0,
                        clockwise: true,
                    },
                )?
            } else {
                create_fixture()?
            };
            let output = operations::object_operation(
                &source,
                &operations::ObjectOperation::Transform {
                    page: 0,
                    index: 0,
                    display: [0.2, 0.3, 0.6, 0.4],
                },
            )?;
            let pages = inspect(&output, None)?;
            let p = &pages[0];
            let bounds = &p.text_objects[0].display_bounds;
            assert!((bounds.left / p.width - 0.2).abs() < 0.005);
            assert!((bounds.right / p.width - 0.6).abs() < 0.005);
            assert!((1. - bounds.top / p.height - 0.3).abs() < 0.005);
            assert!((1. - bounds.bottom / p.height - 0.4).abs() < 0.005);
        }
        Ok(())
    }
    #[test]
    fn rotated_page_text_is_editable_and_coordinates_follow_the_view() -> Result<()> {
        let source = operations::page_operation(
            &create_fixture()?,
            &operations::PageOperation::Rotate {
                page: 0,
                clockwise: true,
            },
        )?;
        let pages = inspect(&source, None)?;
        let object = &pages[0].text_objects[0];
        assert!(pages[0].width > pages[0].height);
        assert!(object.display_bounds.left >= 0. && object.display_bounds.right <= pages[0].width);
        let output = replace_text(&source, 0, 0, &object.text, "New text 123", &object.bounds)?;
        assert_eq!(
            inspect(&output, None)?[0].text_objects[0].text,
            "New text 123"
        );
        Ok(())
    }
    #[test]
    fn replacement_accepts_new_supported_characters() -> Result<()> {
        let source = create_fixture()?;
        let pages = inspect(&source, None)?;
        let object = &pages[0].text_objects[0];
        let edited = replace_text(&source, 0, 0, &object.text, "New text 123", &object.bounds)?;
        assert_eq!(
            inspect(&edited, None)?[0].text_objects[0].text,
            "New text 123"
        );
        Ok(())
    }
    #[test]
    fn chinese_font_replacement_and_shrink_survive_save() -> Result<()> {
        let source = create_fixture()?;
        let pages = inspect(&source, None)?;
        let object = &pages[0].text_objects[0];
        let options = TextEditOptions {
            shrink_to_fit: true,
            font_path: Some("C:/Windows/Fonts/simhei.ttf".into()),
        };
        let output = replace_text_with_options(
            &source,
            0,
            0,
            &object.text,
            "编辑测试一二三",
            &object.bounds,
            &options,
        )?;
        assert_eq!(
            inspect(&output, None)?[0].text_objects[0].text,
            "编辑测试一二三"
        );
        let bundled_font = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../apps/flutter_app/assets/fonts/NotoSansSC.ttf");
        let bundled = replace_text_with_options(
            &source,
            0,
            0,
            &object.text,
            "中文编辑与测试",
            &object.bounds,
            &TextEditOptions {
                shrink_to_fit: true,
                font_path: Some(bundled_font.to_string_lossy().into()),
            },
        )?;
        assert_eq!(
            inspect(&bundled, None)?[0].text_objects[0].text,
            "中文编辑与测试"
        );
        let edited = replace_text_with_options(
            &source,
            0,
            0,
            &object.text,
            "Hello PDF Editor 123456",
            &object.bounds,
            &TextEditOptions {
                shrink_to_fit: true,
                font_path: None,
            },
        )?;
        assert!(inspect(&edited, None)?[0].text_objects[0].font_size < object.font_size);
        Ok(())
    }
    #[test]
    fn native_replace_reopens_and_overflow_is_rejected() -> Result<()> {
        let source = create_fixture()?;
        let pages = inspect(&source, None)?;
        let object = &pages[0].text_objects[0];
        let edited = replace_text(
            &source,
            0,
            object.object_index,
            &object.text,
            "Hello PDF",
            &object.bounds,
        )?;
        let reopened = inspect(&edited, None)?;
        assert_eq!(reopened[0].text_objects[0].text, "Hello PDF");
        assert_eq!(
            reopened[0].text_objects[1].text,
            pages[0].text_objects[1].text
        );
        assert!(
            replace_text(
                &source,
                0,
                object.object_index,
                &object.text,
                "Hello PDF Editor Hello PDF Editor",
                &object.bounds
            )
            .is_err()
        );
        assert!(
            replace_text(
                &source,
                0,
                object.object_index,
                &object.text,
                "中文",
                &object.bounds
            )
            .is_err()
        );
        Ok(())
    }
}
