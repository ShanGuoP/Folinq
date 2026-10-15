use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Rect {
    pub left: f32,
    pub bottom: f32,
    pub right: f32,
    pub top: f32,
}

impl Rect {
    pub fn intersects(&self, other: &Self) -> bool {
        self.left < other.right
            && self.right > other.left
            && self.bottom < other.top
            && self.top > other.bottom
    }
    pub fn contains(&self, other: &Self, tolerance: f32) -> bool {
        other.left >= self.left - tolerance
            && other.bottom >= self.bottom - tolerance
            && other.right <= self.right + tolerance
            && other.top <= self.top + tolerance
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TextObject {
    pub id: String,
    pub page_id: String,
    pub object_index: u32,
    pub text: String,
    pub bounds: Rect,
    #[serde(default)]
    pub layout_bounds: Option<Rect>,
    pub display_bounds: Rect,
    pub font_size: f32,
    #[serde(default = "default_true")]
    pub editable: bool,
}
fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OcrWord {
    pub text: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OcrResult {
    pub provider: String,
    pub language: String,
    pub text: String,
    pub width: u32,
    pub height: u32,
    pub words: Vec<OcrWord>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TextEditOptions {
    pub shrink_to_fit: bool,
    pub font_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PageInfo {
    pub id: String,
    pub index: u16,
    pub width: f32,
    pub height: f32,
    pub text_objects: Vec<TextObject>,
    #[serde(default)]
    pub text_content: String,
    #[serde(default)]
    pub image_objects: Vec<ImageObject>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ImageObject {
    pub id: String,
    pub page_id: String,
    pub object_index: u32,
    pub bounds: Rect,
    pub display_bounds: Rect,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DocumentInfo {
    pub id: String,
    pub source_path: String,
    pub source_hash: String,
    pub working_path: String,
    pub version: u64,
    pub dirty: bool,
    pub can_undo: bool,
    pub can_redo: bool,
    pub pages: Vec<PageInfo>,
}

pub fn check_version(actual: u64, expected: u64) -> Result<()> {
    ensure!(
        actual == expected,
        "STALE_VERSION: expected {expected}, current {actual}"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_stale_commands() {
        assert!(check_version(3, 2).is_err());
        assert!(check_version(3, 3).is_ok());
    }
    #[test]
    fn layout_checks_all_edges() {
        let original = Rect {
            left: 10.,
            bottom: 10.,
            right: 30.,
            top: 30.,
        };
        assert!(original.contains(&original, 0.));
        assert!(!original.contains(
            &Rect {
                right: 40.,
                ..original.clone()
            },
            0.5
        ));
        assert!(!original.contains(
            &Rect {
                bottom: 0.,
                ..original.clone()
            },
            0.5
        ));
    }
}
