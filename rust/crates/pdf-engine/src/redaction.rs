//! Explicit raster-copy redaction. No source PDF objects or document metadata
//! are copied into the output; every page is freshly encoded from pixels.
use super::*;

pub fn export(bytes: &[u8], target: u16, areas: &[[f32; 4]]) -> Result<Vec<u8>> {
    ensure!(
        !areas.is_empty() && areas.len() <= 100,
        "REDACTION_REGION_REQUIRED"
    );
    for [left, top, right, bottom] in areas {
        ensure!(
            [left, top, right, bottom]
                .iter()
                .all(|v| v.is_finite() && (0.0..=1.0).contains(*v))
                && right > left
                && bottom > top,
            "INVALID_REDACTION_REGION"
        );
    }
    with_pdfium(|pdfium| {
        let source = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        ensure!(i32::from(target) < source.pages().len(), "PAGE_NOT_FOUND");
        ensure!(
            source.pages().len() <= 50,
            "REDACTION_PAGE_LIMIT: maximum 50 pages per raster copy"
        );
        let mut result = pdfium.create_new_pdf()?;
        let mut pixels = 0u64;
        for (index, page) in source.pages().iter().enumerate() {
            let mut image = page
                .render_with_config(
                    &PdfRenderConfig::new()
                        .set_target_width(1600)
                        .set_maximum_height(2400),
                )?
                .as_image()?
                .to_rgba8();
            pixels += u64::from(image.width()) * u64::from(image.height());
            ensure!(pixels <= 80_000_000, "REDACTION_PIXEL_LIMIT");
            if index == usize::from(target) {
                for [left, top, right, bottom] in areas {
                    // Round outward and include two pixels to remove antialiasing at the boundary.
                    let x0 = ((*left * image.width() as f32).floor() as u32).saturating_sub(2);
                    let y0 = ((*top * image.height() as f32).floor() as u32).saturating_sub(2);
                    let x1 = ((*right * image.width() as f32).ceil() as u32 + 2).min(image.width());
                    let y1 =
                        ((*bottom * image.height() as f32).ceil() as u32 + 2).min(image.height());
                    for y in y0..y1 {
                        for x in x0..x1 {
                            image.put_pixel(x, y, image::Rgba([0, 0, 0, 255]));
                        }
                    }
                }
            }
            let mut output = result
                .pages_mut()
                .create_page_at_end(PdfPagePaperSize::Custom(page.width(), page.height()))?;
            output.objects_mut().create_image_object(
                PdfPoints::ZERO,
                PdfPoints::ZERO,
                &image::DynamicImage::ImageRgba8(image),
                Some(page.width()),
                Some(page.height()),
            )?;
            output.regenerate_content()?;
        }
        let output = result.save_to_bytes()?;
        let reopened = pdfium.load_pdf_from_byte_slice(&output, None)?;
        ensure!(
            reopened.pages().len() == source.pages().len(),
            "REDACTION_VERIFICATION_FAILED"
        );
        for page in reopened.pages().iter() {
            ensure!(
                page.text()?.all().trim().is_empty()
                    && page.objects().len() == 1
                    && page.objects().get(0)?.as_image_object().is_some()
                    && page.annotations().is_empty(),
                "REDACTION_VERIFICATION_FAILED"
            );
        }
        drop(reopened);
        Ok(output)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raster_copy_has_no_old_text_or_annotations_and_region_pixels_are_removed() -> Result<()> {
        let source = create_fixture()?;
        let output = export(&source, 0, &[[0.05, 0.05, 0.5, 0.2]])?;
        assert!(!String::from_utf8_lossy(&output).contains("Hello PDF Editor"));
        assert!(inspect(&output, None)?[0].text_content.trim().is_empty());
        with_pdfium(|pdfium| {
            let document = pdfium.load_pdf_from_byte_slice(&output, None)?;
            let image = document
                .pages()
                .get(0)?
                .render_with_config(&PdfRenderConfig::new().set_target_width(1000))?
                .as_image()?
                .to_rgba8();
            let black = image.get_pixel(image.width() / 4, image.height() / 10);
            assert!(black.0[..3].iter().all(|v| *v < 5));
            let white = image.get_pixel(image.width() * 3 / 4, image.height() / 2);
            assert!(white.0[..3].iter().all(|v| *v > 250));
            Ok(())
        })?;
        assert!(export(&source, 0, &[]).is_err());
        Ok(())
    }
}
