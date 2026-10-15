use anyhow::{Context, Result};
use app_api::session::Session;
use std::{env, fs, path::Path};

fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("ocr") if args.len() == 2 => {
            println!(
                "{}",
                serde_json::to_string_pretty(&ocr_engine::recognize(&args[1], "en-US")?)?
            );
        }
        Some("fixture") if args.len() == 2 => {
            let destination = Path::new(&args[1]);
            anyhow::ensure!(!destination.exists(), "Destination exists");
            fs::write(destination, pdf_engine::create_fixture()?)?;
        }
        Some("inspect") if args.len() == 2 => {
            let session = Session::open(Path::new(&args[1]), Path::new("../.work/sessions"))?;
            println!("{}", serde_json::to_string_pretty(&session.info)?);
        }
        Some("render") if args.len() == 3 => {
            pdf_engine::render_png(&fs::read(&args[1])?, 0, Path::new(&args[2]))?;
        }
        Some("replace") if args.len() == 5 => {
            let mut session = Session::open(Path::new(&args[1]), Path::new("../.work/sessions"))?;
            let target = session
                .info
                .pages
                .iter()
                .flat_map(|p| &p.text_objects)
                .find(|o| o.text == args[2])
                .context("Exact text object not found")?
                .id
                .clone();
            session.replace(0, &target, &args[3])?;
            session.save(1, Path::new(&args[4]))?;
            println!("{}", serde_json::to_string_pretty(&session.info)?);
        }
        _ => anyhow::bail!(
            "Usage: pdf-editor fixture <new.pdf> | inspect <input.pdf> | render <input.pdf> <page.png> | replace <input.pdf> <exact-original-text> <replacement> <new.pdf>"
        ),
    }
    Ok(())
}
