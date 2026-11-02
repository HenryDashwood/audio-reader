//! Text to the phonemes Kokoro reads, on the phone, for Magpie's downloadable voice.
//!
//! misaki-rs does the work: misaki 0.9.4's lexicons and spaCy's tokenizer and tagger, ported to Rust. What misaki
//! can't say goes to [`WordFallback`]: a lexicon generated at build time (CMUdict, then espeak-ng, which never ships
//! in the app) and, for words in no lexicon, a small model. Everything is read from the voice download's folder.

mod ffi;
#[cfg(target_os = "android")]
mod jni;
pub mod net;
pub mod normalize;

use misaki_rs::fallback::FallbackError;
use misaki_rs::{Data, Fallback, G2P, Language};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

/// One token of the text, as misaki splits it: its characters, what Kokoro says for it, and what follows it.
#[derive(Serialize, Debug)]
pub struct Token {
    pub text: String,
    pub phonemes: String,
    pub whitespace: String,
    /// Where it came from in the text given, in UTF-16 code units (what Swift's NSRange and Kotlin's String count).
    /// A written-out abbreviation covers the whole abbreviation: "Street" from "St." covers "St.".
    pub start: usize,
    pub end: usize,
}

#[derive(Serialize, Debug)]
pub struct Phonemes {
    /// The phoneme string Kokoro takes, before its vocabulary drops anything it doesn't know.
    pub phonemes: String,
    pub tokens: Vec<Token>,
}

pub struct Phonemizer {
    g2p: G2P,
}

impl Phonemizer {
    /// Load everything for one accent from `dir`: misaki's data, `lexicon_{us,gb}.json` and `g2p_{us,gb}.g2p`.
    pub fn open(dir: &Path, british: bool) -> Result<Self, String> {
        let (lang, accent) = if british { (Language::EnglishGB, "gb") } else { (Language::EnglishUS, "us") };
        let data = Data::from_dir(dir, lang)?;
        let fallback = WordFallback::open(dir, accent, british)?;
        Ok(Self { g2p: G2P::with_fallback(lang, data, Some(Box::new(fallback))) })
    }

    pub fn phonemize(&self, text: &str) -> Result<Phonemes, String> {
        let normalized = normalize::normalize(text);
        let (phonemes, tokens) = self.g2p.g2p(&normalized.text).map_err(|e| e.to_string())?;
        let utf16 = |byte: usize| text[..byte].encode_utf16().count();
        let mut at = 0; // Tokens come in order: find each one after the last
        let tokens = tokens
            .into_iter()
            .map(|t| {
                let found = normalized.text[at..].find(&t.text).map(|i| at + i);
                let span = found.map_or(at..at, |s| s..s + t.text.len());
                at = span.end;
                let original = normalized.to_original(span);
                Token {
                    start: utf16(original.start),
                    end: utf16(original.end),
                    text: t.text,
                    phonemes: t.phonemes.unwrap_or_default(),
                    whitespace: t.whitespace,
                }
            })
            .collect();
        Ok(Phonemes { phonemes, tokens })
    }
}

#[derive(Deserialize)]
struct LexiconFile {
    letters: HashMap<String, String>,
    words: HashMap<String, String>,
}

/// What misaki can't say: the build-time lexicon, then the model, then the letters spelled out.
pub struct WordFallback {
    letters: HashMap<String, String>,
    words: HashMap<String, String>,
    net: net::G2PNet,
    guesses: Mutex<HashMap<String, Option<String>>>, // The model is slow-ish, and a name tends to recur
    british: bool,
}

impl WordFallback {
    pub fn open(dir: &Path, accent: &str, british: bool) -> Result<Self, String> {
        let name = format!("lexicon_{accent}.json");
        let bytes = std::fs::read(dir.join(&name)).map_err(|e| format!("{name}: {e}"))?;
        let file: LexiconFile = serde_json::from_slice(&bytes).map_err(|e| format!("{name}: {e}"))?;
        let name = format!("g2p_{accent}.g2p");
        let net = net::G2PNet::load(&std::fs::read(dir.join(&name)).map_err(|e| format!("{name}: {e}"))?)?;
        Ok(Self { letters: file.letters, words: file.words, net, guesses: Mutex::new(HashMap::new()), british })
    }

    /// The lexicon's entry for a lowercase word, else the model's guess.
    fn word(&self, lower: &str) -> Option<String> {
        if let Some(ps) = self.words.get(lower) {
            return Some(ps.clone());
        }
        let mut guesses = self.guesses.lock().unwrap_or_else(|e| e.into_inner());
        guesses.entry(lower.to_string()).or_insert_with(|| self.net.phonemize(lower)).clone()
    }

    fn lookup(&self, word: &str) -> Option<String> {
        let lower = word.to_lowercase().replace('’', "'");
        if let Some(ps) = self.words.get(&lower) {
            return Some(ps.clone());
        }
        // A possessive on a word we can say: the ending misaki gives known words
        for suffix in ["'s", "s'"] {
            if let Some(stem) = lower.strip_suffix(suffix) {
                if let Some(ps) = self.word(stem) {
                    let last = ps.chars().last().unwrap_or(' ');
                    let ending = if "szʃʒʧʤ".contains(last) {
                        if self.british { "ɪz" } else { "ᵻz" }
                    } else if "ptkfθ".contains(last) {
                        "s"
                    } else {
                        "z"
                    };
                    return Some(format!("{ps}{ending}"));
                }
            }
        }
        // Parts joined by hyphens or the like, each said in turn
        let parts: Vec<_> = lower.split(|c: char| !c.is_alphabetic() && c != '\'').filter(|p| !p.is_empty()).collect();
        if parts.len() > 1 {
            return parts.iter().map(|p| self.lookup(p)).collect::<Option<Vec<_>>>().map(|ps| ps.join(" "));
        }
        self.word(&lower)
    }
}

impl Fallback for WordFallback {
    fn phonemize(&self, word: &str) -> Result<String, FallbackError> {
        // Never an error: misaki-rs abandons the whole sentence when its fallback fails
        Ok(self.lookup(word).unwrap_or_else(|| {
            let letters: Vec<_> =
                word.to_lowercase().chars().filter_map(|c| self.letters.get(&c.to_string()).cloned()).collect();
            letters.join(" ")
        }))
    }
}
