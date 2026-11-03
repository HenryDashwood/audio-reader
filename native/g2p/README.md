# magpie-g2p

Text to the phonemes Kokoro reads, on the phone, for the optional downloadable voice. One Rust library for both apps:
a C interface for Swift (`include/magpie_g2p.h`) and JNI for Kotlin (`com.henrydashwood.magpie.playback.NativePhonemizer`).

1. **Abbreviations and units** are written out in context (`src/normalize.rs`): "St. Paul's" is Saint, "Baker St."
   Street, "5 km" kilometres. Every token keeps its UTF-16 range in the original text, for highlighting and seeking.
2. **misaki-rs** (`vendor/misaki-rs`) does the rest: misaki 0.9.4's lexicons, and spaCy's tokenizer and tagger
   ported to Rust. It matches Python misaki on every line of a 1,974-line corpus that has no unknown word.
3. **Words misaki can't say** go to `WordFallback` (`src/lib.rs`): a lexicon generated at build time (CMUdict for US
   English, then espeak-ng), then a 4.8M-parameter model (`src/net.rs`), then the letters spelled out. espeak-ng is
   GPL, so it only ever runs when the lexicon is generated, never in the apps.

## The voice folder

`Phonemizer::open` reads everything from the voice download, so none of it is in the app binary:

| File | What it is |
|---|---|
| `us_gold.json`, `us_silver.json`, `gb_gold.json`, `gb_silver.json` | misaki 0.9.4's lexicons |
| `tagger.bin`, `tagger_labels.txt` | misaki-rs's port of spaCy's `en_core_web_sm` tagger |
| `lexicon_us.json`, `lexicon_gb.json` | `{"letters": …, "words": …}`: words misaki can't say, from CMUdict and espeak-ng |
| `g2p_us.g2p`, `g2p_gb.g2p` | The spelling-to-phonemes model: `G2P1`, a JSON header, 16-bit weights |

## Building

```sh
scripts/build-g2p.sh ios        # native/g2p/build/MagpieG2P.xcframework
scripts/build-g2p.sh android    # android/app/src/main/jniLibs (needs the NDK and cargo-ndk)
MISAKI_DATA=<voice folder> rustup run 1.97 cargo test --workspace --manifest-path native/g2p/Cargo.toml
rustup run 1.97 cargo run --release --manifest-path native/g2p/Cargo.toml --example phonemize -- <voice folder> gb < text.txt
```

## The vendored misaki-rs

[misaki-rs](https://github.com/MicheleYin/misaki-rs) 0.8.0 (MIT), changed for the apps:

- The lexicons and tagger load from files (`Data::from_dir`) instead of being compiled in, about 20 MB per
  architecture.
- The unused perceptron tagger and its 5.7 MB of weights are gone, and so is the espeak-ng fallback.
- The fallback is asked only about parts with letters in them. Upstream also asked about numbers, which misaki-rs
  resolves in a later pass than Python misaki, so a fallback silenced "1." and "50%".
