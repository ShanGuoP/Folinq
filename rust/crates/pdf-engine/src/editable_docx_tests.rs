use super::*;
use std::io::Read;

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
