//! What misaki needs that is too big to build into an app: the lexicons and spaCy's tagger. Magpie reads them from
//! the voice download (Magpie's change; upstream embeds them with `include_str!`).
use crate::language::Language;
use crate::lexicon::PhonemeEntry;
use std::collections::HashMap;
use std::path::Path;

pub struct Data {
    pub golds: HashMap<String, PhonemeEntry>,
    pub silvers: HashMap<String, PhonemeEntry>,
    pub tagger: Vec<u8>,
    pub tagger_labels: String,
}

impl Data {
    /// `{us,gb}_gold.json`, `{us,gb}_silver.json`, `tagger.bin` and `tagger_labels.txt` from `dir`.
    pub fn from_dir(dir: &Path, lang: Language) -> Result<Self, String> {
        let accent = match lang {
            Language::EnglishUS => "us",
            Language::EnglishGB => "gb",
        };
        let read = |name: &str| std::fs::read(dir.join(name)).map_err(|e| format!("{name}: {e}"));
        let json = |name: &str| -> Result<HashMap<String, PhonemeEntry>, String> {
            serde_json::from_slice(&read(name)?).map_err(|e| format!("{name}: {e}"))
        };
        Ok(Self {
            golds: json(&format!("{accent}_gold.json"))?,
            silvers: json(&format!("{accent}_silver.json"))?,
            tagger: read("tagger.bin")?,
            tagger_labels: String::from_utf8(read("tagger_labels.txt")?).map_err(|e| e.to_string())?,
        })
    }

    /// For the tests: the data directory named by `MISAKI_DATA`.
    pub fn for_tests(lang: Language) -> Self {
        let dir = std::env::var("MISAKI_DATA").expect("set MISAKI_DATA to a directory holding misaki's data files");
        Self::from_dir(Path::new(&dir), lang).unwrap()
    }
}
