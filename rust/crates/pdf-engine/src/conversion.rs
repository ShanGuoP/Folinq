use super::*;
use docx_rs::{Docx, Paragraph, Run};
use std::io::Read;

#[derive(Clone, Debug)]
pub struct TextBlock {
    pub text: String,
    pub size: f32,
}

pub fn blank_document() -> Result<Vec<u8>> {
    with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        Ok(document.save_to_bytes()?)
    })
}

pub fn markdown_blocks(source: &str) -> Vec<TextBlock> {
    use pulldown_cmark::{Event, Parser, Tag, TagEnd};
    let mut blocks = Vec::new();
    let mut text = String::new();
    let mut size = 12.;
    for event in Parser::new(source) {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                size = match level {
                    pulldown_cmark::HeadingLevel::H1 => 24.,
                    pulldown_cmark::HeadingLevel::H2 => 20.,
                    _ => 16.,
                };
            }
            Event::Start(Tag::Item) => text.push_str("- "),
            Event::Text(value) | Event::Code(value) => text.push_str(&value),
            Event::SoftBreak | Event::HardBreak => text.push('\n'),
            Event::End(
                TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::Item | TagEnd::CodeBlock,
            ) => {
                if !text.is_empty() {
                    blocks.push(TextBlock {
                        text: std::mem::take(&mut text),
                        size,
                    });
                }
                size = 12.;
            }
            _ => {}
        }
    }
    if !text.is_empty() {
        blocks.push(TextBlock { text, size });
    }
    blocks
}

pub fn docx_blocks(bytes: &[u8]) -> Result<Vec<TextBlock>> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))?;
    let entry = archive.by_name("word/document.xml")?;
    ensure!(entry.size() <= 32 * 1024 * 1024, "DOCX_XML_LIMIT");
    let mut xml = Vec::new();
    entry.take(32 * 1024 * 1024 + 1).read_to_end(&mut xml)?;
    ensure!(xml.len() <= 32 * 1024 * 1024, "DOCX_XML_LIMIT");
    let mut reader = quick_xml::Reader::from_reader(xml.as_slice());
    let mut text = String::new();
    let mut inside_text = false;
    let mut blocks = Vec::new();
    loop {
        match reader.read_event()? {
            quick_xml::events::Event::Start(element) if element.local_name().as_ref() == b"t" => {
                inside_text = true
            }
            quick_xml::events::Event::End(element) if element.local_name().as_ref() == b"t" => {
                inside_text = false
            }
            quick_xml::events::Event::Text(value) if inside_text => {
                text.push_str(&quick_xml::escape::unescape(&value.decode()?)?)
            }
            quick_xml::events::Event::GeneralRef(value) if inside_text => {
                text.push_str(&quick_xml::escape::unescape(&format!(
                    "&{};",
                    std::str::from_utf8(value.as_ref())?
                ))?);
            }
            quick_xml::events::Event::End(element) if element.local_name().as_ref() == b"p" => {
                blocks.push(TextBlock {
                    text: std::mem::take(&mut text),
                    size: 12.,
                });
            }
            quick_xml::events::Event::Eof => break,
            _ => {}
        }
    }
    Ok(blocks)
}

pub fn text_to_pdf(blocks: &[TextBlock], font_path: Option<&str>) -> Result<Vec<u8>> {
    ensure!(!blocks.is_empty() && blocks.len() < 100000, "TEXT_LIMIT");
    with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let font = if let Some(path) = font_path {
            let data = std::fs::read(path)?;
            let face = ttf_parser::Face::parse(&data, 0).context("INVALID_FONT")?;
            ensure!(
                blocks
                    .iter()
                    .flat_map(|b| b.text.chars())
                    .all(|c| c.is_whitespace() || face.glyph_index(c).is_some()),
                "FONT_MISSING_GLYPH"
            );
            document
                .fonts_mut()
                .load_true_type_from_bytes(&data, true)?
        } else {
            ensure!(
                blocks.iter().all(|b| b.text.is_ascii()),
                "FONT_MISSING_GLYPH"
            );
            document.fonts_mut().helvetica()
        };
        document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        let mut page_index = 0;
        let mut y = 780.;
        for block in blocks {
            for line in block.text.lines() {
                let chars: Vec<char> = line.chars().collect();
                let mut offset = 0;
                while offset < chars.len() {
                    let mut count = ((495. / block.size) as usize)
                        .min(chars.len() - offset)
                        .max(1);
                    let (mut object, count) = loop {
                        let value: String = chars[offset..offset + count].iter().collect();
                        let object = PdfPageTextObject::new(
                            &document,
                            value,
                            font,
                            PdfPoints::new(block.size),
                        )?;
                        if object.bounds()?.to_rect().width().value <= 495. {
                            break (object, count);
                        }
                        ensure!(count > 1, "TEXT_LAYOUT_FAILED");
                        count -= 1;
                    };
                    if y < 60. + block.size {
                        page_index += 1;
                        ensure!(page_index < 1000, "PAGE_LIMIT");
                        document
                            .pages_mut()
                            .create_page_at_end(PdfPagePaperSize::a4())?;
                        y = 780.;
                    }
                    object.translate(PdfPoints::new(50.), PdfPoints::new(y))?;
                    document
                        .pages()
                        .get(page_index)?
                        .objects_mut()
                        .add_text_object(object)?;
                    y -= block.size * 1.5;
                    offset += count;
                }
                if chars.is_empty() {
                    y -= block.size * 1.5;
                }
            }
            y -= 8.;
        }
        let output = document.save_to_bytes()?;
        Ok(output)
    })
}

pub fn images_to_pdf(paths: &[String]) -> Result<Vec<u8>> {
    ensure!(!paths.is_empty() && paths.len() <= 1000, "IMAGE_LIMIT");
    with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        for path in paths {
            let mut reader = image::ImageReader::open(path)?.with_guessed_format()?;
            let mut limits = image::Limits::default();
            limits.max_image_width = Some(12000);
            limits.max_image_height = Some(12000);
            limits.max_alloc = Some(256 * 1024 * 1024);
            reader.limits(limits);
            let image = reader.decode()?;
            let mut page = document
                .pages_mut()
                .create_page_at_end(PdfPagePaperSize::a4())?;
            let scale = (page.width().value / image.width() as f32)
                .min(page.height().value / image.height() as f32);
            let width = image.width() as f32 * scale;
            let height = image.height() as f32 * scale;
            let x = (page.width().value - width) / 2.;
            let y = (page.height().value - height) / 2.;
            page.objects_mut().create_image_object(
                PdfPoints::new(x),
                PdfPoints::new(y),
                &image,
                Some(PdfPoints::new(width)),
                Some(PdfPoints::new(height)),
            )?;
            page.regenerate_content()?;
        }
        Ok(document.save_to_bytes()?)
    })
}

pub fn text_export(pages: &[PageInfo], markdown: bool) -> String {
    let mut output = String::new();
    for (index, page) in pages.iter().enumerate() {
        if markdown {
            output.push_str(&format!("<!-- page {} -->\n\n", index + 1));
        }
        output.push_str(&page.text_content);
        output.push_str(if markdown {
            "\n\n---\n\n"
        } else {
            "\n\u{000c}\n"
        });
    }
    output
}

pub fn docx_export(pages: &[PageInfo]) -> Result<Vec<u8>> {
    let mut document = Docx::new();
    for (index, page) in pages.iter().enumerate() {
        for line in page.text_content.lines() {
            document = document.add_paragraph(Paragraph::new().add_run(Run::new().add_text(line)));
        }
        if index + 1 < pages.len() {
            document = document.add_paragraph(
                Paragraph::new().add_run(Run::new().add_break(docx_rs::BreakType::Page)),
            );
        }
    }
    let mut cursor = std::io::Cursor::new(Vec::new());
    document.build().pack(&mut cursor)?;
    Ok(cursor.into_inner())
}

/// Render in page order with annotations. PNG bytes are also used verbatim in
/// Markdown resources so the two fidelity exports share the same page appearance.
pub fn layout_pages(bytes: &[u8], pages: &[u16]) -> Result<Vec<Vec<u8>>> {
    ensure!(!pages.is_empty() && pages.len() <= 1000, "PAGE_LIMIT");
    with_pdfium(|pdfium| {
        let document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        let mut images = Vec::new();
        let mut total_bytes = 0usize;
        for index in pages {
            let page = document.pages().get(i32::from(*index))?;
            let image = page
                .render_with_config(
                    &PdfRenderConfig::new()
                        .set_target_width(2400)
                        .set_maximum_height(4096),
                )?
                .as_image()?;
            let mut buffer = std::io::Cursor::new(Vec::new());
            image.write_to(&mut buffer, image::ImageFormat::Png)?;
            let png = buffer.into_inner();
            total_bytes += png.len();
            ensure!(total_bytes <= 256 * 1024 * 1024, "EXPORT_SIZE_LIMIT");
            images.push(png);
        }
        Ok(images)
    })
}

/// One full-page anchored image per section. Individual sections preserve mixed
/// portrait/landscape page sizes. Tiny anchor paragraphs cannot add blank pages.
pub fn layout_docx(pages: &[PageInfo], images: &[Vec<u8>]) -> Result<Vec<u8>> {
    use docx_rs::*;
    ensure!(
        !pages.is_empty() && pages.len() == images.len(),
        "INVALID_EXPORT_PAGES"
    );
    let margin = PageMargin::new()
        .top(0)
        .bottom(0)
        .left(0)
        .right(0)
        .header(0)
        .footer(0);
    let mut document = Docx::new();
    for (index, (page, image)) in pages.iter().zip(images).enumerate() {
        // Word's maximum paper size is 22 inches. Scale oversized PDF pages
        // proportionally; the visible composition remains unchanged.
        let scale = (1584. / page.width.max(page.height)).min(1.);
        let width = (page.width * scale * 20.).round() as u32;
        let height = (page.height * scale * 20.).round() as u32;
        let picture = Pic::new(image)
            .size(width * 635, height * 635)
            .floating()
            .position_h(DrawingPosition::Offset(0))
            .position_v(DrawingPosition::Offset(0))
            .relative_from_h(RelativeFromHType::Page)
            .relative_from_v(RelativeFromVType::Page);
        let paragraph = Paragraph::new()
            .add_run(Run::new().add_image(picture).size(2))
            .line_spacing(
                LineSpacing::new()
                    .before(0)
                    .after(0)
                    .line(1)
                    .line_rule(LineSpacingType::Exact),
            );
        if index + 1 == pages.len() {
            document = document
                .add_paragraph(paragraph)
                .page_size(width, height)
                .page_margin(margin.clone());
        } else {
            document = document.add_section(
                Section::new()
                    .page_size(PageSize::new().size(width, height))
                    .page_margin(margin.clone())
                    .add_paragraph(paragraph),
            );
        }
    }
    let mut output = std::io::Cursor::new(Vec::new());
    document.build().pack(&mut output)?;
    Ok(output.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn markdown_and_docx_create_reopenable_text_pdfs() -> Result<()> {
        assert_eq!(inspect(&blank_document()?, None)?.len(), 1);
        let blocks =
            markdown_blocks("# A title\n\nA paragraph with 123.\n\n- First item\n- Second item");
        assert!(blocks[0].size > blocks[1].size);
        let output = text_to_pdf(&blocks, None)?;
        let pages = inspect(&output, None)?;
        assert!(pages[0].text_content.contains("A title"));
        let word = docx_export(&pages)?;
        let imported = docx_blocks(&word)?;
        assert!(imported.iter().any(|block| block.text.contains("123")));
        let output = text_to_pdf(&imported, None)?;
        assert!(inspect(&output, None)?[0].text_content.contains("123"));
        Ok(())
    }
}
