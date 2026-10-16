//! PDF geometry -> editable Word paragraphs, tables, images and vector shapes.
//! This module never renders a page into a background screenshot.
use super::*;
use std::{
    collections::{HashMap, HashSet},
    io::{Cursor, Write},
};

#[derive(Clone, Debug, PartialEq)]
struct Style {
    font: String,
    size: f32,
    bold: bool,
    italic: bool,
    color: String,
}
#[derive(Clone, Debug)]
struct Glyph {
    text: char,
    x: f32,
    y: f32,
    right: f32,
    baseline: f32,
    hidden: bool,
    source_bounds: [u32; 4],
    order: usize,
    style: Style,
}
#[derive(Clone, Debug)]
struct Edge {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
}
#[derive(Clone)]
struct Vector {
    path: String,
    fill: Option<String>,
    stroke: Option<String>,
    width: f32,
    edges: Vec<Edge>,
    rectangle: Option<[f32; 4]>,
}
struct Picture {
    order: usize,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    png: Vec<u8>,
}
struct TextPaint {
    key: [u32; 4],
    bounds: [f32; 4],
    order: usize,
}
struct Layout {
    order: usize,
    text_paints: Vec<TextPaint>,
    width: f32,
    height: f32,
    glyphs: Vec<Glyph>,
    vectors: Vec<Vector>,
    images: Vec<Picture>,
}
#[derive(Clone)]
struct Cell {
    col: usize,
    span: usize,
    root: (usize, usize),
    bottom: f32,
}
struct Grid {
    xs: Vec<f32>,
    ys: Vec<f32>,
    rows: Vec<Vec<Cell>>,
    edges: HashSet<usize>,
}

fn bounds_key(b: &PdfRect) -> [u32; 4] {
    [
        b.left().value.to_bits(),
        b.bottom().value.to_bits(),
        b.right().value.to_bits(),
        b.top().value.to_bits(),
    ]
}

fn xml(value: &str) -> String {
    value
        .chars()
        .filter(|c| matches!(*c, '\t' | '\n' | '\r') || *c >= ' ')
        .collect::<String>()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn color(value: PdfColor) -> String {
    format!(
        "{:02X}{:02X}{:02X}",
        value.red(),
        value.green(),
        value.blue()
    )
}
fn twip(value: f32) -> i32 {
    (value * 20.).round() as i32
}
fn font_name(name: &str) -> String {
    let name = name
        .split_once('+')
        .filter(|(prefix, _)| prefix.len() == 6)
        .map(|(_, n)| n)
        .unwrap_or(name)
        .trim_start_matches('/');
    match name {
        "Helvetica" | "Helvetica-Bold" | "Helvetica-Oblique" | "ArialMT" | "Arial-BoldMT" => {
            "Arial".into()
        }
        "Times-Roman" | "TimesNewRomanPSMT" | "Times-Bold" => "Times New Roman".into(),
        "SimSun" | "SimSun-Identity-H" | "宋体" => "SimSun".into(),
        "SimHei" | "黑体" => "SimHei".into(),
        _ if name.is_empty() => "Arial".into(),
        _ => name.to_owned(),
    }
}

fn point(page: &PdfPage, x: f32, y: f32, parents: &[PdfMatrix]) -> Result<(f32, f32)> {
    let (mut x, mut y) = (PdfPoints::new(x), PdfPoints::new(y));
    for matrix in parents.iter().rev() {
        (x, y) = matrix.apply_to_points(x, y);
    }
    let config = PdfRenderConfig::new()
        .set_fixed_width(20000)
        .set_fixed_height(20000);
    let (px, py) = page.points_to_pixels(x, y, &config)?;
    Ok((
        px as f32 / 20000. * page.width().value,
        py as f32 / 20000. * page.height().value,
    ))
}

fn graphics(
    object: &PdfPageObject<'_>,
    page: &PdfPage<'_>,
    document: &PdfDocument<'_>,
    parents: &[PdfMatrix],
    layout: &mut Layout,
    depth: usize,
) -> Result<()> {
    ensure!(
        depth <= 32 && layout.vectors.len() + layout.images.len() < 50000,
        "EXPORT_OBJECT_LIMIT"
    );
    layout.order += 1;
    let order = layout.order;
    if let Some(form) = object.as_x_object_form_object() {
        let mut parents = parents.to_vec();
        parents.push(form.matrix()?);
        for child in form.iter() {
            graphics(&child, page, document, &parents, layout, depth + 1)?;
        }
    } else if let Some(text) = object.as_text_object() {
        let b = text.bounds()?.to_rect();
        let corners = [
            (b.left().value, b.top().value),
            (b.right().value, b.top().value),
            (b.left().value, b.bottom().value),
            (b.right().value, b.bottom().value),
        ]
        .into_iter()
        .map(|(x, y)| point(page, x, y, parents))
        .collect::<Result<Vec<_>>>()?;
        layout.text_paints.push(TextPaint {
            key: bounds_key(&b),
            order,
            bounds: [
                corners.iter().map(|p| p.0).fold(f32::INFINITY, f32::min),
                corners.iter().map(|p| p.1).fold(f32::INFINITY, f32::min),
                corners
                    .iter()
                    .map(|p| p.0)
                    .fold(f32::NEG_INFINITY, f32::max),
                corners
                    .iter()
                    .map(|p| p.1)
                    .fold(f32::NEG_INFINITY, f32::max),
            ],
        });
    } else if let Some(image) = object.as_image_object() {
        let bounds = rect(image.bounds()?.to_rect());
        let corners = [
            (bounds.left, bounds.top),
            (bounds.right, bounds.top),
            (bounds.left, bounds.bottom),
            (bounds.right, bounds.bottom),
        ]
        .into_iter()
        .map(|(x, y)| point(page, x, y, parents))
        .collect::<Result<Vec<_>>>()?;
        let x = corners.iter().map(|p| p.0).fold(f32::INFINITY, f32::min);
        let y = corners.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
        let width = corners
            .iter()
            .map(|p| p.0)
            .fold(f32::NEG_INFINITY, f32::max)
            - x;
        let height = corners
            .iter()
            .map(|p| p.1)
            .fold(f32::NEG_INFINITY, f32::max)
            - y;
        ensure!(
            image.width()? as u64 * image.height()? as u64 <= 80_000_000,
            "IMAGE_PIXEL_LIMIT"
        );
        let raster = image.get_processed_image(document)?;
        let mut output = Cursor::new(Vec::new());
        raster.write_to(&mut output, image::ImageFormat::Png)?;
        layout.images.push(Picture {
            order,
            x,
            y,
            width,
            height,
            png: output.into_inner(),
        });
    } else if let Some(path) = object.as_path_object() {
        let mut matrices = parents.to_vec();
        matrices.push(path.matrix()?);
        let mut points = Vec::new();
        for segment in path.segments().iter() {
            let (x, y) = point(page, segment.x().value, segment.y().value, &matrices)?;
            points.push((segment.segment_type(), x, y, segment.is_close()));
        }
        let mut commands = String::new();
        let mut edges = Vec::new();
        let mut previous = None;
        let mut first = None;
        let mut i = 0;
        while i < points.len() {
            let (kind, x, y, close) = points[i];
            match kind {
                PdfPathSegmentType::MoveTo => {
                    commands.push_str(&format!("m {},{} ", twip(x), twip(y)));
                    first = Some((x, y));
                }
                PdfPathSegmentType::LineTo => {
                    commands.push_str(&format!("l {},{} ", twip(x), twip(y)));
                    if let Some((px, py)) = previous {
                        edges.push(Edge {
                            x1: px,
                            y1: py,
                            x2: x,
                            y2: y,
                        });
                    }
                }
                PdfPathSegmentType::BezierTo if i + 2 < points.len() => {
                    let (_, x2, y2, _) = points[i + 1];
                    let (_, x3, y3, c) = points[i + 2];
                    commands.push_str(&format!(
                        "c {},{},{},{},{},{} ",
                        twip(x),
                        twip(y),
                        twip(x2),
                        twip(y2),
                        twip(x3),
                        twip(y3)
                    ));
                    i += 2;
                    previous = Some((x3, y3));
                    if c {
                        commands.push_str("x ");
                    }
                    i += 1;
                    continue;
                }
                _ => {}
            }
            if close {
                commands.push_str("x ");
                if let Some((fx, fy)) = first {
                    edges.push(Edge {
                        x1: x,
                        y1: y,
                        x2: fx,
                        y2: fy,
                    });
                }
            }
            previous = Some((x, y));
            i += 1;
        }
        commands.push('e');
        let fill = if path.fill_mode()? == PdfPathFillMode::None {
            None
        } else {
            Some(color(path.fill_color()?))
        };
        let stroke = if path.is_stroked()? {
            Some(color(path.stroke_color()?))
        } else {
            None
        };
        let left = points.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
        let right = points.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max);
        let top = points.iter().map(|p| p.2).fold(f32::INFINITY, f32::min);
        let bottom = points.iter().map(|p| p.2).fold(f32::NEG_INFINITY, f32::max);
        let rectangle = if fill.is_some()
            && right - left > 3.
            && bottom - top > 3.
            && points.iter().all(|(kind, x, y, _)| {
                *kind != PdfPathSegmentType::BezierTo
                    && (near(*x, left) || near(*x, right))
                    && (near(*y, top) || near(*y, bottom))
            }) {
            Some([left, top, right, bottom])
        } else {
            None
        };
        if stroke.is_none() {
            // Word-generated PDFs frequently encode table rules as very thin
            // filled rectangles rather than stroked paths. Recover their centerlines.
            edges.clear();
            if fill
                .as_deref()
                .is_some_and(|c| c != "FFFFFF" && c != "FFFFFE")
            {
                if right - left > 3. && bottom - top <= 1.5 {
                    edges.push(Edge {
                        x1: left,
                        y1: (top + bottom) / 2.,
                        x2: right,
                        y2: (top + bottom) / 2.,
                    });
                }
                if bottom - top > 3. && right - left <= 1.5 {
                    edges.push(Edge {
                        x1: (left + right) / 2.,
                        y1: top,
                        x2: (left + right) / 2.,
                        y2: bottom,
                    });
                }
            }
        }
        if fill.is_some() || stroke.is_some() {
            layout.vectors.push(Vector {
                path: commands,
                fill,
                stroke,
                width: path.stroke_width()?.value,
                edges,
                rectangle,
            });
        }
    }
    Ok(())
}

fn extract(bytes: &[u8], selected: &[u16]) -> Result<Vec<Layout>> {
    with_pdfium(|pdfium| {
        let document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        let mut layouts = Vec::new();
        for index in selected {
            let page = document.pages().get(i32::from(*index))?;
            let text = page.text()?;
            ensure!(text.chars().len() <= 500_000, "EXPORT_TEXT_LIMIT");
            let mut layout = Layout {
                order: 0,
                text_paints: vec![],
                width: page.width().value,
                height: page.height().value,
                glyphs: vec![],
                vectors: vec![],
                images: vec![],
            };
            for c in text.chars().iter() {
                let Some(value) = c.unicode_char() else {
                    continue;
                };
                if value.is_control() {
                    continue;
                }
                let bounds = c.loose_bounds().or_else(|_| c.tight_bounds())?;
                let (x, y) = point(&page, bounds.left().value, bounds.top().value, &[])?;
                let (right, _) = point(&page, bounds.right().value, bounds.bottom().value, &[])?;
                let (ox, oy) = c.origin()?;
                let (_, baseline) = point(&page, ox.value, oy.value, &[])?;
                let raw = c.font_name();
                let bold = matches!(
                    c.font_weight(),
                    Some(
                        PdfFontWeight::Weight600
                            | PdfFontWeight::Weight700Bold
                            | PdfFontWeight::Weight800
                            | PdfFontWeight::Weight900
                    )
                ) || raw.to_lowercase().contains("bold")
                    || c.font_is_bold_reenforced()
                    || matches!(
                        c.render_mode(),
                        Ok(PdfPageTextRenderMode::FilledThenStroked
                            | PdfPageTextRenderMode::FilledThenStrokedClipping)
                    );
                let style = Style {
                    font: font_name(&raw),
                    size: c.scaled_font_size().value.clamp(1., 400.),
                    bold,
                    italic: c.font_is_italic()
                        || raw.to_lowercase().contains("italic")
                        || raw.to_lowercase().contains("oblique")
                        || c.matrix()
                            .is_ok_and(|m| m.c().abs() > 0.05 && m.b().abs() < 0.01),
                    color: color(c.fill_color().unwrap_or(PdfColor::BLACK)),
                };
                layout.glyphs.push(Glyph {
                    text: value,
                    x,
                    y,
                    right,
                    baseline,
                    source_bounds: c
                        .text_object()
                        .and_then(|o| o.bounds().map(|b| bounds_key(&b.to_rect())))
                        .unwrap_or([0; 4]),
                    order: 0,
                    hidden: matches!(
                        c.render_mode(),
                        Ok(PdfPageTextRenderMode::Invisible
                            | PdfPageTextRenderMode::InvisibleClipping)
                    ),
                    style,
                });
            }
            for object in page.objects().iter() {
                graphics(&object, &page, &document, &[], &mut layout, 0)?;
            }
            // Stamp appearances (including handwritten signatures) are separate
            // PDF annotations, not ordinary page images. Preserve their local
            // appearance objects at the annotation's position on the page.
            for annotation in page.annotations().iter().filter(|a| {
                matches!(
                    a.annotation_type(),
                    PdfPageAnnotationType::Stamp | PdfPageAnnotationType::Ink
                )
            }) {
                let objects = annotation.objects();
                ensure!(!objects.is_empty(), "ANNOTATION_APPEARANCE_REQUIRED");
                let bounds = objects
                    .iter()
                    .map(|o| o.bounds().map(|b| b.to_rect()))
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                let left = bounds
                    .iter()
                    .map(|b| b.left().value)
                    .fold(f32::INFINITY, f32::min);
                let bottom = bounds
                    .iter()
                    .map(|b| b.bottom().value)
                    .fold(f32::INFINITY, f32::min);
                let right = bounds
                    .iter()
                    .map(|b| b.right().value)
                    .fold(f32::NEG_INFINITY, f32::max);
                let top = bounds
                    .iter()
                    .map(|b| b.top().value)
                    .fold(f32::NEG_INFINITY, f32::max);
                let target = annotation.bounds()?;
                ensure!(
                    right > left && top > bottom,
                    "INVALID_ANNOTATION_APPEARANCE"
                );
                let sx = target.width().value / (right - left);
                let sy = target.height().value / (top - bottom);
                let transform = PdfMatrix::new(
                    sx,
                    0.,
                    0.,
                    sy,
                    target.left().value - left * sx,
                    target.bottom().value - bottom * sy,
                );
                for object in objects.iter() {
                    graphics(&object, &page, &document, &[transform], &mut layout, 0)?;
                }
            }
            let mut paints: HashMap<[u32; 4], Vec<&TextPaint>> = HashMap::new();
            for paint in &layout.text_paints {
                paints.entry(paint.key).or_default().push(paint);
            }
            for glyph in &mut layout.glyphs {
                if let Some(candidates) = paints.get(&glyph.source_bounds) {
                    let x = (glyph.x + glyph.right) / 2.;
                    let y = (glyph.y + glyph.baseline) / 2.;
                    glyph.order = candidates
                        .iter()
                        .rev()
                        .find(|p| {
                            x >= p.bounds[0] - 1.
                                && x <= p.bounds[2] + 1.
                                && y >= p.bounds[1] - 1.
                                && y <= p.bounds[3] + 1.
                        })
                        .or_else(|| candidates.first())
                        .map(|p| p.order)
                        .unwrap_or(0);
                }
            }
            ensure!(
                !layout.glyphs.is_empty() || layout.images.is_empty(),
                "EDITABLE_TEXT_REQUIRED: recognize scanned pages with OCR before Word export"
            );
            if layout
                .glyphs
                .iter()
                .any(|g| !g.hidden && !g.text.is_whitespace())
            {
                layout.glyphs.retain(|g| !g.hidden);
            } else if !layout.glyphs.is_empty() {
                // An OCR search layer becomes real Word text. Do not also put
                // the original full-page scan underneath the editable words.
                let page_area = layout.width * layout.height;
                layout
                    .images
                    .retain(|i| i.width * i.height < page_area * 0.7);
            }
            let existing_glyphs: usize = layouts.iter().map(|l: &Layout| l.glyphs.len()).sum();
            let existing_media: usize = layouts
                .iter()
                .flat_map(|l: &Layout| &l.images)
                .map(|i| i.png.len())
                .sum();
            ensure!(
                existing_glyphs + layout.glyphs.len() <= 2_000_000,
                "EXPORT_TEXT_LIMIT"
            );
            ensure!(
                existing_media + layout.images.iter().map(|i| i.png.len()).sum::<usize>()
                    <= 128 * 1024 * 1024,
                "EXPORT_SIZE_LIMIT"
            );
            layouts.push(layout);
        }
        Ok(layouts)
    })
}

fn near(a: f32, b: f32) -> bool {
    (a - b).abs() < 1.5
}
fn coordinates(mut values: Vec<f32>) -> Vec<f32> {
    values.sort_by(f32::total_cmp);
    values.dedup_by(|a, b| near(*a, *b));
    values
}
fn horizontal(e: &Edge) -> bool {
    near(e.y1, e.y2) && (e.x1 - e.x2).abs() > 3.
}
fn vertical(e: &Edge) -> bool {
    near(e.x1, e.x2) && (e.y1 - e.y2).abs() > 3.
}
fn meets(a: &Edge, b: &Edge) -> bool {
    a.x1.min(a.x2) <= b.x1.max(b.x2) + 1.5
        && a.x1.max(a.x2) + 1.5 >= b.x1.min(b.x2)
        && a.y1.min(a.y2) <= b.y1.max(b.y2) + 1.5
        && a.y1.max(a.y2) + 1.5 >= b.y1.min(b.y2)
}
fn grids(layout: &Layout) -> Vec<Grid> {
    let edges: Vec<_> = layout
        .vectors
        .iter()
        .flat_map(|v| v.edges.iter())
        .filter(|e| horizontal(e) || vertical(e))
        .cloned()
        .collect();
    // Fail closed on vector-heavy illustrations: editable text/shapes still export.
    if edges.len() > 4000 {
        return vec![];
    }
    let mut remaining: HashSet<usize> = (0..edges.len()).collect();
    let mut output = Vec::new();
    while let Some(seed) = remaining.iter().copied().min() {
        remaining.remove(&seed);
        let mut component = vec![seed];
        let mut at = 0;
        while at < component.len() {
            let linked: Vec<_> = remaining
                .iter()
                .copied()
                .filter(|i| meets(&edges[component[at]], &edges[*i]))
                .collect();
            for i in linked {
                remaining.remove(&i);
                component.push(i);
            }
            at += 1;
        }
        let xs = coordinates(
            component
                .iter()
                .filter(|i| vertical(&edges[**i]))
                .map(|i| edges[*i].x1)
                .collect(),
        );
        let ys = coordinates(
            component
                .iter()
                .filter(|i| horizontal(&edges[**i]))
                .map(|i| edges[*i].y1)
                .collect(),
        );
        if xs.len() < 2 || ys.len() < 2 || xs.len() > 100 || ys.len() > 200 {
            continue;
        }
        let h = |y: f32, x: f32| {
            component.iter().any(|i| {
                let e = &edges[*i];
                horizontal(e)
                    && near(e.y1, y)
                    && e.x1.min(e.x2) <= x + 1.5
                    && e.x1.max(e.x2) >= x - 1.5
            })
        };
        let v = |x: f32, y: f32| {
            component.iter().any(|i| {
                let e = &edges[*i];
                vertical(e)
                    && near(e.x1, x)
                    && e.y1.min(e.y2) <= y + 1.5
                    && e.y1.max(e.y2) >= y - 1.5
            })
        };
        // A real bounded grid needs four outside borders, not just underlines.
        if !h(ys[0], (xs[0] + xs[xs.len() - 1]) / 2.)
            || !h(ys[ys.len() - 1], (xs[0] + xs[xs.len() - 1]) / 2.)
            || !v(xs[0], (ys[0] + ys[ys.len() - 1]) / 2.)
            || !v(xs[xs.len() - 1], (ys[0] + ys[ys.len() - 1]) / 2.)
        {
            continue;
        }
        let mut rows: Vec<Vec<Cell>> = Vec::new();
        for r in 0..ys.len() - 1 {
            let boundaries: Vec<_> = (0..xs.len())
                .filter(|c| *c == 0 || *c == xs.len() - 1 || v(xs[*c], (ys[r] + ys[r + 1]) / 2.))
                .collect();
            let mut row = Vec::new();
            for pair in boundaries.windows(2) {
                let (col, end) = (pair[0], pair[1]);
                let span = end - col;
                let above = if r > 0 && !h(ys[r], (xs[col] + xs[end]) / 2.) {
                    rows[r - 1]
                        .iter()
                        .find(|c| c.col == col && c.span == span)
                        .map(|c| c.root)
                } else {
                    None
                };
                let root = above.unwrap_or((r, row.len()));
                if let Some((rr, cc)) = above {
                    rows[rr][cc].bottom = ys[r + 1];
                }
                row.push(Cell {
                    col,
                    span,
                    root,
                    bottom: ys[r + 1],
                });
            }
            rows.push(row);
        }
        output.push(Grid {
            xs,
            ys,
            rows,
            edges: component.into_iter().collect(),
        });
    }
    output
}

fn runs(glyphs: &[&Glyph], scale: f32, fit_id: &mut u32) -> String {
    styled_runs(glyphs, scale, fit_id, true)
}
fn styled_runs(glyphs: &[&Glyph], scale: f32, fit_id: &mut u32, fit_width: bool) -> String {
    let mut out = String::new();
    let mut index = 0;
    while index < glyphs.len() {
        let first = glyphs[index];
        let mut end = index + 1;
        while end < glyphs.len() && glyphs[end].style == first.style {
            end += 1;
        }
        let value: String = glyphs[index..end].iter().map(|g| g.text).collect();
        let style = &first.style;
        let size = (style.size * scale * 2.).round().max(2.) as u32;
        *fit_id += 1;
        // Preserve the original span's advance width even when Word substitutes
        // an unavailable PDF font. Text remains editable in the native run.
        let advance = twip((glyphs[end - 1].right - first.x).max(style.size * 0.2) * scale);
        let fit = if fit_width {
            format!("<w:fitText w:val=\"{advance}\" w:id=\"{fit_id}\"/>")
        } else {
            String::new()
        };
        out.push_str(&format!("<w:r><w:rPr><w:rFonts w:ascii=\"{0}\" w:hAnsi=\"{0}\" w:eastAsia=\"{0}\" w:cs=\"{0}\"/>{3}{4}<w:color w:val=\"{2}\"/><w:sz w:val=\"{1}\"/><w:szCs w:val=\"{1}\"/>{fit}</w:rPr><w:t xml:space=\"preserve\">{5}</w:t></w:r>",xml(&style.font),size,style.color,if style.bold{"<w:b/><w:bCs/>"}else{""},if style.italic{"<w:i/><w:iCs/>"}else{""},xml(&value)));
        index = end;
    }
    out
}
fn lines(mut glyphs: Vec<&Glyph>) -> Vec<Vec<&Glyph>> {
    glyphs.sort_by(|a, b| a.baseline.total_cmp(&b.baseline).then(a.x.total_cmp(&b.x)));
    let mut result: Vec<Vec<&Glyph>> = Vec::new();
    for glyph in glyphs {
        if let Some(row) = result.last_mut()
            && (row[0].baseline - glyph.baseline).abs()
                < glyph.style.size.min(row[0].style.size) * 0.25
        {
            row.push(glyph);
        } else {
            result.push(vec![glyph]);
        }
    }
    for row in &mut result {
        row.sort_by(|a, b| a.x.total_cmp(&b.x));
    }
    result
}
fn table(grid: &Grid, layout: &Layout, scale: f32, fit_id: &mut u32, floating: bool) -> String {
    let mut out = format!(
        "<w:tbl><w:tblPr><w:tblpPr w:horzAnchor=\"page\" w:vertAnchor=\"page\" w:tblpX=\"{}\" w:tblpY=\"{}\" w:leftFromText=\"0\" w:rightFromText=\"0\" w:topFromText=\"0\" w:bottomFromText=\"0\"/><w:tblW w:w=\"{}\" w:type=\"dxa\"/><w:tblBorders>",
        twip(grid.xs[0] * scale),
        twip(grid.ys[0] * scale),
        twip((grid.xs.last().unwrap() - grid.xs[0]) * scale)
    );
    for border in ["top", "left", "bottom", "right", "insideH", "insideV"] {
        out.push_str(&format!(
            "<w:{border} w:val=\"single\" w:sz=\"4\" w:color=\"000000\"/>"
        ));
    }
    out.push_str("</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"0\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"0\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>");
    for xs in grid.xs.windows(2) {
        out.push_str(&format!(
            "<w:gridCol w:w=\"{}\"/>",
            twip((xs[1] - xs[0]) * scale)
        ));
    }
    out.push_str("</w:tblGrid>");
    for (r, row) in grid.rows.iter().enumerate() {
        out.push_str(&format!(
            "<w:tr><w:trPr><w:cantSplit/><w:trHeight w:val=\"{}\" w:hRule=\"exact\"/></w:trPr>",
            twip((grid.ys[r + 1] - grid.ys[r]) * scale)
        ));
        for (c, cell) in row.iter().enumerate() {
            out.push_str(&format!(
                "<w:tc><w:tcPr><w:tcW w:w=\"{}\" w:type=\"dxa\"/><w:gridSpan w:val=\"{}\"/>",
                twip((grid.xs[cell.col + cell.span] - grid.xs[cell.col]) * scale),
                cell.span
            ));
            let continuation = cell.root != (r, c);
            if continuation {
                out.push_str("<w:vMerge/>");
            } else if cell.bottom > grid.ys[r + 1] + 1. {
                out.push_str("<w:vMerge w:val=\"restart\"/>");
            }
            let cx = (grid.xs[cell.col] + grid.xs[cell.col + cell.span]) / 2.;
            let cy = (grid.ys[r] + grid.ys[r + 1]) / 2.;
            if let Some(shade) = layout
                .vectors
                .iter()
                .rev()
                .find(|v| {
                    v.rectangle
                        .is_some_and(|[l, t, r, b]| cx >= l && cx <= r && cy >= t && cy <= b)
                })
                .and_then(|v| v.fill.as_deref())
            {
                out.push_str(&format!("<w:shd w:val=\"clear\" w:fill=\"{shade}\"/>"));
            }
            out.push_str("<w:vAlign w:val=\"top\"/></w:tcPr>");
            let glyphs = if continuation {
                vec![]
            } else {
                layout
                    .glyphs
                    .iter()
                    .filter(|g| {
                        let x = (g.x + g.right) / 2.;
                        x >= grid.xs[cell.col] - 0.5
                            && x < grid.xs[cell.col + cell.span] - 0.5
                            && g.baseline >= grid.ys[r]
                            && g.y < cell.bottom
                    })
                    .collect()
            };
            let mut previous = grid.ys[r];
            let rows = lines(glyphs);
            if rows.is_empty() {
                out.push_str("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/></w:pPr></w:p>");
            }
            for line in rows {
                let size = line.iter().map(|g| g.style.size).fold(1., f32::max);
                let top = line.iter().map(|g| g.y).fold(f32::INFINITY, f32::min);
                let left = line[0].x - grid.xs[cell.col];
                out.push_str(&format!("<w:p><w:pPr><w:spacing w:before=\"{}\" w:after=\"0\" w:line=\"{}\" w:lineRule=\"exact\"/><w:ind w:left=\"{}\"/><w:contextualSpacing w:val=\"0\"/></w:pPr>{}</w:p>",twip((top-previous).max(0.)*scale),twip(size*1.1*scale),twip(left.max(0.)*scale),runs(&line,scale,fit_id)));
                previous = top + size * 1.1;
            }
            out.push_str("</w:tc>");
        }
        out.push_str("</w:tr>");
    }
    out.push_str("</w:tbl>");
    if !floating {
        if let Some(start) = out.find("<w:tblpPr")
            && let Some(end) = out[start..].find("/>")
        {
            out.replace_range(start..start + end + 2, "");
        }
        out = out.replace("w:hRule=\"exact\"", "w:hRule=\"atLeast\"");
        while let Some(start) = out.find("<w:fitText") {
            let end = out[start..].find("/>").unwrap() + start + 2;
            out.replace_range(start..end, "");
        }
        out = out.replace("w:lineRule=\"exact\"", "w:lineRule=\"atLeast\"");
    }
    out
}

fn section(width: f32, height: f32, last: bool) -> String {
    let properties = format!(
        "<w:sectPr><w:type w:val=\"nextPage\"/><w:pgSz w:w=\"{}\" w:h=\"{}\"/><w:pgMar w:top=\"0\" w:right=\"0\" w:bottom=\"0\" w:left=\"0\" w:header=\"0\" w:footer=\"0\"/><w:cols w:space=\"0\"/></w:sectPr>",
        twip(width),
        twip(height)
    );
    if last {
        properties
    } else {
        format!(
            "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/>{properties}</w:pPr></w:p>"
        )
    }
}

fn picture_overlaps(p: &Picture, g: &Glyph) -> bool {
    g.right > p.x
        && g.x < p.x + p.width
        && g.baseline + g.style.size * 0.2 > p.y
        && g.y < p.y + p.height
}

// Floating text boxes share the drawing z-order with pictures. Ordinary frame
// paragraphs alone cannot appear above a foreground DrawingML picture in Word.
fn layered_box(content: &str, bounds: [f32; 4], order: usize) -> String {
    let [x, y, w, h] = bounds;
    let z = 251658240 + order;
    format!(
        "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/></w:pPr><w:r><w:pict><v:rect style=\"position:absolute;margin-left:{x}pt;margin-top:{y}pt;width:{}pt;height:{}pt;z-index:{z};mso-position-horizontal-relative:page;mso-position-vertical-relative:page\" filled=\"f\" stroked=\"f\"><v:textbox inset=\"0,0,0,0\"><w:txbxContent>{content}</w:txbxContent></v:textbox></v:rect></w:pict></w:r></w:p>",
        w.max(1.),
        h.max(1.)
    )
}

pub fn export(bytes: &[u8], selected: &[u16]) -> Result<Vec<u8>> {
    ensure!(!selected.is_empty() && selected.len() <= 1000, "PAGE_LIMIT");
    let layouts = extract(bytes, selected)?;
    let mut media = Vec::new();
    let mut body = String::new();
    let mut fit_id = 0;
    for (page_index, page) in layouts.iter().enumerate() {
        let scale = (1584. / page.width.max(page.height)).min(1.);
        let grids = grids(page);
        let all_edges: Vec<_> = page
            .vectors
            .iter()
            .flat_map(|v| v.edges.iter())
            .filter(|e| horizontal(e) || vertical(e))
            .collect();
        for (i, vector) in page.vectors.iter().enumerate() {
            // Recognized grid lines are represented by real Word table borders.
            let is_grid = (vector.fill.is_none() || vector.edges.len() == 1)
                && !vector.edges.is_empty()
                && vector.edges.iter().all(|edge| {
                    all_edges
                        .iter()
                        .position(|e| std::ptr::eq(*e, edge))
                        .is_some_and(|n| grids.iter().any(|g| g.edges.contains(&n)))
                });
            let cell_fill = vector.rectangle.is_some_and(|[left, top, right, bottom]| {
                grids.iter().any(|grid| {
                    left >= grid.xs[0] - 1.5
                        && right <= *grid.xs.last().unwrap() + 1.5
                        && top >= grid.ys[0] - 1.5
                        && bottom <= *grid.ys.last().unwrap() + 1.5
                })
            });
            if is_grid || cell_fill {
                continue;
            }
            body.push_str(&format!("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/></w:pPr><w:r><w:pict><v:shape id=\"vector{page_index}_{i}\" style=\"position:absolute;margin-left:0;margin-top:0;width:{}pt;height:{}pt;mso-position-horizontal-relative:page;mso-position-vertical-relative:page;z-index:0\" coordsize=\"{},{}\" path=\"{}\" filled=\"{}\" fillcolor=\"#{}\" stroked=\"{}\" strokecolor=\"#{}\" strokeweight=\"{}pt\"/></w:pict></w:r></w:p>",page.width*scale,page.height*scale,twip(page.width),twip(page.height),vector.path,if vector.fill.is_some(){"t"}else{"f"},vector.fill.as_deref().unwrap_or("FFFFFF"),if vector.stroke.is_some(){"t"}else{"f"},vector.stroke.as_deref().unwrap_or("000000"),vector.width*scale));
        }
        for picture in &page.images {
            let id = media.len() + 1;
            media.push(picture.png.clone());
            let (x, y, w, h) = (
                twip(picture.x * scale) * 635,
                twip(picture.y * scale) * 635,
                twip(picture.width * scale) * 635,
                twip(picture.height * scale) * 635,
            );
            let z = 251658240 + picture.order;
            let behind = if page.glyphs.iter().any(|g| picture_overlaps(picture, g)) {
                0
            } else {
                1
            };
            body.push_str(&format!("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/></w:pPr><w:r><w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"{z}\" behindDoc=\"{behind}\" locked=\"0\" layoutInCell=\"0\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"page\"><wp:posOffset>{x}</wp:posOffset></wp:positionH><wp:positionV relativeFrom=\"page\"><wp:posOffset>{y}</wp:posOffset></wp:positionV><wp:extent cx=\"{w}\" cy=\"{h}\"/><wp:wrapNone/><wp:docPr id=\"{id}\" name=\"PDF image {id}\"/><wp:cNvGraphicFramePr/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"{id}\" name=\"Image {id}\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId{id}\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{w}\" cy=\"{h}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>"));
        }
        for grid in &grids {
            let glyphs: Vec<_> = page
                .glyphs
                .iter()
                .filter(|g| {
                    let x = (g.x + g.right) / 2.;
                    x >= grid.xs[0]
                        && x <= *grid.xs.last().unwrap()
                        && g.baseline >= grid.ys[0]
                        && g.y < *grid.ys.last().unwrap()
                })
                .collect();
            let layered = page.images.iter().any(|p| {
                glyphs
                    .iter()
                    .any(|g| g.order > p.order && picture_overlaps(p, g))
            });
            if layered {
                let content = table(grid, page, scale, &mut fit_id, false) + "<w:p/>";
                body.push_str(&layered_box(
                    &content,
                    [
                        grid.xs[0] * scale,
                        grid.ys[0] * scale,
                        (grid.xs.last().unwrap() - grid.xs[0]) * scale,
                        (grid.ys.last().unwrap() - grid.ys[0]) * scale + 8.,
                    ],
                    glyphs.iter().map(|g| g.order).max().unwrap_or(0),
                ));
            } else {
                body.push_str(&table(grid, page, scale, &mut fit_id, true));
            }
        }
        let outside = page
            .glyphs
            .iter()
            .filter(|g| {
                !grids.iter().any(|grid| {
                    let x = (g.x + g.right) / 2.;
                    x >= grid.xs[0] - 0.5
                        && x < *grid.xs.last().unwrap() - 0.5
                        && g.baseline >= grid.ys[0]
                        && g.y < *grid.ys.last().unwrap()
                })
            })
            .collect();
        for line in lines(outside) {
            let layered = page
                .images
                .iter()
                .any(|p| line.iter().any(|g| picture_overlaps(p, g)));
            // Keep separate columns apart instead of concatenating them into one paragraph.
            let mut start = 0;
            for end in 1..=line.len() {
                if end < line.len()
                    && line[end].x - line[end - 1].right < line[end].style.size * 1.5
                    && (!layered || line[end].order == line[end - 1].order)
                {
                    continue;
                }
                let glyphs = &line[start..end];
                let size = glyphs.iter().map(|g| g.style.size).fold(1., f32::max);
                let y = glyphs.iter().map(|g| g.y).fold(f32::INFINITY, f32::min);
                let width = (glyphs.last().unwrap().right - glyphs[0].x + size * 0.4).max(size);
                if page.images.iter().any(|p| {
                    glyphs
                        .iter()
                        .any(|g| g.order > p.order && picture_overlaps(p, g))
                }) {
                    let content = format!(
                        "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"{}\" w:lineRule=\"exact\"/></w:pPr>{}</w:p>",
                        twip(size * 1.1 * scale),
                        runs(glyphs, scale, &mut fit_id)
                    );
                    body.push_str(&layered_box(
                        &content,
                        [
                            glyphs[0].x * scale,
                            y * scale,
                            width * scale,
                            size * 1.5 * scale,
                        ],
                        glyphs[0].order,
                    ));
                    start = end;
                    continue;
                }
                body.push_str(&format!("<w:p><w:pPr><w:framePr w:w=\"{}\" w:hAnchor=\"page\" w:vAnchor=\"page\" w:x=\"{}\" w:y=\"{}\" w:wrap=\"none\" w:hSpace=\"0\" w:vSpace=\"0\"/><w:widowControl w:val=\"0\"/><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"{}\" w:lineRule=\"exact\"/></w:pPr>{}</w:p>",twip(width*scale),twip(glyphs[0].x*scale),twip(y*scale),twip(size*1.1*scale),runs(glyphs,scale,&mut fit_id)));
                start = end;
            }
        }
        body.push_str(&section(
            page.width * scale,
            page.height * scale,
            page_index + 1 == layouts.len(),
        ));
    }
    package_docx(&body, &media, None, None)
}

fn package_docx(
    body: &str,
    media: &[Vec<u8>],
    styles: Option<&str>,
    numbering: Option<&str>,
) -> Result<Vec<u8>> {
    ensure!(
        media.iter().map(Vec::len).sum::<usize>() + body.len() <= 256 * 1024 * 1024,
        "EXPORT_SIZE_LIMIT"
    );
    let document = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>{body}</w:body></w:document>"
    );
    let mut rels = String::from(
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">",
    );
    for i in 1..=media.len() {
        rels.push_str(&format!("<Relationship Id=\"rId{i}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image{i}.png\"/>"));
    }
    for (name, part) in [("styles", styles), ("numbering", numbering)] {
        if part.is_some() {
            rels.push_str(&format!("<Relationship Id=\"rId{name}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/{name}\" Target=\"{name}.xml\"/>"));
        }
    }
    rels.push_str("</Relationships>");
    let extras = [("styles", styles), ("numbering", numbering)].into_iter().filter(|(_, p)|p.is_some()).map(|(name,_)|format!("<Override PartName=\"/word/{name}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.{name}+xml\"/>")).collect::<String>();
    let content_types = format!(
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>{extras}</Types>"
    );
    let mut output = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    for (name, value) in [
        ("[Content_Types].xml", content_types.as_str()),
        (
            "_rels/.rels",
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
        ),
        ("word/document.xml", document.as_str()),
        ("word/_rels/document.xml.rels", rels.as_str()),
    ] {
        output.start_file(name, options)?;
        output.write_all(value.as_bytes())?;
    }
    for (name, part) in [("styles", styles), ("numbering", numbering)] {
        if let Some(part) = part {
            output.start_file(format!("word/{name}.xml"), options)?;
            output.write_all(part.as_bytes())?;
        }
    }
    for (i, png) in media.iter().enumerate() {
        output.start_file(format!("word/media/image{}.png", i + 1), options)?;
        output.write_all(png)?;
    }
    Ok(output.finish()?.into_inner())
}

#[cfg(test)]
#[path = "editable_docx_tests.rs"]
mod tests;

#[path = "structured_export.rs"]
mod structured;
pub use structured::{MarkdownExport, flow_docx, markdown};
