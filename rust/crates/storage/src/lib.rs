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
            CREATE TABLE IF NOT EXISTS members(document_id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS hidden_sources(source_key TEXT PRIMARY KEY);")?;
        Ok(Self(connection))
    }
    pub fn command(&self, command: &str, request: &serde_json::Value) -> Result<String> {
        let id = request["id"].as_str().unwrap_or("");
        match command {
            "list" => {}
            "forget" | "show" => {
                let source = request["source_key"].as_str().unwrap_or("");
                ensure!(!source.is_empty(), "INVALID_SOURCE_KEY");
                if command == "forget" {
                    self.0
                        .execute("INSERT OR IGNORE INTO hidden_sources VALUES(?1)", [source])?;
                } else {
                    self.0
                        .execute("DELETE FROM hidden_sources WHERE source_key=?1", [source])?;
                }
            }
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
                let fallback = vec![request["document_id"].clone()];
                let documents = request["document_ids"].as_array().unwrap_or(&fallback);
                let transaction = self.0.unchecked_transaction()?;
                for document in documents {
                    let document = document.as_str().unwrap_or("");
                    if let Some(project) = request["project_id"].as_str() {
                        transaction.execute("INSERT INTO members VALUES(?1,?2) ON CONFLICT(document_id) DO UPDATE SET project_id=excluded.project_id", params![document,project])?;
                    } else {
                        transaction
                            .execute("DELETE FROM members WHERE document_id=?1", [document])?;
                    }
                }
                transaction.commit()?;
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
        let mut statement = self
            .0
            .prepare("SELECT source_key FROM hidden_sources ORDER BY source_key")?;
        let hidden = statement
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(
            serde_json::json!({"projects":projects,"memberships":members,"hidden_sources":hidden})
                .to_string(),
        )
    }
}

impl Catalog {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        // The UI searches its document DTOs. Keep only catalog metadata here;
        // do not rebuild an unqueried full-text index on every durable commit.
        connection.execute_batch("PRAGMA journal_mode=WAL;
          CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, metadata TEXT NOT NULL, updated INTEGER NOT NULL);")?;
        Ok(Self(connection))
    }
    pub fn index(&mut self, document: &DocumentInfo) -> Result<()> {
        self.0.execute("INSERT INTO documents(id,metadata,updated) VALUES(?1,?2,unixepoch()) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata, updated=excluded.updated",
            params![document.id, serde_json::to_string(document)?])?;
        Ok(())
    }
}
