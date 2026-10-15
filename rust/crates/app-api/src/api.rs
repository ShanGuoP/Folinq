//! Async flutter_rust_bridge endpoints. JSON keeps the initial DTO contract small;
//! all mutable document state and native handles remain on the Rust side.
use crate::session::Session;
use anyhow::{Context, Result};
use std::{
    collections::HashMap,
    path::Path,
    sync::{Mutex, OnceLock},
};

static SESSIONS: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
type Cancellations = HashMap<String, std::sync::Arc<std::sync::atomic::AtomicBool>>;
static OCR_TASKS: OnceLock<Mutex<Cancellations>> = OnceLock::new();

pub fn cancel_task(document_id: String) -> Result<bool> {
    let tasks = OCR_TASKS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow::anyhow!("TASK_LOCK_POISONED"))?;
    if let Some(cancel) = tasks.get(&document_id) {
        cancel.store(true, std::sync::atomic::Ordering::Relaxed);
        return Ok(true);
    }
    Ok(false)
}

struct OcrTask(String);
impl Drop for OcrTask {
    fn drop(&mut self) {
        if let Ok(mut tasks) = OCR_TASKS.get_or_init(|| Mutex::new(HashMap::new())).lock() {
            tasks.remove(&self.0);
        }
    }
}

fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn open_document(source: String, workspace: String) -> Result<String> {
    let session = Session::open(Path::new(&source), Path::new(&workspace))?;
    let json = serde_json::to_string(&session.info)?;
    sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?
        .insert(session.info.id.clone(), session);
    Ok(json)
}

pub fn create_document(
    sources: Vec<String>,
    workspace: String,
    font_path: Option<String>,
) -> Result<String> {
    anyhow::ensure!(sources.len() <= 1000, "INPUT_LIMIT");
    for path in &sources {
        anyhow::ensure!(
            std::fs::metadata(path)?.len() <= 64 * 1024 * 1024,
            "FILE_LIMIT"
        );
    }
    let source_name = sources.first().map(String::as_str).unwrap_or("未命名.pdf");
    let extension = Path::new(source_name)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    let bytes = if sources.is_empty() {
        pdf_engine::conversion::blank_document()?
    } else if ["png", "jpg", "jpeg"].contains(&extension.as_str()) {
        anyhow::ensure!(
            sources.iter().all(|p| Path::new(p)
                .extension()
                .and_then(|s| s.to_str())
                .is_some_and(|e| ["png", "jpg", "jpeg"].contains(&e.to_lowercase().as_str()))),
            "MIXED_IMAGE_INPUT"
        );
        pdf_engine::conversion::images_to_pdf(&sources)?
    } else {
        anyhow::ensure!(sources.len() == 1, "ONE_DOCUMENT_REQUIRED");
        let source = std::fs::read(&sources[0])?;
        let blocks = match extension.as_str() {
            "md" | "markdown" => {
                pdf_engine::conversion::markdown_blocks(std::str::from_utf8(&source)?)
            }
            "txt" => vec![pdf_engine::conversion::TextBlock {
                text: String::from_utf8(source)?,
                size: 12.,
            }],
            "docx" => pdf_engine::conversion::docx_blocks(&source)?,
            _ => anyhow::bail!("UNSUPPORTED_INPUT_FORMAT"),
        };
        let font = if blocks.iter().all(|block| block.text.is_ascii()) {
            None
        } else {
            font_path.as_deref()
        };
        pdf_engine::conversion::text_to_pdf(&blocks, font)?
    };
    pdf_engine::inspect(&bytes, None)?;
    let import_dir = Path::new(&workspace).join("imports");
    std::fs::create_dir_all(&import_dir)?;
    let file = import_dir.join(format!(
        "{}-{}.pdf",
        Path::new(source_name)
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy(),
        uuid::Uuid::new_v4()
    ));
    std::fs::write(&file, bytes)?;
    open_document(file.to_string_lossy().into(), workspace)
}

pub fn document_command(
    document_id: String,
    expected_version: u64,
    command: String,
    object_id: String,
    value: String,
) -> Result<String> {
    let mut sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    let session = sessions.get_mut(&document_id).context("DOCUMENT_CLOSED")?;
    match command.as_str() {
        "replace_text" => session.replace(expected_version, &object_id, &value)?,
        "replace_text_options" => {
            let request: serde_json::Value = serde_json::from_str(&value)?;
            let options = serde_json::from_value(
                request
                    .get("options")
                    .cloned()
                    .unwrap_or(serde_json::json!({})),
            )?;
            session.replace_with_options(
                expected_version,
                &object_id,
                request
                    .get("text")
                    .and_then(|v| v.as_str())
                    .context("INVALID_TEXT")?,
                &options,
            )?;
        }
        "restore_version" => {
            let request: serde_json::Value = serde_json::from_str(&value)?;
            session.restore_version(
                expected_version,
                request["session_id"]
                    .as_str()
                    .context("INVALID_DOCUMENT_ID")?,
                request["version"]
                    .as_u64()
                    .context("INVALID_HISTORY_VERSION")?,
            )?;
        }
        "page_operation" => {
            session.page_operation(expected_version, serde_json::from_str(&value)?)?
        }
        "object_operation" => {
            session.object_operation(expected_version, serde_json::from_str(&value)?)?
        }
        "export" => {
            let request: serde_json::Value = serde_json::from_str(&value)?;
            let pages: Vec<u16> = serde_json::from_value(
                request
                    .get("pages")
                    .cloned()
                    .unwrap_or(serde_json::json!([])),
            )?;
            session.export(
                expected_version,
                request["format"].as_str().context("INVALID_EXPORT")?,
                Path::new(request["destination"].as_str().context("INVALID_EXPORT")?),
                &pages,
            )?;
        }
        "redact_export" => {
            let request: serde_json::Value = serde_json::from_str(&value)?;
            let page: u16 = serde_json::from_value(request["page"].clone())?;
            let areas: Vec<[f32; 4]> = serde_json::from_value(request["areas"].clone())?;
            session.redact_export(
                expected_version,
                page,
                &areas,
                Path::new(request["destination"].as_str().context("INVALID_EXPORT")?),
            )?;
        }
        "ocr_layer" => {
            let request: serde_json::Value = serde_json::from_str(&value)?;
            let page: u16 = serde_json::from_value(request["page"].clone())?;
            session.add_ocr_layer(
                expected_version,
                page,
                request["language"].as_str().unwrap_or(""),
                request["font_path"].as_str(),
            )?;
        }
        "undo" => session.undo(expected_version)?,
        "redo" => session.redo(expected_version)?,
        "save_as" => session.save(expected_version, Path::new(&value))?,
        "save_source" => session.save_source(expected_version)?,
        "external_save_complete" => session.mark_external_saved(expected_version)?,
        _ => anyhow::bail!("UNKNOWN_COMMAND"),
    }
    Ok(serde_json::to_string(&session.info)?)
}

pub fn page_annotations(
    document_id: String,
    expected_version: u64,
    page_index: u16,
) -> Result<String> {
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    let session = sessions.get(&document_id).context("DOCUMENT_CLOSED")?;
    document_core::check_version(session.info.version, expected_version)?;
    pdf_engine::annotations::list(&session.bytes()?, page_index)
}

pub fn recognize_page(
    document_id: String,
    expected_version: u64,
    page_index: u16,
    language: String,
) -> Result<String> {
    let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let mut tasks = OCR_TASKS
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .map_err(|_| anyhow::anyhow!("TASK_LOCK_POISONED"))?;
        anyhow::ensure!(!tasks.contains_key(&document_id), "TASK_ALREADY_RUNNING");
        tasks.insert(document_id.clone(), cancelled.clone());
    }
    let _task = OcrTask(document_id.clone());
    let (preview, cache) = {
        let sessions = sessions()
            .lock()
            .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
        let session = sessions.get(&document_id).context("DOCUMENT_CLOSED")?;
        let cache = session.ocr_cache(expected_version, page_index, &language)?;
        let page = &session.info.pages[page_index as usize];
        if !page.text_content.trim().is_empty() {
            return Ok(serde_json::to_string(&document_core::OcrResult {
                provider: "native_text".into(),
                language: String::new(),
                text: page.text_content.clone(),
                width: 0,
                height: 0,
                words: vec![],
            })?);
        }
        if cache.exists() {
            return Ok(std::fs::read_to_string(cache)?);
        }
        (session.preview(expected_version, page_index)?, cache)
    };
    let result = ocr_engine::recognize_cancellable(&preview, &language, cancelled.clone())?;
    anyhow::ensure!(
        !cancelled.load(std::sync::atomic::Ordering::Relaxed),
        "TASK_CANCELLED"
    );
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    let session = sessions.get(&document_id).context("DOCUMENT_CLOSED")?;
    document_core::check_version(session.info.version, expected_version)?;
    let json = serde_json::to_string(&result)?;
    std::fs::write(cache, &json)?;
    Ok(json)
}

/// Render a library cover without opening a new editor tab.
pub fn document_cover(workspace: String, document_id: String) -> Result<String> {
    let session = Session::recover(Path::new(&workspace), &document_id)?;
    session.detail_preview(session.info.version, 0, 512)
}

pub fn document_history(document_id: String) -> Result<String> {
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    Ok(sessions
        .get(&document_id)
        .context("DOCUMENT_CLOSED")?
        .history()?
        .to_string())
}

pub fn recoverable_documents(workspace: String) -> Result<String> {
    Ok(serde_json::to_string(&Session::recoverable(Path::new(
        &workspace,
    ))?)?)
}

pub fn project_catalog(workspace: String, command: String, value: String) -> Result<String> {
    let root = Path::new(&workspace);
    let mut request: serde_json::Value = serde_json::from_str(&value)?;
    anyhow::ensure!(request.is_object(), "INVALID_PROJECT_REQUEST");
    if command == "create" {
        request["id"] = serde_json::Value::String(uuid::Uuid::new_v4().to_string());
    }
    if matches!(command.as_str(), "rename" | "delete") {
        uuid::Uuid::parse_str(request["id"].as_str().context("INVALID_PROJECT_ID")?)?;
    }
    if command == "assign" {
        let document = request["document_id"]
            .as_str()
            .context("INVALID_DOCUMENT_ID")?;
        uuid::Uuid::parse_str(document)?;
        anyhow::ensure!(
            root.join(document).join("recovery.json").is_file(),
            "DOCUMENT_NOT_FOUND"
        );
        if let Some(project) = request["project_id"].as_str() {
            uuid::Uuid::parse_str(project)?;
        }
    }
    if command == "assign" {
        let records = Session::recoverable(root)?;
        let target = records
            .iter()
            .find(|d| Some(d.id.as_str()) == request["document_id"].as_str())
            .context("DOCUMENT_NOT_FOUND")?;
        request["document_ids"] = serde_json::json!(
            records
                .iter()
                .filter(|d| Session::source_key(&d.source_path)
                    == Session::source_key(&target.source_path))
                .map(|d| d.id.clone())
                .collect::<Vec<_>>()
        );
    }
    storage::Projects::open(&root.join("projects.sqlite"))?.command(&command, &request)
}

pub fn restore_document(workspace: String, document_id: String) -> Result<String> {
    let session = Session::recover(Path::new(&workspace), &document_id)?;
    let json = serde_json::to_string(&session.info)?;
    let mut sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    anyhow::ensure!(
        !sessions.contains_key(&document_id),
        "DOCUMENT_ALREADY_OPEN"
    );
    sessions.insert(document_id, session);
    Ok(json)
}

pub fn close_document(document_id: String) -> Result<()> {
    sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?
        .remove(&document_id)
        .context("DOCUMENT_CLOSED")?;
    Ok(())
}

pub fn render_preview(
    document_id: String,
    expected_version: u64,
    page_index: u16,
) -> Result<String> {
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    sessions
        .get(&document_id)
        .context("DOCUMENT_CLOSED")?
        .preview(expected_version, page_index)
}

pub fn render_detail(
    document_id: String,
    expected_version: u64,
    page_index: u16,
    width: u32,
) -> Result<String> {
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    sessions
        .get(&document_id)
        .context("DOCUMENT_CLOSED")?
        .detail_preview(expected_version, page_index, width)
}

pub fn prepare_external_export(
    document_id: String,
    expected_version: u64,
    format: String,
    pages: Vec<u16>,
) -> Result<String> {
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    sessions
        .get(&document_id)
        .context("DOCUMENT_CLOSED")?
        .prepare_external_export(expected_version, &format, &pages)
}

pub fn view_state(
    document_id: String,
    expected_version: u64,
    value: Option<String>,
) -> Result<String> {
    let sessions = sessions()
        .lock()
        .map_err(|_| anyhow::anyhow!("SESSION_LOCK_POISONED"))?;
    sessions
        .get(&document_id)
        .context("DOCUMENT_CLOSED")?
        .view_state(expected_version, value.as_deref())
}

pub fn application_data(workspace: String, clear_cache: bool) -> Result<String> {
    let root = Path::new(&workspace);
    std::fs::create_dir_all(root)?;
    let root = root.canonicalize()?;
    let mut bytes = 0u64;
    let mut files = 0u64;
    let mut removed = 0u64;
    let mut locked = 0u64;
    for directory in std::fs::read_dir(&root)?.flatten() {
        if !directory.file_type()?.is_dir()
            || uuid::Uuid::parse_str(&directory.file_name().to_string_lossy()).is_err()
        {
            continue;
        }
        let directory = directory.path().canonicalize()?;
        anyhow::ensure!(
            directory.parent() == Some(root.as_path()),
            "INVALID_CACHE_PATH"
        );
        for file in std::fs::read_dir(&directory)?.flatten() {
            if !file.file_type()?.is_file() {
                continue;
            }
            let name = file.file_name().to_string_lossy().to_string();
            let cache = (name.starts_with("preview-") && name.ends_with(".png"))
                || (name.starts_with("ocr-") && name.ends_with(".json"));
            if !cache {
                continue;
            }
            files += 1;
            bytes += file.metadata()?.len();
            if clear_cache {
                if std::fs::remove_file(file.path()).is_ok() {
                    removed += 1;
                } else {
                    locked += 1;
                }
            }
        }
    }
    Ok(serde_json::json!({"cache_bytes":bytes,"cache_files":files,"removed":removed,"locked":locked}).to_string())
}
