use anyhow::{Result, ensure};
use document_core::DocumentInfo;
use rusqlite::{Connection, params};
use std::path::Path;

/// SQLite is a rebuildable catalog/search index. Immutable working files and
/// atomic recovery manifests remain the document durability authority.
pub struct Catalog(Connection);

/// User-owned organization is stored separately from the rebuildable search index.
pub struct Projects(Connection);
impl Projects {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, name TEXT NOT NULL, updated INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS members(document_id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE);")?;
        Ok(Self(connection))
    }
    pub fn command(&self, command: &str, request: &serde_json::Value) -> Result<String> {
        let id = request["id"].as_str().unwrap_or("");
        match command {
            "list" => {}
            "create" | "rename" => {
                let name = request["name"].as_str().unwrap_or("").trim();
                ensure!(
                    !name.is_empty()
                        && name.chars().count() <= 80
                        && !name.chars().any(char::is_control),
                    "INVALID_PROJECT_NAME"
                );
                if command == "create" {
                    self.0.execute(
                        "INSERT INTO projects VALUES(?1,?2,unixepoch())",
                        params![id, name],
                    )?;
                } else {
                    ensure!(
                        self.0.execute(
                            "UPDATE projects SET name=?2, updated=unixepoch() WHERE id=?1",
                            params![id, name]
                        )? == 1,
                        "PROJECT_NOT_FOUND"
                    );
                }
            }
            "delete" => {
                ensure!(
                    self.0.execute("DELETE FROM projects WHERE id=?1", [id])? == 1,
                    "PROJECT_NOT_FOUND"
                );
            }
            "assign" => {
                let document = request["document_id"].as_str().unwrap_or("");
                if let Some(project) = request["project_id"].as_str() {
                    self.0.execute("INSERT INTO members VALUES(?1,?2) ON CONFLICT(document_id) DO UPDATE SET project_id=excluded.project_id", params![document,project])?;
                } else {
                    self.0
                        .execute("DELETE FROM members WHERE document_id=?1", [document])?;
                }
            }
            _ => anyhow::bail!("UNKNOWN_PROJECT_COMMAND"),
        }
        let mut statement = self
            .0
            .prepare("SELECT id,name,updated FROM projects ORDER BY updated DESC,name,id")?;
        let projects = statement.query_map([], |r| Ok(serde_json::json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"updated":r.get::<_,i64>(2)?})))?.collect::<std::result::Result<Vec<_>, _>>()?;
        let mut statement = self
            .0
            .prepare("SELECT document_id,project_id FROM members")?;
        let members = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    serde_json::Value::String(r.get::<_, String>(1)?),
                ))
            })?
            .collect::<std::result::Result<serde_json::Map<String, serde_json::Value>, _>>();
        let members = members?;
        Ok(serde_json::json!({"projects":projects,"memberships":members}).to_string())
    }
}

impl Catalog {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
          CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, metadata TEXT NOT NULL, updated INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS pages(id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL, text_content TEXT NOT NULL);
          CREATE VIRTUAL TABLE IF NOT EXISTS text_index USING fts5(page_id UNINDEXED, document_id UNINDEXED, text_content, tokenize='trigram');
          CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS ocr_cache(cache_key TEXT PRIMARY KEY, document_id TEXT NOT NULL, result TEXT NOT NULL);
          PRAGMA user_version=1;")?;
        Ok(Self(connection))
    }
    pub fn index(&mut self, document: &DocumentInfo) -> Result<()> {
        let transaction = self.0.transaction()?;
        transaction.execute("INSERT INTO documents(id,metadata,updated) VALUES(?1,?2,unixepoch()) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata, updated=excluded.updated",
            params![document.id, serde_json::to_string(document)?])?;
        transaction.execute("DELETE FROM pages WHERE document_id=?1", [&document.id])?;
        transaction.execute(
            "DELETE FROM text_index WHERE document_id=?1",
            [&document.id],
        )?;
        for page in &document.pages {
            transaction.execute(
                "INSERT INTO pages VALUES(?1,?2,?3,?4)",
                params![page.id, document.id, page.index, page.text_content],
            )?;
            transaction.execute(
                "INSERT INTO text_index VALUES(?1,?2,?3)",
                params![page.id, document.id, page.text_content],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }
    pub fn set(&self, key: &str, value: &str) -> Result<()> {
        serde_json::from_str::<serde_json::Value>(value)?;
        self.0.execute("INSERT INTO settings VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value])?;
        Ok(())
    }
    pub fn settings(&self) -> Result<String> {
        let mut statement = self
            .0
            .prepare("SELECT key,value FROM settings ORDER BY key")?;
        let mut output = serde_json::Map::new();
        for row in
            statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        {
            let (key, value) = row?;
            output.insert(key, serde_json::from_str(&value)?);
        }
        Ok(serde_json::Value::Object(output).to_string())
    }
    pub fn cache_ocr(&self, key: &str, document: &str, result: &str) -> Result<()> {
        self.0.execute("INSERT INTO ocr_cache VALUES(?1,?2,?3) ON CONFLICT(cache_key) DO UPDATE SET result=excluded.result", params![key,document,result])?;
        Ok(())
    }
}
