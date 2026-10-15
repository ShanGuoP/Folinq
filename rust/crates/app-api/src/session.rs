use anyhow::{Context, Result, ensure};
use document_core::{DocumentInfo, PageInfo, check_version};
use pdf_engine::operations::{ObjectOperation, PageOperation};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

const MAX_FILE_BYTES: u64 = 256 * 1024 * 1024;
const HISTORY_LIMIT: usize = 20;

pub struct Session {
    pub info: DocumentInfo,
    directory: PathBuf,
    undo: Vec<PathBuf>,
    redo: Vec<PathBuf>,
    saved_hash: String,
}

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn read_pdf(path: &Path) -> Result<Vec<u8>> {
    let file = fs::File::open(path)?;
    ensure!(
        file.metadata()?.len() <= MAX_FILE_BYTES,
        "FILE_LIMIT: maximum 256 MiB"
    );
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= MAX_FILE_BYTES, "FILE_LIMIT");
    ensure!(bytes.starts_with(b"%PDF-"), "INVALID_PDF_HEADER");
    Ok(bytes)
}

// Only create new files; an existing destination is never silently overwritten.
fn publish_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist_noclobber(path)
        .map_err(|e| e.error)
        .context("DESTINATION_EXISTS_OR_UNWRITABLE")?;
    Ok(())
}

impl Session {
    pub fn open(source: &Path, workspace: &Path) -> Result<Self> {
        let source = source.canonicalize()?;
        let bytes = read_pdf(&source)?;
        let id = Uuid::new_v4().to_string();
        let mut pages = pdf_engine::inspect(&bytes, None)?;
        for page in &mut pages {
            page.id = format!("{id}:{}", page.id);
            for object in &mut page.image_objects {
                object.id = format!("{}:image:{}", page.id, object.object_index);
                object.page_id = page.id.clone();
            }
            for object in &mut page.text_objects {
                object.page_id = page.id.clone();
                object.id = format!("{}:text:{}", page.id, object.object_index);
            }
        }
        let directory = workspace.join(&id);
        fs::create_dir_all(&directory)?;
        publish_new(&directory.join("source.pdf"), &bytes)?;
        let working = directory.join("version-0.pdf");
        publish_new(&working, &bytes)?;
        let source_hash = hash(&bytes);
        let info = DocumentInfo {
            id,
            source_path: source.to_string_lossy().into(),
            source_hash: source_hash.clone(),
            working_path: working.to_string_lossy().into(),
            version: 0,
            dirty: false,
            can_undo: false,
            can_redo: false,
            pages,
        };
        let session = Self {
            info,
            directory,
            undo: vec![],
            redo: vec![],
            saved_hash: source_hash,
        };
        session.journal(&session.info)?;
        session.persist_recovery(&session.info, &[], &[], &session.saved_hash)?;
        Ok(session)
    }

    fn persist_recovery(
        &self,
        info: &DocumentInfo,
        undo: &[PathBuf],
        redo: &[PathBuf],
        saved_hash: &str,
    ) -> Result<()> {
        let bytes = serde_json::to_vec(&serde_json::json!({ "info": info, "undo": undo,
            "redo": redo, "saved_hash": saved_hash, "working_hash": hash(&read_pdf(Path::new(&info.working_path))?) }))?;
        let mut temporary = tempfile::NamedTempFile::new_in(&self.directory)?;
        temporary.write_all(&bytes)?;
        temporary.as_file().sync_all()?;
        temporary
            .persist(self.directory.join("recovery.json"))
            .map_err(|error| error.error)?;
        // A catalog failure cannot roll back an already published document.
        // Record it locally; the catalog can be rebuilt from recovery manifests.
        if let Some(workspace) = self.directory.parent() {
            let result = storage::Catalog::open(&workspace.join("catalog.sqlite"))
                .and_then(|mut catalog| catalog.index(info));
            if let Err(error) = result {
                let _ = fs::write(self.directory.join("catalog-error.log"), error.to_string());
            }
        }
        Ok(())
    }

    pub fn recover(workspace: &Path, id: &str) -> Result<Self> {
        Uuid::parse_str(id).context("INVALID_DOCUMENT_ID")?;
        let root = workspace.canonicalize()?;
        let directory = root.join(id).canonicalize()?;
        ensure!(
            directory.parent() == Some(root.as_path()),
            "INVALID_RECOVERY_PATH"
        );
        let record: serde_json::Value =
            serde_json::from_slice(&fs::read(directory.join("recovery.json"))?)?;
        let mut info: DocumentInfo = serde_json::from_value(record["info"].clone())?;
        ensure!(info.id == id, "RECOVERY_ID_MISMATCH");
        let undo: Vec<PathBuf> = serde_json::from_value(record["undo"].clone())?;
        let redo: Vec<PathBuf> = serde_json::from_value(record["redo"].clone())?;
        for path in undo
            .iter()
            .chain(&redo)
            .chain(std::iter::once(&PathBuf::from(&info.working_path)))
        {
            ensure!(
                path.canonicalize()?.parent() == Some(directory.as_path()),
                "INVALID_RECOVERY_PATH"
            );
        }
        let bytes = read_pdf(Path::new(&info.working_path))?;
        ensure!(
            record["working_hash"].as_str() == Some(hash(&bytes).as_str()),
            "RECOVERY_HASH_MISMATCH"
        );
        let saved_hash = record["saved_hash"]
            .as_str()
            .context("INVALID_RECOVERY")?
            .to_owned();
        let ids = info.pages.iter().map(|p| p.id.clone()).collect::<Vec<_>>();
        let mut pages = pdf_engine::inspect(&bytes, Some(&ids))?;
        reconcile(&mut pages, &info.pages);
        info.pages = pages;
        info.dirty = hash(&bytes) != saved_hash;
        info.can_undo = !undo.is_empty();
        info.can_redo = !redo.is_empty();
        Ok(Self {
            info,
            directory,
            undo,
            redo,
            saved_hash,
        })
    }

    pub fn recoverable(workspace: &Path) -> Result<Vec<DocumentInfo>> {
        if !workspace.exists() {
            return Ok(vec![]);
        }
        let mut results = Vec::new();
        for entry in fs::read_dir(workspace)?.take(1000).flatten() {
            let path = entry.path().join("recovery.json");
            let name = entry.file_name().to_string_lossy().into_owned();
            if Uuid::parse_str(&name).is_err() || !entry.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            if let Ok(bytes) = fs::read(&path)
                && let Ok(record) = serde_json::from_slice::<serde_json::Value>(&bytes)
                && let Ok(info) = serde_json::from_value::<DocumentInfo>(record["info"].clone())
            {
                if info.id != name {
                    continue;
                }
                results.push((
                    fs::metadata(&path)
                        .and_then(|m| m.modified())
                        .unwrap_or(std::time::UNIX_EPOCH),
                    info,
                ));
            }
        }
        results.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
        Ok(results.into_iter().map(|(_, info)| info).collect())
    }

    pub fn source_key(source: &str) -> String {
        let normalized = source.replace('\\', "/");
        let normalized = normalized.trim_start_matches("//?/");
        if cfg!(windows) {
            normalized.to_lowercase()
        } else {
            normalized.to_owned()
        }
    }

    pub fn history(&self) -> Result<serde_json::Value> {
        let workspace = self.directory.parent().context("INVALID_WORKSPACE")?;
        let source = Self::source_key(&self.info.source_path);
        let mut records = Vec::new();
        for info in Self::recoverable(workspace)?
            .into_iter()
            .filter(|info| Self::source_key(&info.source_path) == source)
        {
            let directory = workspace.join(&info.id);
            for entry in fs::read_dir(directory)?.take(10000).flatten() {
                let path = entry.path();
                let Some(version) = path
                    .file_name()
                    .and_then(|s| s.to_str())
                    .and_then(|s| s.strip_prefix("version-"))
                    .and_then(|s| s.strip_suffix(".json"))
                    .and_then(|s| s.parse::<u64>().ok())
                else {
                    continue;
                };
                // An incomplete/failed future commit is never a usable version.
                if version > info.version || !path.with_extension("pdf").is_file() {
                    continue;
                }
                let metadata = fs::metadata(&path)?;
                let time = metadata
                    .modified()?
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64;
                records.push(
                    serde_json::json!({"session_id":info.id,"version":version,"time":time,
                    "current": info.id == self.info.id && version == self.info.version}),
                );
            }
        }
        records.sort_by(|a, b| {
            b["time"]
                .as_u64()
                .cmp(&a["time"].as_u64())
                .then_with(|| b["version"].as_u64().cmp(&a["version"].as_u64()))
        });
        Ok(serde_json::Value::Array(records))
    }

    pub fn restore_version(&mut self, expected: u64, session_id: &str, version: u64) -> Result<()> {
        check_version(self.info.version, expected)?;
        let root = self
            .directory
            .parent()
            .context("INVALID_WORKSPACE")?
            .canonicalize()?;
        Uuid::parse_str(session_id).context("INVALID_DOCUMENT_ID")?;
        let directory = root.join(session_id).canonicalize()?;
        ensure!(
            directory.parent() == Some(root.as_path()),
            "INVALID_RECOVERY_PATH"
        );
        let record: serde_json::Value =
            serde_json::from_slice(&fs::read(directory.join("recovery.json"))?)?;
        let current: DocumentInfo = serde_json::from_value(record["info"].clone())?;
        ensure!(
            current.id == session_id
                && version <= current.version
                && Self::source_key(&current.source_path)
                    == Self::source_key(&self.info.source_path),
            "INVALID_HISTORY_VERSION"
        );
        let path = directory
            .join(format!("version-{version}.pdf"))
            .canonicalize()?;
        ensure!(
            path.parent() == Some(directory.as_path()),
            "INVALID_RECOVERY_PATH"
        );
        let template: DocumentInfo =
            serde_json::from_slice(&fs::read(path.with_extension("json"))?)?;
        ensure!(
            template.id == session_id && template.version == version,
            "INVALID_HISTORY_VERSION"
        );
        let bytes = read_pdf(&path)?;
        let mut undo = self.undo.clone();
        undo.push(PathBuf::from(&self.info.working_path));
        if undo.len() > HISTORY_LIMIT {
            undo.remove(0);
        }
        self.commit_with_pages(&bytes, undo, vec![], template.pages)
    }

    fn journal(&self, info: &DocumentInfo) -> Result<()> {
        // Immutable version records: the highest complete record is the recovery point.
        publish_new(
            &self
                .directory
                .join(format!("version-{}.json", info.version)),
            &serde_json::to_vec_pretty(info)?,
        )
    }

    pub fn bytes(&self) -> Result<Vec<u8>> {
        read_pdf(Path::new(&self.info.working_path))
    }

    pub fn preview(&self, expected_version: u64, page_index: u16) -> Result<String> {
        check_version(self.info.version, expected_version)?;
        ensure!(
            (page_index as usize) < self.info.pages.len(),
            "PAGE_NOT_FOUND"
        );
        let path = self
            .directory
            .join(format!("preview-{}-{page_index}.png", self.info.version));
        if !path.exists() {
            pdf_engine::render_png(&self.bytes()?, page_index, &path)?;
        }
        Ok(path.to_string_lossy().into())
    }

    pub fn detail_preview(&self, version: u64, page: u16, width: u32) -> Result<String> {
        check_version(self.info.version, version)?;
        ensure!(
            (page as usize) < self.info.pages.len() && (512..=4096).contains(&width),
            "INVALID_RENDER_REQUEST"
        );
        let path = self
            .directory
            .join(format!("preview-{version}-{page}-{width}.png"));
        if !path.exists() {
            pdf_engine::render_png_at_width(&self.bytes()?, page, &path, width)?;
        }
        Ok(path.to_string_lossy().into())
    }

    pub fn view_state(&self, version: u64, value: Option<&str>) -> Result<String> {
        check_version(self.info.version, version)?;
        let path = self.directory.join("view.json");
        if let Some(value) = value {
            ensure!(value.len() <= 65536, "VIEW_STATE_LIMIT");
            let record: serde_json::Value = serde_json::from_str(value)?;
            let page_id = record["page_id"].as_str().context("INVALID_VIEW_STATE")?;
            ensure!(
                self.info.pages.iter().any(|p| p.id == page_id),
                "PAGE_NOT_FOUND"
            );
            let mut temporary = tempfile::NamedTempFile::new_in(&self.directory)?;
            temporary.write_all(value.as_bytes())?;
            temporary.as_file().sync_all()?;
            temporary.persist(&path).map_err(|e| e.error)?;
            return Ok(value.to_owned());
        }
        if path.exists() && path.metadata()?.len() <= 65536 {
            Ok(fs::read_to_string(path)?)
        } else {
            Ok("{}".into())
        }
    }

    pub fn ocr_cache(&self, version: u64, page: u16, language: &str) -> Result<PathBuf> {
        check_version(self.info.version, version)?;
        ensure!(
            (page as usize) < self.info.pages.len()
                && language.len() < 40
                && language
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-'),
            "INVALID_OCR_REQUEST"
        );
        Ok(self.directory.join(format!(
            "ocr-{}-{page}-{language}.json",
            hash(&self.bytes()?)
        )))
    }

    pub fn add_ocr_layer(
        &mut self,
        version: u64,
        page: u16,
        language: &str,
        font: Option<&str>,
    ) -> Result<()> {
        let path = self.ocr_cache(version, page, language)?;
        let result: document_core::OcrResult =
            serde_json::from_slice(&fs::read(path).context("OCR_RESULT_REQUIRED")?)?;
        let bytes = pdf_engine::searchable::add_search_layer(&self.bytes()?, page, &result, font)?;
        let mut undo = self.undo.clone();
        undo.push(PathBuf::from(&self.info.working_path));
        if undo.len() > HISTORY_LIMIT {
            undo.remove(0);
        }
        self.commit(&bytes, undo, vec![])
    }

    fn commit(&mut self, bytes: &[u8], undo: Vec<PathBuf>, redo: Vec<PathBuf>) -> Result<()> {
        self.commit_with_pages(bytes, undo, redo, self.info.pages.clone())
    }

    fn commit_with_pages(
        &mut self,
        bytes: &[u8],
        undo: Vec<PathBuf>,
        redo: Vec<PathBuf>,
        template: Vec<PageInfo>,
    ) -> Result<()> {
        let ids: Vec<String> = template.iter().map(|p| p.id.clone()).collect();
        let mut pages = pdf_engine::inspect(bytes, Some(&ids))?;
        reconcile(&mut pages, &template);
        let version = self
            .info
            .version
            .checked_add(1)
            .context("VERSION_EXHAUSTED")?;
        let working = self.directory.join(format!("version-{version}.pdf"));
        let mut info = self.info.clone();
        info.pages = pages;
        info.version = version;
        info.working_path = working.to_string_lossy().into();
        info.dirty = hash(bytes) != self.saved_hash;
        info.can_undo = !undo.is_empty();
        info.can_redo = !redo.is_empty();
        publish_new(&working, bytes)?;
        if let Err(error) = self.journal(&info) {
            let _ = fs::remove_file(&working);
            return Err(error);
        }
        if let Err(error) = self.persist_recovery(&info, &undo, &redo, &self.saved_hash) {
            let _ = fs::remove_file(&working);
            let _ = fs::remove_file(working.with_extension("json"));
            return Err(error);
        }
        self.info = info;
        self.undo = undo;
        self.redo = redo;
        Ok(())
    }

    pub fn replace(
        &mut self,
        expected_version: u64,
        object_id: &str,
        replacement: &str,
    ) -> Result<()> {
        self.replace_with_options(
            expected_version,
            object_id,
            replacement,
            &document_core::TextEditOptions::default(),
        )
    }

    pub fn replace_with_options(
        &mut self,
        expected_version: u64,
        object_id: &str,
        replacement: &str,
        options: &document_core::TextEditOptions,
    ) -> Result<()> {
        check_version(self.info.version, expected_version)?;
        let (page_index, object) = self
            .info
            .pages
            .iter()
            .find_map(|p| {
                p.text_objects
                    .iter()
                    .find(|o| o.id == object_id)
                    .map(|o| (p.index, o))
            })
            .context("OBJECT_NOT_FOUND")?;
        let bytes = pdf_engine::replace_text_with_options(
            &self.bytes()?,
            page_index,
            object.object_index,
            &object.text,
            replacement,
            object.layout_bounds.as_ref().unwrap_or(&object.bounds),
            options,
        )?;
        let mut undo = self.undo.clone();
        undo.push(PathBuf::from(&self.info.working_path));
        if undo.len() > HISTORY_LIMIT {
            undo.remove(0);
        }
        self.commit(&bytes, undo, vec![])
    }

    pub fn undo(&mut self, expected_version: u64) -> Result<()> {
        check_version(self.info.version, expected_version)?;
        let mut undo = self.undo.clone();
        let previous = undo.pop().context("NOTHING_TO_UNDO")?;
        let mut redo = self.redo.clone();
        redo.push(PathBuf::from(&self.info.working_path));
        let info: DocumentInfo =
            serde_json::from_slice(&fs::read(previous.with_extension("json"))?)?;
        self.commit_with_pages(&read_pdf(&previous)?, undo, redo, info.pages)
    }

    pub fn redo(&mut self, expected_version: u64) -> Result<()> {
        check_version(self.info.version, expected_version)?;
        let mut redo = self.redo.clone();
        let next = redo.pop().context("NOTHING_TO_REDO")?;
        let mut undo = self.undo.clone();
        undo.push(PathBuf::from(&self.info.working_path));
        let info: DocumentInfo = serde_json::from_slice(&fs::read(next.with_extension("json"))?)?;
        self.commit_with_pages(&read_pdf(&next)?, undo, redo, info.pages)
    }

    pub fn save(&mut self, expected_version: u64, destination: &Path) -> Result<()> {
        check_version(self.info.version, expected_version)?;
        let bytes = self.bytes()?;
        let pages = pdf_engine::inspect(&bytes, None)?;
        ensure!(pages.len() == self.info.pages.len(), "PAGE_COUNT_MISMATCH");
        publish_new(destination, &bytes)?;
        // Reading the exported file also catches destination/provider failures.
        ensure!(
            hash(&read_pdf(destination)?) == hash(&bytes),
            "EXPORT_VERIFICATION_FAILED"
        );
        let saved_hash = hash(&bytes);
        let mut info = self.info.clone();
        info.dirty = false;
        self.persist_recovery(&info, &self.undo, &self.redo, &saved_hash)?;
        self.saved_hash = saved_hash;
        self.info = info;
        Ok(())
    }

    pub fn save_source(&mut self, version: u64) -> Result<()> {
        check_version(self.info.version, version)?;
        let destination = PathBuf::from(&self.info.source_path);
        ensure!(
            hash(&read_pdf(&destination)?) == self.info.source_hash,
            "SOURCE_CHANGED: source was modified outside this session"
        );
        let bytes = self.bytes()?;
        pdf_engine::inspect(&bytes, None)?;
        let mut temporary =
            tempfile::NamedTempFile::new_in(destination.parent().context("INVALID_SOURCE_PATH")?)?;
        temporary.write_all(&bytes)?;
        temporary.as_file().sync_all()?;
        ensure!(
            hash(&read_pdf(&destination)?) == self.info.source_hash,
            "SOURCE_CHANGED"
        );
        temporary
            .persist(&destination)
            .map_err(|e| e.error)
            .context("SOURCE_SAVE_FAILED")?;
        let saved_hash = hash(&read_pdf(&destination)?);
        ensure!(saved_hash == hash(&bytes), "EXPORT_VERIFICATION_FAILED");
        self.info.source_hash = saved_hash.clone();
        self.info.dirty = false;
        self.saved_hash = saved_hash;
        self.persist_recovery(&self.info, &self.undo, &self.redo, &self.saved_hash)?;
        Ok(())
    }

    pub fn redact_export(
        &self,
        version: u64,
        page: u16,
        areas: &[[f32; 4]],
        destination: &Path,
    ) -> Result<()> {
        check_version(self.info.version, version)?;
        ensure!(!destination.exists(), "DESTINATION_EXISTS_OR_UNWRITABLE");
        let output = pdf_engine::redaction::export(&self.bytes()?, page, areas)?;
        publish_new(destination, &output)?;
        ensure!(
            hash(&fs::read(destination)?) == hash(&output),
            "EXPORT_VERIFICATION_FAILED"
        );
        Ok(())
    }

    pub fn prepare_external_export(
        &self,
        version: u64,
        format: &str,
        pages: &[u16],
    ) -> Result<String> {
        check_version(self.info.version, version)?;
        let path = self
            .directory
            .join(format!("export-{}.{}", Uuid::new_v4(), format));
        if format == "pdf" && pages.is_empty() {
            publish_new(&path, &self.bytes()?)?;
        } else {
            self.export(version, format, &path, pages)?;
        }
        Ok(path.to_string_lossy().into())
    }

    pub fn mark_external_saved(&mut self, version: u64) -> Result<()> {
        check_version(self.info.version, version)?;
        let saved_hash = hash(&self.bytes()?);
        let mut info = self.info.clone();
        info.dirty = false;
        self.persist_recovery(&info, &self.undo, &self.redo, &saved_hash)?;
        self.saved_hash = saved_hash;
        self.info = info;
        Ok(())
    }

    pub fn page_operation(&mut self, version: u64, operation: PageOperation) -> Result<()> {
        check_version(self.info.version, version)?;
        let mut operation = operation;
        if let PageOperation::Merge { path, .. } = &mut operation {
            let frozen = self
                .directory
                .join(format!("import-{}.pdf", Uuid::new_v4()));
            publish_new(&frozen, &read_pdf(Path::new(path))?)?;
            *path = frozen.to_string_lossy().into();
        }
        let bytes = pdf_engine::operations::page_operation(&self.bytes()?, &operation)?;
        let mut template = self.info.pages.clone();
        match operation {
            PageOperation::Delete { page } => {
                template.remove(page as usize);
            }
            PageOperation::Insert { at } => {
                template.insert(
                    at as usize,
                    PageInfo {
                        id: Uuid::new_v4().to_string(),
                        index: at,
                        width: 0.,
                        height: 0.,
                        text_objects: vec![],
                        text_content: String::new(),
                        image_objects: vec![],
                    },
                );
            }
            PageOperation::Move { page, target } => {
                let page = template.remove(page as usize);
                template.insert(target as usize, page);
            }
            PageOperation::Merge { path, at } => {
                let mut added = pdf_engine::inspect(&read_pdf(Path::new(&path))?, None)?;
                for page in &mut added {
                    page.id = Uuid::new_v4().to_string();
                    for object in &mut page.image_objects {
                        object.id = Uuid::new_v4().to_string();
                        object.page_id = page.id.clone();
                    }
                    for object in &mut page.text_objects {
                        object.id = Uuid::new_v4().to_string();
                        object.page_id = page.id.clone();
                    }
                }
                template.splice(at as usize..at as usize, added);
            }
            _ => {}
        }
        let mut undo = self.undo.clone();
        undo.push(PathBuf::from(&self.info.working_path));
        if undo.len() > HISTORY_LIMIT {
            undo.remove(0);
        }
        self.commit_with_pages(&bytes, undo, vec![], template)
    }

    pub fn object_operation(&mut self, version: u64, operation: ObjectOperation) -> Result<()> {
        check_version(self.info.version, version)?;
        let bytes = pdf_engine::operations::object_operation(&self.bytes()?, &operation)?;
        let mut template = self.info.pages.clone();
        if let ObjectOperation::Transform { page, index, .. } = &operation
            && let Some(object) = template
                .get_mut(*page as usize)
                .and_then(|p| p.text_objects.iter_mut().find(|o| o.object_index == *index))
        {
            object.layout_bounds = None;
        }
        if let ObjectOperation::Move {
            page,
            index,
            dx,
            dy,
        } = &operation
            && let Some(object) = template
                .get_mut(*page as usize)
                .and_then(|p| p.text_objects.iter_mut().find(|o| o.object_index == *index))
        {
            let mut bounds = object
                .layout_bounds
                .clone()
                .unwrap_or_else(|| object.bounds.clone());
            bounds.left += dx;
            bounds.right += dx;
            bounds.bottom += dy;
            bounds.top += dy;
            object.layout_bounds = Some(bounds);
        }
        if let ObjectOperation::Delete { page, index } = operation {
            let page = template.get_mut(page as usize).context("PAGE_NOT_FOUND")?;
            page.text_objects.retain(|o| o.object_index != index);
            page.image_objects.retain(|o| o.object_index != index);
            for object in &mut page.image_objects {
                if object.object_index > index {
                    object.object_index -= 1;
                }
            }
            for object in &mut page.text_objects {
                if object.object_index > index {
                    object.object_index -= 1;
                }
            }
        }
        let mut undo = self.undo.clone();
        undo.push(PathBuf::from(&self.info.working_path));
        if undo.len() > HISTORY_LIMIT {
            undo.remove(0);
        }
        self.commit_with_pages(&bytes, undo, vec![], template)
    }

    pub fn export(
        &self,
        version: u64,
        format: &str,
        destination: &Path,
        pages: &[u16],
    ) -> Result<()> {
        self.export_with_mode(version, format, destination, pages, "layout")
    }

    pub fn export_with_mode(
        &self,
        version: u64,
        format: &str,
        destination: &Path,
        pages: &[u16],
        mode: &str,
    ) -> Result<()> {
        ensure!(matches!(mode, "layout" | "text"), "INVALID_EXPORT_MODE");
        ensure!(!destination.exists(), "DESTINATION_EXISTS_OR_UNWRITABLE");
        check_version(self.info.version, version)?;
        let selected: Vec<PageInfo> = if pages.is_empty() {
            self.info.pages.clone()
        } else {
            pages
                .iter()
                .map(|index| {
                    self.info
                        .pages
                        .get(*index as usize)
                        .cloned()
                        .context("PAGE_NOT_FOUND")
                })
                .collect::<Result<_>>()?
        };
        if matches!(format, "docx" | "md") && mode == "layout" {
            let images = pdf_engine::conversion::layout_pages(
                &self.bytes()?,
                &selected.iter().map(|p| p.index).collect::<Vec<_>>(),
            )?;
            if format == "docx" {
                return publish_new(
                    destination,
                    &pdf_engine::conversion::layout_docx(&selected, &images)?,
                );
            }
            // Stage all images before publishing the .md. A unique adjacent
            // directory avoids overwriting existing resources or racing exports.
            let parent = destination
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new("."));
            let resources = format!("folinq-assets-{}", Uuid::new_v4());
            let staging = tempfile::Builder::new()
                .prefix(".folinq-export-")
                .tempdir_in(parent)?;
            let mut markdown = String::new();
            for (page, image) in selected.iter().zip(&images) {
                let filename = format!("page-{:04}.png", page.index + 1);
                let mut file = fs::File::create(staging.path().join(&filename))?;
                file.write_all(image)?;
                file.sync_all()?;
                markdown.push_str(&format!(
                    "## 第 {} 页\n\n![第 {} 页]({resources}/{filename})\n\n",
                    page.index + 1,
                    page.index + 1
                ));
            }
            let resource_path = parent.join(&resources);
            fs::rename(staging.path(), &resource_path)?;
            if let Err(error) = publish_new(destination, markdown.as_bytes()) {
                // This path is a freshly created UUID owned by this operation.
                let _ = fs::remove_dir_all(&resource_path);
                return Err(error);
            }
            return Ok(());
        }
        let bytes = match format {
            "txt" => pdf_engine::conversion::text_export(&selected, false).into_bytes(),
            "md" => pdf_engine::conversion::text_export(&selected, true).into_bytes(),
            "docx" => pdf_engine::conversion::docx_export(&selected)?,
            "pdf" => pdf_engine::operations::extract_pages(
                &self.bytes()?,
                &selected.iter().map(|p| p.index).collect::<Vec<_>>(),
            )?,
            "png" | "jpg" => {
                ensure!(selected.len() == 1, "ONE_PAGE_REQUIRED");
                ensure!(!destination.exists(), "DESTINATION_EXISTS_OR_UNWRITABLE");
                let temp = self
                    .directory
                    .join(format!("export-{}.{}", Uuid::new_v4(), format));
                pdf_engine::render_png(&self.bytes()?, selected[0].index, &temp)?;
                let bytes = fs::read(&temp)?;
                let _ = fs::remove_file(&temp);
                bytes
            }
            _ => anyhow::bail!("UNSUPPORTED_EXPORT_FORMAT"),
        };
        if format == "pdf" {
            pdf_engine::inspect(&bytes, None)?;
        }
        publish_new(destination, &bytes)
    }
}

fn reconcile(pages: &mut [PageInfo], template: &[PageInfo]) {
    for page in pages {
        let old = template.iter().find(|p| p.id == page.id);
        for object in &mut page.image_objects {
            object.id = old
                .and_then(|p| {
                    p.image_objects
                        .iter()
                        .find(|o| o.object_index == object.object_index)
                })
                .map(|o| o.id.clone())
                .unwrap_or_else(|| Uuid::new_v4().to_string());
            object.page_id = page.id.clone();
        }
        for object in &mut page.text_objects {
            if let Some(previous) = old.and_then(|p| {
                p.text_objects
                    .iter()
                    .find(|o| o.object_index == object.object_index)
            }) {
                object.layout_bounds = Some(
                    previous
                        .layout_bounds
                        .clone()
                        .unwrap_or_else(|| object.bounds.clone()),
                );
            }
            object.id = old
                .and_then(|p| {
                    p.text_objects
                        .iter()
                        .find(|o| o.object_index == object.object_index)
                })
                .map(|o| o.id.clone())
                .unwrap_or_else(|| Uuid::new_v4().to_string());
            object.page_id = page.id.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fidelity_exports_include_every_page_and_history_restore_is_undoable() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("source.pdf");
        let original = pdf_engine::create_fixture()?;
        fs::write(&source, &original)?;
        let workspace = temp.path().join("sessions");
        let mut session = Session::open(&source, &workspace)?;
        session.page_operation(0, PageOperation::Insert { at: 1 })?;
        session.page_operation(
            1,
            PageOperation::Rotate {
                page: 1,
                clockwise: true,
            },
        )?;
        let image_path = temp.path().join("image.png");
        image::RgbImage::from_fn(90, 50, |x, y| {
            image::Rgb([(x * 2) as u8, (y * 4) as u8, 140])
        })
        .save(&image_path)?;
        session.object_operation(
            2,
            ObjectOperation::InsertImage {
                page: 0,
                path: image_path.to_string_lossy().into(),
                x: 50.,
                y: 400.,
                width: 180.,
                height: 100.,
            },
        )?;
        let mut grid = Vec::new();
        for p in [0., 0.5, 1.] {
            grid.push(vec![[p, 0.], [p, 1.]]);
            grid.push(vec![[0., p], [1., p]]);
        }
        session.object_operation(
            3,
            ObjectOperation::Ink {
                page: 0,
                strokes: grid,
            },
        )?;
        let v = session.info.version;
        assert_eq!(session.info.pages[0].image_objects.len(), 1);
        assert!(session.info.pages[1].width > session.info.pages[1].height);
        let before = session.bytes()?;
        let expected_images = pdf_engine::conversion::layout_pages(&before, &[1, 0])?;
        let word = temp.path().join("mixed.docx");
        session.export(v, "docx", &word, &[1, 0])?;
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(fs::read(&word)?))?;
        let mut xml = String::new();
        archive
            .by_name("word/document.xml")?
            .read_to_string(&mut xml)?;
        assert_eq!(xml.matches("<wp:anchor").count(), 2);
        assert_eq!(xml.matches("<w:sectPr>").count(), 2);
        assert!(xml.contains("relativeFrom=\"page\""));
        let media_names = archive
            .file_names()
            .filter(|name| name.starts_with("word/media/") && !name.ends_with('/'))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        assert_eq!(media_names.len(), 2);
        for name in media_names {
            let mut png = Vec::new();
            archive.by_name(&name)?.read_to_end(&mut png)?;
            let image = image::load_from_memory(&png)?;
            // docx-rs re-encodes PNG; compare pixels rather than PNG compression.
            assert!(expected_images.iter().any(|expected| {
                image::load_from_memory(expected).unwrap().to_rgba8() == image.to_rgba8()
            }));
        }
        let markdown = temp.path().join("document with spaces.md");
        session.export(v, "md", &markdown, &[1, 0])?;
        let md = fs::read_to_string(&markdown)?;
        assert!(md.find("第 2 页").unwrap() < md.find("第 1 页").unwrap());
        for (index, link) in md
            .split("](")
            .skip(1)
            .map(|s| s.split(')').next().unwrap())
            .enumerate()
        {
            assert_eq!(fs::read(temp.path().join(link))?, expected_images[index]);
        }
        assert!(session.export(v, "md", &markdown, &[]).is_err());
        assert_eq!(fs::read_to_string(&markdown)?, md);
        assert!(
            session
                .export(v, "md", &temp.path().join("missing/output.md"), &[])
                .is_err()
        );
        assert!(!temp.path().join("missing/output.md").exists());
        // Another opening of the same PDF remains available through history.
        let older = Session::open(&source, &workspace)?;
        let history = session.history()?;
        assert!(
            history
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["session_id"] == older.info.id)
        );
        assert!(
            history
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["current"] == true)
        );
        session.restore_version(v, &older.info.id, 0)?;
        assert_eq!(session.info.pages.len(), 1);
        assert_eq!(fs::read(&source)?, original);
        session.undo(v + 1)?;
        assert_eq!(session.bytes()?, before);
        // A foreign PDF and a path traversal cannot be used as a history source.
        let other_path = temp.path().join("other.pdf");
        fs::write(&other_path, &original)?;
        let other = Session::open(&other_path, &workspace)?;
        assert!(session.restore_version(v + 2, &other.info.id, 0).is_err());
        assert!(session.restore_version(v + 2, "../outside", 0).is_err());
        assert_eq!(session.bytes()?, before);
        Ok(())
    }

    #[test]
    fn projects_persist_membership_and_deletion_keeps_pdf_independent() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("source.pdf");
        fs::write(&source, pdf_engine::create_fixture()?)?;
        let workspace = temp.path().join("sessions");
        let session = Session::open(&source, &workspace)?;
        let duplicate = Session::open(&source, &workspace)?;
        let command = |command: &str, value: serde_json::Value| -> Result<serde_json::Value> {
            Ok(serde_json::from_str(&crate::api::project_catalog(
                workspace.to_string_lossy().into(),
                command.into(),
                value.to_string(),
            )?)?)
        };
        let data = command("create", serde_json::json!({"name":"Project Alpha"}))?;
        let id = data["projects"][0]["id"].as_str().unwrap();
        command("rename", serde_json::json!({"id":id,"name":"Renamed"}))?;
        command(
            "assign",
            serde_json::json!({"document_id":session.info.id,"project_id":id}),
        )?;
        let data = command("list", serde_json::json!({}))?;
        assert_eq!(data["projects"][0]["name"], "Renamed");
        assert_eq!(data["memberships"][&session.info.id], id);
        assert_eq!(data["memberships"][&duplicate.info.id], id);
        assert!(command("assign",serde_json::json!({"document_id":session.info.id,"project_id":"00000000-0000-0000-0000-000000000000"})).is_err());
        assert_eq!(
            command("list", serde_json::json!({}))?["memberships"][&session.info.id],
            id
        );
        let data = command("delete", serde_json::json!({"id":id}))?;
        assert!(data["memberships"].as_object().unwrap().is_empty());
        assert!(data["projects"].as_array().unwrap().is_empty());
        assert!(Session::recover(&workspace, &session.info.id).is_ok());
        assert!(source.exists());
        Ok(())
    }
    #[test]
    fn direct_save_updates_source_keeps_private_original_and_detects_conflicts() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("source.pdf");
        let original = pdf_engine::create_fixture()?;
        fs::write(&source, &original)?;
        let mut session = Session::open(&source, &temp.path().join("sessions"))?;
        let id = session.info.pages[0].text_objects[0].id.clone();
        session.replace(0, &id, "New 123")?;
        session.save_source(1)?;
        assert!(!session.info.dirty);
        assert!(
            pdf_engine::inspect(&fs::read(&source)?, None)?[0]
                .text_content
                .contains("New 123")
        );
        assert_eq!(fs::read(session.directory.join("source.pdf"))?, original);
        session.replace(1, &id, "Next 456")?;
        session.save_source(2)?;
        fs::write(&source, &original)?;
        assert!(
            session
                .save_source(2)
                .unwrap_err()
                .to_string()
                .contains("SOURCE_CHANGED")
        );
        assert_eq!(fs::read(&source)?, original);
        Ok(())
    }
    #[test]
    fn shortening_then_expanding_text_preserves_the_original_edit_area() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("input.pdf");
        fs::write(&source, pdf_engine::create_fixture()?)?;
        let workspace = temp.path().join("sessions");
        let mut session = Session::open(&source, &workspace)?;
        let id = session.info.pages[0].text_objects[0].id.clone();
        session.replace(0, &id, "Hi")?;
        let mut session = Session::recover(&workspace, &session.info.id)?;
        session.replace(1, &id, "Hello PDF Editor")?;
        assert_eq!(
            session.info.pages[0].text_objects[0].text,
            "Hello PDF Editor"
        );
        Ok(())
    }
    #[test]
    #[cfg(windows)]
    fn real_offline_ocr_search_layer_keeps_scan_pixels() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("input.pdf");
        let bytes = pdf_engine::create_fixture()?;
        fs::write(&source, &bytes)?;
        let image = temp.path().join("scan.png");
        pdf_engine::render_png(&bytes, 0, &image)?;
        let mut session = Session::open(&source, &temp.path().join("sessions"))?;
        let (width, height) = (session.info.pages[0].width, session.info.pages[0].height);
        session.page_operation(0, PageOperation::Insert { at: 0 })?;
        session.object_operation(
            1,
            ObjectOperation::InsertImage {
                page: 0,
                path: image.to_string_lossy().into(),
                x: 0.,
                y: 0.,
                width,
                height,
            },
        )?;
        session.page_operation(2, PageOperation::Delete { page: 1 })?;
        assert!(session.info.pages[0].text_content.trim().is_empty());
        let preview = session.preview(3, 0)?;
        let result = ocr_engine::recognize(&preview, "en-US")?;
        assert!(result.text.contains("Hello"));
        fs::write(
            session.ocr_cache(3, 0, "en-US")?,
            serde_json::to_vec(&result)?,
        )?;
        session.add_ocr_layer(3, 0, "en-US", None)?;
        assert!(session.info.pages[0].text_content.contains("Hello"));
        assert!(
            session.info.pages[0]
                .text_objects
                .iter()
                .all(|o| !o.editable)
        );
        let output = temp.path().join("searchable.pdf");
        session.save(4, &output)?;
        let restored = Session::recover(&temp.path().join("sessions"), &session.info.id)?;
        assert!(!restored.info.dirty);
        assert!(restored.info.pages[0].text_content.contains("Hello"));
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        assert!(
            ocr_engine::recognize_cancellable(&preview, "en-US", cancelled)
                .unwrap_err()
                .to_string()
                .contains("TASK_CANCELLED")
        );
        Ok(())
    }
    #[test]
    fn page_operations_restore_ids_and_recover_unsaved_work() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("input.pdf");
        fs::write(&source, pdf_engine::create_fixture()?)?;
        let workspace = temp.path().join("sessions");
        let mut session = Session::open(&source, &workspace)?;
        let original_page = session.info.pages[0].id.clone();
        session.page_operation(0, PageOperation::Insert { at: 0 })?;
        let inserted = session.info.pages[0].id.clone();
        assert_eq!(session.info.pages[1].id, original_page);
        session.page_operation(1, PageOperation::Move { page: 1, target: 0 })?;
        assert_eq!(session.info.pages[0].id, original_page);
        assert_eq!(session.info.pages[1].id, inserted);
        session.page_operation(2, PageOperation::Delete { page: 1 })?;
        assert_eq!(session.info.pages.len(), 1);
        session.undo(3)?;
        assert_eq!(session.info.pages[1].id, inserted);
        let mut restored = Session::recover(&workspace, &session.info.id)?;
        assert_eq!(restored.info.version, 4);
        assert_eq!(restored.info.pages[0].id, original_page);
        restored.redo(4)?;
        assert_eq!(restored.info.pages.len(), 1);
        let output = temp.path().join("output.docx");
        restored.export_with_mode(5, "docx", &output, &[], "text")?;
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(fs::read(output)?))?;
        let mut xml = String::new();
        archive
            .by_name("word/document.xml")?
            .read_to_string(&mut xml)?;
        assert!(xml.contains("Hello PDF Editor"));
        let txt = temp.path().join("output.txt");
        restored.export(5, "txt", &txt, &[])?;
        assert!(fs::read_to_string(txt)?.contains("Unchanged reference text"));
        for format in ["png", "jpg", "pdf", "md"] {
            let path = temp.path().join(format!("page-1.{format}"));
            restored.export(5, format, &path, &[0])?;
            let bytes = fs::read(&path)?;
            assert!(bytes.len() > 20);
            match format {
                "png" => assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n")),
                "jpg" => assert!(bytes.starts_with(&[0xff, 0xd8, 0xff])),
                "pdf" => assert_eq!(pdf_engine::inspect(&bytes, None)?.len(), 1),
                _ => {
                    let md = std::str::from_utf8(&bytes)?;
                    let link = md.split("](").nth(1).unwrap().split(')').next().unwrap();
                    assert!(path.parent().unwrap().join(link).exists());
                }
            }
            assert!(restored.export(5, format, &path, &[0]).is_err());
        }
        Ok(())
    }

    #[test]
    fn added_text_annotations_and_deletion_survive_history() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("input.pdf");
        fs::write(&source, pdf_engine::create_fixture()?)?;
        let mut session = Session::open(&source, &temp.path().join("sessions"))?;
        let second_id = session.info.pages[0].text_objects[1].id.clone();
        session.object_operation(
            0,
            ObjectOperation::InsertText {
                page: 0,
                text: "New text 123".into(),
                x: 60.,
                y: 540.,
                font_size: 16.,
                font_path: None,
            },
        )?;
        assert_eq!(session.info.pages[0].text_objects.len(), 3);
        let added_id = session.info.pages[0].text_objects[2].id.clone();
        session.object_operation(1, ObjectOperation::Highlight { page: 0, index: 0 })?;
        session.object_operation(2, ObjectOperation::Delete { page: 0, index: 0 })?;
        assert_eq!(session.info.pages[0].text_objects[0].id, second_id);
        assert_eq!(session.info.pages[0].text_objects[1].id, added_id);
        session.undo(3)?;
        assert_eq!(session.info.pages[0].text_objects[2].id, added_id);
        session.object_operation(
            4,
            ObjectOperation::Ink {
                page: 0,
                strokes: vec![vec![[0.1, 0.1], [0.2, 0.7], [0.3, 0.2], [0.4, 0.8]]],
            },
        )?;
        let drawing = temp.path().join("drawing.png");
        pdf_engine::render_png(&session.bytes()?, 0, &drawing)?;
        let drawing_pixels = fs::read(&drawing)?;
        session.undo(5)?;
        let before_drawing = temp.path().join("before-drawing.png");
        pdf_engine::render_png(&session.bytes()?, 0, &before_drawing)?;
        assert!(
            drawing_pixels != fs::read(before_drawing)?,
            "ink must render after save/reopen"
        );
        let annotations: serde_json::Value =
            serde_json::from_str(&pdf_engine::annotations::list(&session.bytes()?, 0)?)?;
        assert_eq!(annotations.as_array().unwrap().len(), 1);
        session.object_operation(6, ObjectOperation::DeleteAnnotation { page: 0, index: 0 })?;
        assert_eq!(pdf_engine::annotations::list(&session.bytes()?, 0)?, "[]");
        session.undo(7)?;
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&pdf_engine::annotations::list(
                &session.bytes()?,
                0
            )?)?
            .as_array()
            .unwrap()
            .len(),
            1
        );
        let view = serde_json::json!({"version":8, "page_id":session.info.pages[0].id,
            "selected_id":session.info.pages[0].text_objects[0].id, "draft":"Pending new text"})
        .to_string();
        session.view_state(8, Some(&view))?;
        assert_eq!(session.view_state(8, None)?, view);
        assert!(temp.path().join("sessions/catalog.sqlite").exists());
        assert!(!session.directory.join("catalog-error.log").exists());
        Ok(())
    }
    #[test]
    fn session_transaction_history_and_source_protection() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("input.pdf");
        let original = pdf_engine::create_fixture()?;
        fs::write(&source, &original)?;
        let mut session = Session::open(&source, &temp.path().join("sessions"))?;
        let object = session.info.pages[0].text_objects[0].id.clone();
        assert!(session.replace(9, &object, "Hello PDF").is_err());
        assert_eq!(session.info.version, 0);
        session.replace(0, &object, "Hello PDF")?;
        assert!(session.info.dirty);
        session.undo(1)?;
        assert_eq!(
            session.info.pages[0].text_objects[0].text,
            "Hello PDF Editor"
        );
        assert!(!session.info.dirty);
        session.redo(2)?;
        assert_eq!(session.info.pages[0].text_objects[0].text, "Hello PDF");
        let version = session.info.version;
        assert!(
            session
                .replace(version, &object, "Hello PDF Hello PDF Hello PDF")
                .is_err()
        );
        assert_eq!(session.info.version, version);
        assert!(session.save(version, &source).is_err());
        assert_eq!(fs::read(&source)?, original);
        let destination = temp.path().join("output.pdf");
        session.save(version, &destination)?;
        assert!(!session.info.dirty);
        assert!(session.save(version, &destination).is_err());
        let reopened = Session::open(&destination, &temp.path().join("sessions"))?;
        assert_eq!(reopened.info.pages[0].text_objects[0].text, "Hello PDF");
        Ok(())
    }
}
