use super::*;

pub fn list(bytes: &[u8], page_index: u16) -> Result<String> {
    with_pdfium(|pdfium| {
        let document = pdfium.load_pdf_from_byte_slice(bytes, None)?;
        let page = document.pages().get(i32::from(page_index))?;
        let annotations: Vec<_> = page.annotations().iter().enumerate().map(|(index, annotation)| {
            serde_json::json!({"index": index, "kind": format!("{:?}", annotation.annotation_type()),
                "text": annotation.contents().unwrap_or_default(),
                "removable": !matches!(annotation.annotation_type(), PdfPageAnnotationType::Widget | PdfPageAnnotationType::XfaWidget | PdfPageAnnotationType::Link)})
        }).collect();
        Ok(serde_json::to_string(&annotations)?)
    })
}
