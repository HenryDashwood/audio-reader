//! `cargo run --release --example phonemize -- <voice folder> us|gb < lines.txt`: one JSON result per line of input.
use magpie_g2p::Phonemizer;
use std::io::BufRead;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let t = std::time::Instant::now();
    let p = Phonemizer::open(Path::new(&args[1]), args.get(2).map(String::as_str) == Some("gb")).unwrap();
    eprintln!("loaded in {:?}", t.elapsed());
    let t = std::time::Instant::now();
    for line in std::io::stdin().lock().lines() {
        println!("{}", serde_json::to_string(&p.phonemize(&line.unwrap()).unwrap()).unwrap());
    }
    eprintln!("phonemized in {:?}", t.elapsed());
}
