//! Untrusted OCR results become private, bounded export files, never PDF edits.
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
struct Request {
    format: String,
    pages: Vec<Page>,
}
#[derive(Deserialize)]
struct Page {
    markdown: String,
    #[serde(default)]
    images: BTreeMap<String, String>,
}

fn safe_image_path(name: &str) -> bool {
    name.len() <= 240
        && name.split('/').all(|part| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && part
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
        })
}

pub(crate) fn prepare(directory: &Path, json: &str) -> Result<PathBuf> {
    ensure!(json.len() <= 96 * 1024 * 1024, "OCR_RESULT_LIMIT");
    let request: Request = serde_json::from_str(json)?;
    ensure!(
        !request.pages.is_empty() && request.pages.len() <= 100,
        "OCR_PAGE_LIMIT"
    );
    ensure!(
        ["md", "txt", "docx"].contains(&request.format.as_str()),
        "INVALID_EXPORT_FORMAT"
    );
    let mut markdown = String::new();
    let mut word_pages = Vec::new();
    let mut resources = BTreeMap::new();
    let mut total = 0usize;
    for (index, page) in request.pages.into_iter().enumerate() {
        if request.format == "docx" {
            word_pages.push((page.markdown.clone(), format!("page-{:04}/", index + 1)));
        }
        let mut text = page.markdown;
        ensure!(
            text.len() <= 8 * 1024 * 1024 && page.images.len() <= 500,
            "OCR_RESULT_LIMIT"
        );
        let mut images: Vec<_> = page.images.into_iter().collect();
        images.sort_by_key(|(name, _)| std::cmp::Reverse(name.len()));
        for (name, value) in images {
            ensure!(safe_image_path(&name), "OCR_UNSAFE_IMAGE_PATH");
            let bytes = STANDARD.decode(value).context("OCR_INVALID_IMAGE")?;
            total += bytes.len();
            ensure!(total <= 64 * 1024 * 1024, "OCR_RESULT_LIMIT");
            // Only permit image resources, even when the service assigns arbitrary extensions.
            ensure!(
                bytes.starts_with(b"\x89PNG\r\n\x1a\n") || bytes.starts_with(b"\xff\xd8\xff"),
                "OCR_INVALID_IMAGE"
            );
            let target = format!("page-{:04}/{name}", index + 1);
            text = text
                .replace(&format!("]({name})"), &format!("]({target})"))
                .replace(&format!("\"{name}\""), &format!("\"{target}\""))
                .replace(&format!("'{name}'"), &format!("'{target}'"));
            resources.insert(target, bytes);
        }
        if index > 0 {
            markdown.push_str("\n\n---\n\n");
        }
        markdown.push_str(&text);
        ensure!(markdown.len() <= 16 * 1024 * 1024, "OCR_RESULT_LIMIT");
    }
    ensure!(!markdown.trim().is_empty(), "OCR_EMPTY_RESULT");
    let extension = if request.format == "md" {
        "zip"
    } else {
        &request.format
    };
    let path = directory.join(format!("document.{extension}"));
    if request.format == "md" {
        let mut archive = zip::ZipWriter::new(fs::File::create(&path)?);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        archive.start_file("document.md", options)?;
        archive.write_all(markdown.as_bytes())?;
        for (name, bytes) in resources {
            archive.start_file(name, options)?;
            archive.write_all(&bytes)?;
        }
        archive.finish()?.sync_all()?;
    } else {
        let bytes = if request.format == "txt" {
            pdf_engine::conversion::ocr_text_exports(&markdown)?
                .0
                .into_bytes()
        } else {
            pdf_engine::ocr_docx::export_pages(&word_pages, &resources)?
        };
        let mut file = fs::File::create(&path)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    #[test]
    fn packages_page_images_without_collisions_and_rejects_traversal() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let image = STANDARD.encode(b"\x89PNG\r\n\x1a\nfixture");
        let page = serde_json::json!({"markdown":"# Title\n\n![pic](imgs/a.png)","images":{"imgs/a.png":image}});
        let request = serde_json::json!({"format":"md","pages":[page.clone(),page]});
        let path = prepare(dir.path(), &request.to_string())?;
        let mut zip = zip::ZipArchive::new(fs::File::open(path)?)?;
        let mut text = String::new();
        zip.by_name("document.md")?.read_to_string(&mut text)?;
        assert!(text.contains("](page-0001/imgs/a.png)"));
        assert!(text.contains("](page-0002/imgs/a.png)"));
        assert!(zip.by_name("page-0002/imgs/a.png").is_ok());
        let bad = serde_json::json!({"format":"md","pages":[{"markdown":"text","images":{"../escape.png":image}}]});
        assert!(prepare(dir.path(), &bad.to_string()).is_err());
        Ok(())
    }
    #[test]
    fn word_keeps_same_named_page_images_and_native_structure() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP438EAAAQRAYhxoDirAAAAAElFTkSuQmCC";
        let first = serde_json::json!({"markdown":"# Heading\n\n**bold**\n\n![picture](imgs/a.png \"caption\")", "images":{"imgs/a.png":image}});
        let second = serde_json::json!({"markdown":"<table\n border=1>\n<tr>\n<td nowrap>R&D</td>\n<td><img src='imgs/a.png'></td>\n</tr>\n</table>", "images":{"imgs/a.png":image}});
        let path = prepare(
            dir.path(),
            &serde_json::json!({"format":"docx","pages":[first,second]}).to_string(),
        )?;
        let mut zip = zip::ZipArchive::new(fs::File::open(path)?)?;
        let mut xml = String::new();
        zip.by_name("word/document.xml")?.read_to_string(&mut xml)?;
        assert!(xml.contains("Heading1") && xml.contains("<w:b") && xml.contains("<w:tbl>"));
        assert_eq!(xml.matches("<w:drawing>").count(), 2);
        assert!(xml.contains("w:type=\"page\""));
        assert_eq!(
            zip.file_names()
                .filter(|n| n.starts_with("word/media/"))
                .count(),
            2
        );
        Ok(())
    }
    #[test]
    fn missing_word_image_does_not_create_output() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let request =
            serde_json::json!({"format":"docx","pages":[{"markdown":"![picture](missing.png)"}]})
                .to_string();
        assert!(prepare(dir.path(), &request).is_err());
        assert!(!dir.path().join("document.docx").exists());
        Ok(())
    }
}
