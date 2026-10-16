use super::*;

fn fixture() -> Result<(tempfile::TempDir, PathBuf, Session)> {
    let temp = tempfile::tempdir()?;
    let source = temp.path().join("source.pdf");
    fs::write(&source, pdf_engine::create_fixture()?)?;
    let workspace = temp.path().join("sessions");
    let session = Session::open(&source, &workspace)?;
    Ok((temp, workspace, session))
}

fn rotate(session: &mut Session) -> Result<()> {
    session.page_operation(
        session.info.version,
        PageOperation::Rotate {
            page: 0,
            clockwise: true,
        },
    )
}

#[test]
fn recover_after_each_candidate_publication_and_retry_without_restart() -> Result<()> {
    for stage in 0..3 {
        let (_temp, workspace, mut session) = fixture()?;
        let original = session.bytes()?;
        fs::copy(
            &session.info.working_path,
            session.directory.join("version-1.pdf"),
        )?;
        if stage > 0 {
            let mut candidate = session.info.clone();
            candidate.version = 1;
            candidate.working_path = session
                .directory
                .join("version-1.pdf")
                .to_string_lossy()
                .into();
            session.journal(&candidate)?;
        }
        if stage < 2 {
            session = Session::recover(&workspace, &session.info.id)?;
        }
        assert_eq!(session.info.version, 0);
        rotate(&mut session)?;
        assert_eq!(session.info.version, 2);
        assert!(!session.directory.join("version-1.pdf").exists());
        assert!(!session.directory.join("version-1.json").exists());
        session.undo(2)?;
        assert_eq!(session.bytes()?, original);
        let mut restored = Session::recover(&workspace, &session.info.id)?;
        restored.redo(3)?;
        assert_eq!(restored.info.version, 4);
    }
    Ok(())
}

#[test]
fn failed_recovery_publication_preserves_history_and_can_retry() -> Result<()> {
    let (_temp, workspace, mut session) = fixture()?;
    rotate(&mut session)?;
    let record = fs::read(session.directory.join("recovery.json"))?;
    fs::remove_file(session.directory.join("recovery.json"))?;
    fs::create_dir(session.directory.join("recovery.json"))?;
    assert!(rotate(&mut session).is_err());
    assert_eq!(session.info.version, 1);
    assert!(session.directory.join("version-0.pdf").exists());
    assert!(session.directory.join("version-1.pdf").exists());
    fs::remove_dir(session.directory.join("recovery.json"))?;
    fs::write(session.directory.join("recovery.json"), record)?;
    let mut restored = Session::recover(&workspace, &session.info.id)?;
    rotate(&mut restored)?;
    assert_eq!(restored.info.version, 2);
    Ok(())
}

#[test]
fn disk_retention_matches_reachable_history_including_abandoned_redo() -> Result<()> {
    let (_temp, workspace, mut session) = fixture()?;
    let original = fs::read(session.directory.join("source.pdf"))?;
    for _ in 0..25 {
        rotate(&mut session)?;
    }
    let count = |s: &Session| {
        fs::read_dir(&s.directory)
            .unwrap()
            .flatten()
            .filter(|e| {
                e.path().extension().is_some_and(|e| e == "pdf")
                    && e.file_name().to_string_lossy().starts_with("version-")
            })
            .count()
    };
    assert_eq!(session.undo.len(), HISTORY_LIMIT);
    assert_eq!(count(&session), HISTORY_LIMIT + 1);
    for _ in 0..20 {
        session.undo(session.info.version)?;
    }
    assert_eq!(count(&session), HISTORY_LIMIT + 1);
    let abandoned = session.redo.clone();
    rotate(&mut session)?;
    assert!(session.redo.is_empty());
    for path in abandoned {
        assert!(!path.exists());
    }
    assert_eq!(count(&session), 2);
    assert_eq!(fs::read(session.directory.join("source.pdf"))?, original);
    let mut restored = Session::recover(&workspace, &session.info.id)?;
    restored.undo(restored.info.version)?;
    restored.redo(restored.info.version)?;
    assert_eq!(count(&restored), 2);
    Ok(())
}

#[test]
fn large_draft_is_durable_and_write_failure_keeps_previous_input() -> Result<()> {
    let (_temp, workspace, session) = fixture()?;
    let value = serde_json::json!({"version":0,"page_id":session.info.pages[0].id,
        "drafts":{"object":"a".repeat(70000)}, "edit_options":{}});
    session.view_state(0, Some(&value.to_string()))?;
    assert!(fs::metadata(session.directory.join("view.json"))?.len() < 65536);
    let restored = Session::recover(&workspace, &session.info.id)?;
    let read: serde_json::Value = serde_json::from_str(&restored.view_state(0, None)?)?;
    assert_eq!(read, value);
    let previous = fs::read(session.directory.join("drafts.json"))?;
    let oversized = serde_json::json!({"version":0,"page_id":session.info.pages[0].id,
        "drafts":{"object":"x".repeat(8 * 1024 * 1024)}});
    assert!(
        session
            .view_state(0, Some(&oversized.to_string()))
            .unwrap_err()
            .to_string()
            .contains("DRAFT_STATE_LIMIT")
    );
    assert_eq!(fs::read(session.directory.join("drafts.json"))?, previous);
    // Simulate loss of optional view preferences after the durable input write.
    fs::write(session.directory.join("view.json"), b"broken preferences")?;
    let recovered: serde_json::Value = serde_json::from_str(&session.view_state(0, None)?)?;
    assert_eq!(recovered, value);
    fs::remove_file(session.directory.join("drafts.json"))?;
    fs::create_dir(session.directory.join("drafts.json"))?;
    assert!(session.view_state(0, Some(&value.to_string())).is_err());
    Ok(())
}

#[test]
fn forget_record_persists_by_source_and_reopen_restores_without_deleting_files() -> Result<()> {
    let (_temp, workspace, first) = fixture()?;
    let source = PathBuf::from(&first.info.source_path);
    let original = fs::read(&source)?;
    let second = Session::open(&source, &workspace)?;
    let command = |name: &str, id: &str| -> Result<serde_json::Value> {
        Ok(serde_json::from_str(&crate::api::project_catalog(
            workspace.to_string_lossy().into(),
            name.into(),
            serde_json::json!({"document_id":id}).to_string(),
        )?)?)
    };
    let hidden = command("forget", &first.info.id)?;
    assert_eq!(hidden["hidden_sources"].as_array().unwrap().len(), 1);
    assert_eq!(
        command("list", "")?["hidden_sources"],
        hidden["hidden_sources"]
    );
    assert_eq!(fs::read(&source)?, original);
    for session in [&first, &second] {
        assert!(Path::new(&session.info.working_path).is_file());
        assert!(
            workspace
                .join(&session.info.id)
                .join("recovery.json")
                .is_file()
        );
        assert_eq!(
            Session::recover(&workspace, &session.info.id)?.bytes()?,
            session.bytes()?
        );
    }
    assert!(command("forget", "../../source.pdf").is_err());
    assert!(command("forget", &Uuid::new_v4().to_string()).is_err());
    command("show", &second.info.id)?;
    assert!(
        command("list", "")?["hidden_sources"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    command("forget", &second.info.id)?;
    let reopened: serde_json::Value = serde_json::from_str(&crate::api::open_document(
        source.to_string_lossy().into(),
        workspace.to_string_lossy().into(),
    )?)?;
    assert!(
        command("list", "")?["hidden_sources"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    crate::api::close_document(reopened["id"].as_str().unwrap().into())?;
    assert_eq!(fs::read(&source)?, original);
    Ok(())
}
