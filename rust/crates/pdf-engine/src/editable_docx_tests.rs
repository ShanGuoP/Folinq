use super::*;
use std::io::Read;

#[test]
fn split_headers_and_footers_with_changing_page_numbers_are_optional() -> Result<()> {
    let source = with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let font = document.fonts_mut().helvetica();
        for index in 1..=3 {
            let mut page = document
                .pages_mut()
                .create_page_at_end(PdfPagePaperSize::a4())?;
            for (text, x, y) in [
                ("Company Confidential".to_owned(), 50., 820.),
                (format!("Page {index}"), 470., 820.),
                ("Internal Use".to_owned(), 50., 20.),
                (format!("Footer {index}"), 470., 20.),
                ("Company Confidential".to_owned(), 50., 420.),
                (format!("Body page {index}"), 50., 400.),
            ] {
                page.objects_mut().create_text_object(
                    PdfPoints::new(x),
                    PdfPoints::new(y),
                    text,
                    font,
                    PdfPoints::new(12.),
                )?;
            }
        }
        Ok(document.save_to_bytes()?)
    })?;
    let keep = markdown(&source, &[0, 1, 2], "assets", false)?.text;
    assert_eq!(keep.matches("Company Confidential").count(), 6);
    assert_eq!(keep.matches("Internal Use").count(), 3);
    let clean = markdown(&source, &[0, 1, 2], "assets", true)?.text;
    assert_eq!(clean.matches("Company Confidential").count(), 3);
    for page in 1..=3 {
        assert!(!clean.contains(&format!("Page {page}")));
        assert!(!clean.contains(&format!("Footer {page}")));
        assert!(clean.contains(&format!("Body page {page}")));
    }
    assert!(!clean.contains("Internal Use"));
    let kept_docx = docx_xml(flow_docx(&source, &[0, 1, 2], false)?)?;
    let clean_docx = docx_xml(flow_docx(&source, &[0, 1, 2], true)?)?;
    assert_eq!(kept_docx.matches("Company Confidential").count(), 6);
    assert_eq!(clean_docx.matches("Company Confidential").count(), 3);
    assert!(!clean_docx.contains("Internal Use") && !clean_docx.contains("Footer 2"));
    // A single selected page provides no evidence of repetition.
    assert!(
        markdown(&source, &[1], "assets", true)?
            .text
            .contains("Page 2")
    );
    Ok(())
}

#[test]
fn markdown_preserves_literal_entities_in_body_and_table_cells() -> Result<()> {
    let literal = "alpha &copy; beta &lt; gamma &#169; &#xA9; &amp; <tag> > &";
    let source = with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let font = document.fonts_mut().helvetica();
        let mut page = document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        for y in [700., 600.] {
            page.objects_mut().create_text_object(
                PdfPoints::new(50.),
                PdfPoints::new(y),
                literal,
                font,
                PdfPoints::new(8.),
            )?;
        }
        for y in [580., 630.] {
            page.objects_mut().create_path_object_line(
                PdfPoints::new(40.),
                PdfPoints::new(y),
                PdfPoints::new(560.),
                PdfPoints::new(y),
                PdfColor::BLACK,
                PdfPoints::new(1.),
            )?;
        }
        for x in [40., 560.] {
            page.objects_mut().create_path_object_line(
                PdfPoints::new(x),
                PdfPoints::new(580.),
                PdfPoints::new(x),
                PdfPoints::new(630.),
                PdfColor::BLACK,
                PdfPoints::new(1.),
            )?;
        }
        drop(page);
        Ok(document.save_to_bytes()?)
    })?;
    let output = markdown(&source, &[0], "assets", false)?.text;
    assert!(output.contains("| --- |"), "{output}");
    let rendered = pulldown_cmark::Parser::new_ext(&output, pulldown_cmark::Options::ENABLE_TABLES)
        .filter_map(|event| match event {
            pulldown_cmark::Event::Text(text) => Some(text.into_string()),
            _ => None,
        })
        .collect::<String>();
    assert_eq!(rendered.matches(literal).count(), 2, "{output}\n{rendered}");
    Ok(())
}

fn rich_pdf() -> Result<Vec<u8>> {
    with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let regular = document.fonts_mut().helvetica();
        let bold = document.fonts_mut().helvetica_bold();
        let italic = document.fonts_mut().helvetica_oblique();
        let mut page = document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        let mut title = page.objects_mut().create_text_object(
            PdfPoints::new(50.),
            PdfPoints::new(760.),
            "Formatted title & <editable>",
            bold,
            PdfPoints::new(24.),
        )?;
        title.set_fill_color(PdfColor::new(30, 70, 90, 255))?;
        drop(title);
        let mut shade = PdfPagePathObject::new(
            &document,
            PdfPoints::new(50.),
            PdfPoints::new(650.),
            None,
            None,
            Some(PdfColor::new(166, 166, 166, 255)),
        )?;
        shade.rect_to(PdfPoints::new(350.), PdfPoints::new(700.))?;
        page.objects_mut().add_path_object(shade)?;
        for (x1, y1, x2, y2) in [
            (50., 600., 350., 600.),
            (50., 650., 350., 650.),
            (50., 700., 350., 700.),
            (50., 600., 50., 700.),
            (350., 600., 350., 700.),
            (200., 600., 200., 650.),
        ] {
            // The same thin filled rules used by Word-generated PDF tables.
            let mut rule = PdfPagePathObject::new(
                &document,
                PdfPoints::new(x1 - 0.25),
                PdfPoints::new(y1 - 0.25),
                None,
                None,
                Some(PdfColor::BLACK),
            )?;
            rule.rect_to(PdfPoints::new(x2 + 0.25), PdfPoints::new(y2 + 0.25))?;
            page.objects_mut().add_path_object(rule)?;
        }
        for (x, y, value, font, size) in [
            (65., 675., "Merged header", bold, 14.),
            (65., 625., "Left cell", regular, 12.),
            (215., 625., "Right cell", italic, 12.),
        ] {
            page.objects_mut().create_text_object(
                PdfPoints::new(x),
                PdfPoints::new(y),
                value,
                font,
                PdfPoints::new(size),
            )?;
        }
        let image = image::DynamicImage::new_rgb8(30, 20);
        page.objects_mut().create_image_object(
            PdfPoints::new(400.),
            PdfPoints::new(700.),
            &image,
            Some(PdfPoints::new(60.)),
            Some(PdfPoints::new(40.)),
        )?;
        page.regenerate_content()?;
        drop(page);
        let mut landscape = document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4().landscape())?;
        landscape.objects_mut().create_text_object(
            PdfPoints::new(60.),
            PdfPoints::new(500.),
            "Landscape page",
            regular,
            PdfPoints::new(16.),
        )?;
        landscape.regenerate_content()?;
        drop(landscape);
        Ok(document.save_to_bytes()?)
    })
}

#[test]
fn formatted_export_has_real_runs_merged_tables_shading_and_original_image() -> Result<()> {
    let source = rich_pdf()?;
    let output = export(&source, &[0, 1])?;
    let mut archive = zip::ZipArchive::new(Cursor::new(output))?;
    let mut xml = String::new();
    archive
        .by_name("word/document.xml")?
        .read_to_string(&mut xml)?;
    assert!(xml.contains("Formatted title &amp; &lt;editable&gt;"));
    assert!(
        xml.contains("Merged header") && xml.contains("Left cell") && xml.contains("Right cell")
    );
    assert!(xml.contains("<w:b/>"), "bold missing");
    assert!(xml.contains("<w:i/>"), "italic missing");
    assert!(xml.contains("w:val=\"48\""), "size missing");
    assert!(xml.contains("w:val=\"1E465A\"") && xml.contains("w:fill=\"A6A6A6\""));
    assert!(xml.contains("<w:gridSpan w:val=\"2\"/>") && xml.contains("<w:tbl>"));
    assert_eq!(xml.matches("<w:sectPr>").count(), 2);
    assert!(xml.find("Formatted title").unwrap() < xml.find("Landscape page").unwrap());
    let media: Vec<_> = archive
        .file_names()
        .filter(|n| n.starts_with("word/media/"))
        .map(str::to_owned)
        .collect();
    assert_eq!(media.len(), 1);
    let mut png = Vec::new();
    archive.by_name(&media[0])?.read_to_end(&mut png)?;
    let image = image::load_from_memory(&png)?;
    assert!(image.width() <= 100 && image.height() <= 100);
    // Native text is also recoverable by the application's DOCX text importer.
    let text = crate::conversion::docx_blocks(archive.into_inner().get_ref())?;
    assert!(text.iter().any(|b| b.text.contains("Merged header")));
    Ok(())
}

fn docx_xml(bytes: Vec<u8>) -> Result<String> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))?;
    let mut xml = String::new();
    archive
        .by_name("word/document.xml")?
        .read_to_string(&mut xml)?;
    Ok(xml)
}

#[test]
fn structured_markdown_keeps_text_merged_cells_and_original_picture() -> Result<()> {
    let source = rich_pdf()?;
    let output = markdown(&source, &[0, 1], "assets", false)?;
    for value in [
        "Formatted title",
        "Merged header",
        "Left cell",
        "Right cell",
        "Landscape page",
    ] {
        assert_eq!(output.text.matches(value).count(), 1, "{value}");
    }
    assert!(output.text.contains("<table>") && output.text.contains("colspan=\"2\""));
    assert!(output.text.contains("![图片 1](assets/image-0001.png)"));
    assert_eq!(output.images.len(), 1);
    assert!(image::load_from_memory(&output.images[0])?.width() <= 100);
    assert!(!output.text.contains("page-0001.png"));
    assert!(markdown(&source, &[], "assets", false).is_err());
    assert!(markdown(&source, &[0], "../unsafe", false).is_err());
    let reversed = markdown(&source, &[1, 0], "assets", false)?;
    assert!(reversed.text.starts_with("<!-- page 2 -->"));
    assert!(reversed.text.find("Landscape page") < reversed.text.find("Formatted title"));
    let flow = docx_xml(flow_docx(&source, &[0, 1], false)?)?;
    assert!(flow.contains("<w:tbl>") && flow.contains("<w:gridSpan w:val=\"2\"/>"));
    assert!(flow.contains("Heading") && flow.contains("<wp:inline"));
    for fixed in ["w:framePr", "w:tblpPr", "w:fitText", "w:hRule=\"exact\""] {
        assert!(!flow.contains(fixed), "flow contains fixed layout: {fixed}");
    }
    Ok(())
}

fn structured_pdf() -> Result<Vec<u8>> {
    with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let regular = document.fonts_mut().helvetica();
        let bold = document.fonts_mut().helvetica_bold();
        for number in 1..=3 {
            let mut page = document
                .pages_mut()
                .create_page_at_end(PdfPagePaperSize::a4())?;
            for (x, y, value, size, font) in [
                (50., 820., "Company Confidential".to_string(), 9., regular),
                (
                    50.,
                    760.,
                    "Full width document heading".to_string(),
                    24.,
                    bold,
                ),
                (50., 680., "left first line".to_string(), 12., regular),
                (50., 660., "left continuation".to_string(), 12., regular),
                (320., 680., "right first line".to_string(), 12., regular),
                (320., 660., "right continuation".to_string(), 12., regular),
                (50., 590., "1. First list item".to_string(), 12., regular),
                (50., 568., "2. Second list item".to_string(), 12., regular),
                (50., 25., format!("Page {number}"), 9., regular),
            ] {
                page.objects_mut().create_text_object(
                    PdfPoints::new(x),
                    PdfPoints::new(y),
                    value,
                    font,
                    PdfPoints::new(size),
                )?;
            }
            page.regenerate_content()?;
        }
        Ok(document.save_to_bytes()?)
    })
}

#[test]
fn reading_order_paragraphs_lists_and_optional_repeated_margins() -> Result<()> {
    let source = structured_pdf()?;
    let keep = markdown(&source, &[0, 1, 2], "assets", false)?;
    assert_eq!(keep.text.matches("Company Confidential").count(), 3);
    let clean = markdown(&source, &[0, 1, 2], "assets", true)?;
    assert!(!clean.text.contains("Company Confidential") && !clean.text.contains("Page 1"));
    assert!(clean.text.contains("# Full width document heading"));
    assert!(clean.text.contains("left first line left continuation"));
    assert!(clean.text.find("left continuation") < clean.text.find("right first line"));
    assert!(
        clean.text.contains("1. First list item") && clean.text.contains("2. Second list item")
    );
    assert!(clean.images.is_empty());
    let docx = flow_docx(&source, &[0, 1, 2], true)?;
    let xml = docx_xml(docx.clone())?;
    assert!(!xml.contains("Company Confidential"));
    assert!(xml.contains("left first line") && xml.contains("left continuation"));
    assert!(xml.contains("<w:pStyle w:val=\"Heading1\"/>") && xml.contains("<w:numPr>"));
    let mut zip = zip::ZipArchive::new(Cursor::new(docx))?;
    let mut numbering = String::new();
    zip.by_name("word/numbering.xml")?
        .read_to_string(&mut numbering)?;
    assert!(numbering.contains("decimal") && numbering.contains("<w:start w:val=\"1\"/>"));
    if let Some(directory) = std::env::var_os("PDF_EXPORT_QA_DIR") {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(&directory)?;
        std::fs::write(directory.join("structured-source.pdf"), &source)?;
        std::fs::write(directory.join("structured.md"), &clean.text)?;
        std::fs::write(
            directory.join("structured-flow.docx"),
            flow_docx(&source, &[0, 1, 2], true)?,
        )?;
    }
    Ok(())
}

#[test]
fn picture_layering_distinguishes_background_from_foreground_text() -> Result<()> {
    let source = with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let font = document.fonts_mut().helvetica();
        let mut page = document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        page.objects_mut().create_text_object(
            PdfPoints::new(70.),
            PdfPoints::new(670.),
            "UNDER IMAGE",
            font,
            PdfPoints::new(18.),
        )?;
        let image = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            100,
            60,
            image::Rgb([20, 70, 180]),
        ));
        page.objects_mut().create_image_object(
            PdfPoints::new(50.),
            PdfPoints::new(640.),
            &image,
            Some(PdfPoints::new(250.)),
            Some(PdfPoints::new(80.)),
        )?;
        let mut top = page.objects_mut().create_text_object(
            PdfPoints::new(70.),
            PdfPoints::new(680.),
            "ON TOP",
            font,
            PdfPoints::new(18.),
        )?;
        top.set_fill_color(PdfColor::WHITE)?;
        drop(top);
        page.regenerate_content()?;
        drop(page);
        Ok(document.save_to_bytes()?)
    })?;
    let layouts = extract(&source, &[0])?;
    let layout = &layouts[0];
    let image = &layout.images[0];
    assert!(layout.glyphs.iter().any(|g| g.order < image.order));
    assert!(layout.glyphs.iter().any(|g| g.order > image.order));
    let output = export(&source, &[0])?;
    let xml = docx_xml(output.clone())?;
    assert!(xml.contains("behindDoc=\"0\""));
    assert!(xml.contains("<w:txbxContent>") && xml.contains("ON TOP"));
    if let Some(directory) = std::env::var_os("PDF_EXPORT_QA_DIR") {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(&directory)?;
        std::fs::write(directory.join("layers-source.pdf"), source)?;
        std::fs::write(directory.join("layers-layout.docx"), output)?;
    }
    Ok(())
}

#[test]
fn selected_page_order_is_preserved_and_invalid_selection_fails() -> Result<()> {
    let source = rich_pdf()?;
    let output = export(&source, &[1, 0])?;
    let mut archive = zip::ZipArchive::new(Cursor::new(output))?;
    let mut xml = String::new();
    archive
        .by_name("word/document.xml")?
        .read_to_string(&mut xml)?;
    assert!(xml.find("Landscape page").unwrap() < xml.find("Formatted title").unwrap());
    assert!(export(&source, &[9]).is_err());
    assert!(export(&source, &[]).is_err());
    Ok(())
}

#[test]
fn image_only_scan_is_not_misrepresented_as_editable_word() -> Result<()> {
    let scan = with_pdfium(|pdfium| {
        let mut document = pdfium.create_new_pdf()?;
        let mut page = document
            .pages_mut()
            .create_page_at_end(PdfPagePaperSize::a4())?;
        page.objects_mut().create_image_object(
            PdfPoints::ZERO,
            PdfPoints::ZERO,
            &image::DynamicImage::new_rgb8(60, 80),
            Some(PdfPoints::new(595.)),
            Some(PdfPoints::new(842.)),
        )?;
        page.regenerate_content()?;
        drop(page);
        Ok(document.save_to_bytes()?)
    })?;
    assert!(
        export(&scan, &[0])
            .unwrap_err()
            .to_string()
            .contains("EDITABLE_TEXT_REQUIRED")
    );
    Ok(())
}

#[test]
fn stamp_appearance_is_preserved_as_a_positioned_graphic() -> Result<()> {
    let bytes = with_pdfium(stamp_pdf)?;
    let layouts = extract(&bytes, &[0])?;
    assert_eq!(layouts[0].images.len(), 1);
    let image = &layouts[0].images[0];
    assert!((image.x - 200.).abs() < 1. && (image.width - 60.).abs() < 1.);
    assert!((image.y - (layouts[0].height - 100.)).abs() < 1.);
    let output = export(&bytes, &[0])?;
    let mut archive = zip::ZipArchive::new(Cursor::new(output))?;
    assert_eq!(
        archive
            .file_names()
            .filter(|n| n.starts_with("word/media/"))
            .count(),
        1
    );
    let mut xml = String::new();
    archive
        .by_name("word/document.xml")?
        .read_to_string(&mut xml)?;
    assert!(xml.contains("Editable text"));
    Ok(())
}

fn stamp_pdf(pdfium: &Pdfium) -> Result<Vec<u8>> {
    let mut document = pdfium.create_new_pdf()?;
    let font = document.fonts_mut().helvetica();
    let mut page = document
        .pages_mut()
        .create_page_at_end(PdfPagePaperSize::a4())?;
    page.objects_mut().create_text_object(
        PdfPoints::new(50.),
        PdfPoints::new(700.),
        "Editable text",
        font,
        PdfPoints::new(12.),
    )?;
    let mut stamp = page.annotations_mut().create_stamp_annotation()?;
    stamp.objects_mut().create_image_object(
        PdfPoints::new(20.),
        PdfPoints::new(30.),
        &image::DynamicImage::new_rgb8(60, 20),
        Some(PdfPoints::new(60.)),
        Some(PdfPoints::new(20.)),
    )?;
    stamp.set_position(PdfPoints::new(200.), PdfPoints::new(80.))?;
    stamp.set_width(PdfPoints::new(60.))?;
    stamp.set_height(PdfPoints::new(20.))?;
    page.regenerate_content()?;
    drop(page);
    Ok(document.save_to_bytes()?)
}
