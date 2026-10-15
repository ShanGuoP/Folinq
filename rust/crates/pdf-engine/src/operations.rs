use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PageOperation {
    Rotate { page: u16, clockwise: bool },
    Delete { page: u16 },
    Insert { at: u16 },
    Move { page: u16, target: u16 },
    Merge { path: String, at: u16 },
}

pub fn page_operation(bytes: &[u8], operation: &PageOperation) -> Result<Vec<u8>> {
    with_pdfium(|pdfium| {
        let mut document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        ensure!(document.signatures().is_empty(), "SIGNED_DOCUMENT");
        let count = document.pages().len();
        match operation {
            PageOperation::Rotate { page, clockwise } => {
                let mut page = document.pages().get(i32::from(*page))?;
                let current = match page.rotation()? {
                    PdfPageRenderRotation::None => 0,
                    PdfPageRenderRotation::Degrees90 => 1,
                    PdfPageRenderRotation::Degrees180 => 2,
                    PdfPageRenderRotation::Degrees270 => 3,
                };
                let rotation = (current + if *clockwise { 1 } else { 3 }) % 4;
                page.set_rotation(match rotation {
                    1 => PdfPageRenderRotation::Degrees90,
                    2 => PdfPageRenderRotation::Degrees180,
                    3 => PdfPageRenderRotation::Degrees270,
                    _ => PdfPageRenderRotation::None,
                });
            }
            PageOperation::Delete { page } => {
                ensure!(count > 1, "LAST_PAGE: a PDF must retain at least one page");
                document.pages().get(i32::from(*page))?.delete()?;
            }
            PageOperation::Insert { at } => {
                ensure!(i32::from(*at) <= count && count < 1000, "PAGE_LIMIT");
                document
                    .pages_mut()
                    .create_page_at_index(PdfPagePaperSize::a4(), i32::from(*at))?;
            }
            PageOperation::Move { page, target } => {
                ensure!(
                    i32::from(*page) < count && i32::from(*target) < count,
                    "PAGE_NOT_FOUND"
                );
                if page != target {
                    let source = pdfium.load_pdf_from_byte_slice(bytes, None)?;
                    let insert = if target > page {
                        i32::from(*target) + 1
                    } else {
                        i32::from(*target)
                    };
                    document.pages_mut().copy_page_from_document(
                        &source,
                        i32::from(*page),
                        insert,
                    )?;
                    let remove = if target > page {
                        i32::from(*page)
                    } else {
                        i32::from(*page) + 1
                    };
                    document.pages().get(remove)?.delete()?;
                }
            }
            PageOperation::Merge { path, at } => {
                ensure!(i32::from(*at) <= count, "PAGE_NOT_FOUND");
                ensure!(
                    std::fs::metadata(path)?.len() <= 256 * 1024 * 1024,
                    "FILE_LIMIT"
                );
                let source = pdfium.load_pdf_from_file(path, None)?;
                ensure!(
                    source.pages().len() + count <= 1000 && !source.pages().is_empty(),
                    "PAGE_LIMIT"
                );
                document.pages_mut().copy_page_range_from_document(
                    &source,
                    0..=source.pages().len() - 1,
                    i32::from(*at),
                )?;
            }
        }
        Ok(document.save_to_bytes()?)
    })
}

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ObjectOperation {
    Transform {
        page: u16,
        index: u32,
        display: [f32; 4],
    },
    DeleteAnnotation {
        page: u16,
        index: u16,
    },
    Ink {
        page: u16,
        strokes: Vec<Vec<[f32; 2]>>,
    },
    ReplaceImage {
        page: u16,
        index: u32,
        path: String,
    },
    InsertText {
        page: u16,
        text: String,
        x: f32,
        y: f32,
        font_size: f32,
        font_path: Option<String>,
    },
    InsertImage {
        page: u16,
        path: String,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    },
    Move {
        page: u16,
        index: u32,
        dx: f32,
        dy: f32,
    },
    Delete {
        page: u16,
        index: u32,
    },
    Highlight {
        page: u16,
        index: u32,
    },
    Underline {
        page: u16,
        index: u32,
    },
    Comment {
        page: u16,
        text: String,
        x: f32,
        y: f32,
    },
}

fn finite(values: &[f32]) -> Result<()> {
    ensure!(
        values.iter().all(|v| v.is_finite() && v.abs() <= 100_000.),
        "INVALID_GEOMETRY"
    );
    Ok(())
}

pub fn object_operation(bytes: &[u8], operation: &ObjectOperation) -> Result<Vec<u8>> {
    with_pdfium(|pdfium| {
        let mut document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        ensure!(document.signatures().is_empty(), "SIGNED_DOCUMENT");
        match operation {
            ObjectOperation::Transform {
                page,
                index,
                display: [left, top, right, bottom],
            } => {
                ensure!(
                    [left, top, right, bottom]
                        .iter()
                        .all(|v| v.is_finite() && (0.0..=1.0).contains(*v))
                        && right - left > 0.001
                        && bottom - top > 0.001,
                    "INVALID_GEOMETRY"
                );
                let mut page = document.pages().get(i32::from(*page))?;
                let config = PdfRenderConfig::new()
                    .set_fixed_width(10000)
                    .set_fixed_height(10000);
                let (x1, y1) =
                    page.pixels_to_points((left * 10000.) as i32, (top * 10000.) as i32, &config)?;
                let (x2, y2) = page.pixels_to_points(
                    (right * 10000.) as i32,
                    (bottom * 10000.) as i32,
                    &config,
                )?;
                let mut object = page.objects().get(*index as usize)?;
                ensure!(
                    object.as_image_object().is_some()
                        || object.as_text_object().is_some_and(|t| t.is_visible()),
                    "UNSUPPORTED_OBJECT"
                );
                let original = object.bounds()?.to_rect();
                ensure!(
                    original.width().value > 0. && original.height().value > 0.,
                    "INVALID_GEOMETRY"
                );
                object.scale(
                    (x2.value - x1.value).abs() / original.width().value,
                    (y2.value - y1.value).abs() / original.height().value,
                )?;
                let scaled = object.bounds()?.to_rect();
                object.translate(
                    PdfPoints::new(x1.value.min(x2.value) - scaled.left().value),
                    PdfPoints::new(y1.value.min(y2.value) - scaled.bottom().value),
                )?;
                drop(object);
                page.regenerate_content()?;
            }
            ObjectOperation::DeleteAnnotation { page, index } => {
                let mut page = document.pages().get(i32::from(*page))?;
                let annotation = page.annotations_mut().get(usize::from(*index))?;
                ensure!(
                    !matches!(
                        annotation.annotation_type(),
                        PdfPageAnnotationType::Widget
                            | PdfPageAnnotationType::XfaWidget
                            | PdfPageAnnotationType::Link
                    ),
                    "PROTECTED_ANNOTATION"
                );
                page.annotations_mut().delete_annotation(annotation)?;
            }
            ObjectOperation::Ink { page, strokes } => {
                ensure!(
                    !strokes.is_empty()
                        && strokes.len() <= 500
                        && strokes.iter().map(Vec::len).sum::<usize>() <= 20000,
                    "DRAWING_LIMIT"
                );
                let mut page = document.pages().get(i32::from(*page))?;
                let config = PdfRenderConfig::new()
                    .set_fixed_width(10000)
                    .set_fixed_height(10000);
                let mut paths = Vec::new();
                for stroke in strokes.iter().filter(|s| s.len() > 1) {
                    ensure!(
                        stroke
                            .iter()
                            .flatten()
                            .all(|v| v.is_finite() && (0.0..=1.0).contains(v)),
                        "INVALID_GEOMETRY"
                    );
                    let point = |p: &[f32; 2]| {
                        page.pixels_to_points(
                            (1000. + p[0] * 8000.) as i32,
                            (7000. + p[1] * 2000.) as i32,
                            &config,
                        )
                    };
                    let (x, y) = point(&stroke[0])?;
                    let mut path = PdfPagePathObject::new(
                        &document,
                        x,
                        y,
                        Some(PdfColor::new(36, 36, 40, 255)),
                        Some(PdfPoints::new(1.5)),
                        None,
                    )?;
                    for p in stroke.iter().skip(1) {
                        let (x, y) = point(p)?;
                        path.line_to(x, y)?;
                    }
                    paths.push(path);
                }
                ensure!(!paths.is_empty(), "EMPTY_DRAWING");
                for path in paths {
                    page.objects_mut().add_path_object(path)?;
                }
                page.regenerate_content()?;
            }
            ObjectOperation::ReplaceImage { page, index, path } => {
                let mut reader = image::ImageReader::open(path)?.with_guessed_format()?;
                let mut limits = image::Limits::default();
                limits.max_image_width = Some(12000);
                limits.max_image_height = Some(12000);
                limits.max_alloc = Some(256 * 1024 * 1024);
                reader.limits(limits);
                let image = reader.decode()?;
                let mut page = document.pages().get(i32::from(*page))?;
                let mut object = page.objects().get(*index as usize)?;
                let image_object = object.as_image_object_mut().context("NOT_IMAGE_OBJECT")?;
                image_object.set_image(&image)?;
                drop(object);
                page.regenerate_content()?;
            }
            ObjectOperation::InsertText {
                page,
                text,
                x,
                y,
                font_size,
                font_path,
            } => {
                finite(&[*x, *y, *font_size])?;
                ensure!(
                    (4.0..=288.).contains(font_size)
                        && !text.trim().is_empty()
                        && text.len() < 16384,
                    "INVALID_TEXT"
                );
                let font = if let Some(path) = font_path {
                    let data = std::fs::read(path)?;
                    let face = ttf_parser::Face::parse(&data, 0).context("INVALID_FONT")?;
                    ensure!(
                        text.chars()
                            .all(|c| c.is_whitespace() || face.glyph_index(c).is_some()),
                        "FONT_MISSING_GLYPH"
                    );
                    document
                        .fonts_mut()
                        .load_true_type_from_bytes(&data, true)?
                } else {
                    ensure!(
                        text.is_ascii(),
                        "FONT_MISSING_GLYPH: choose a Chinese font for Chinese text"
                    );
                    document.fonts_mut().helvetica()
                };
                let mut page = document.pages().get(i32::from(*page))?;
                for (line, value) in text.lines().enumerate() {
                    if value.trim().is_empty() {
                        continue;
                    }
                    page.objects_mut().create_text_object(
                        PdfPoints::new(*x),
                        PdfPoints::new(*y - line as f32 * font_size * 1.4),
                        value,
                        font,
                        PdfPoints::new(*font_size),
                    )?;
                }
                page.regenerate_content()?;
            }
            ObjectOperation::InsertImage {
                page,
                path,
                x,
                y,
                width,
                height,
            } => {
                finite(&[*x, *y, *width, *height])?;
                ensure!(*width > 0. && *height > 0., "INVALID_GEOMETRY");
                let reader = image::ImageReader::open(path)?.with_guessed_format()?;
                let mut limits = image::Limits::default();
                limits.max_image_width = Some(12000);
                limits.max_image_height = Some(12000);
                limits.max_alloc = Some(256 * 1024 * 1024);
                let mut reader = reader;
                reader.limits(limits);
                let image = reader.decode()?;
                let mut page = document.pages().get(i32::from(*page))?;
                page.objects_mut().create_image_object(
                    PdfPoints::new(*x),
                    PdfPoints::new(*y),
                    &image,
                    Some(PdfPoints::new(*width)),
                    Some(PdfPoints::new(*height)),
                )?;
                page.regenerate_content()?;
            }
            ObjectOperation::Move {
                page,
                index,
                dx,
                dy,
            } => {
                finite(&[*dx, *dy])?;
                let mut page = document.pages().get(i32::from(*page))?;
                let mut object = page.objects().get(*index as usize)?;
                object.translate(PdfPoints::new(*dx), PdfPoints::new(*dy))?;
                drop(object);
                page.regenerate_content()?;
            }
            ObjectOperation::Delete { page, index } => {
                let mut page = document.pages().get(i32::from(*page))?;
                drop(page.objects_mut().remove_object_at_index(*index as usize)?);
                page.regenerate_content()?;
            }
            ObjectOperation::Highlight { page, index }
            | ObjectOperation::Underline { page, index } => {
                let mut page = document.pages().get(i32::from(*page))?;
                let object = page.objects().get(*index as usize)?;
                let bounds = object.bounds()?;
                drop(object);
                if matches!(operation, ObjectOperation::Highlight { .. }) {
                    let mut annotation = page.annotations_mut().create_highlight_annotation()?;
                    annotation.set_position(bounds.left(), bounds.bottom())?;
                    annotation.set_width(bounds.width())?;
                    annotation.set_height(bounds.height())?;
                    annotation.set_stroke_color(PdfColor::new(250, 216, 70, 120))?;
                    annotation
                        .attachment_points_mut()
                        .create_attachment_point_at_end(bounds)?;
                } else {
                    let mut annotation = page.annotations_mut().create_underline_annotation()?;
                    annotation.set_position(bounds.left(), bounds.bottom())?;
                    annotation.set_width(bounds.width())?;
                    annotation.set_height(bounds.height())?;
                    annotation.set_stroke_color(PdfColor::new(70, 90, 160, 255))?;
                    annotation
                        .attachment_points_mut()
                        .create_attachment_point_at_end(bounds)?;
                }
            }
            ObjectOperation::Comment { page, text, x, y } => {
                finite(&[*x, *y])?;
                ensure!(
                    !text.trim().is_empty() && text.len() <= 65536,
                    "INVALID_TEXT"
                );
                let mut page = document.pages().get(i32::from(*page))?;
                let mut annotation = page.annotations_mut().create_text_annotation(text)?;
                annotation.set_position(PdfPoints::new(*x), PdfPoints::new(*y))?;
                annotation.set_width(PdfPoints::new(24.))?;
                annotation.set_height(PdfPoints::new(24.))?;
            }
        }
        Ok(document.save_to_bytes()?)
    })
}

pub fn extract_pages(bytes: &[u8], pages: &[u16]) -> Result<Vec<u8>> {
    ensure!(
        !pages.is_empty() && pages.len() <= 1000,
        "INVALID_PAGE_RANGE"
    );
    with_pdfium(|pdfium| {
        let source = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        let mut result = pdfium.create_new_pdf()?;
        for page in pages {
            ensure!(i32::from(*page) < source.pages().len(), "PAGE_NOT_FOUND");
            let end = result.pages().len();
            result
                .pages_mut()
                .copy_page_from_document(&source, i32::from(*page), end)?;
        }
        Ok(result.save_to_bytes()?)
    })
}
