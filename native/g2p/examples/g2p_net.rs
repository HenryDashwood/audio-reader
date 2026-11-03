//! `cargo run --release --example g2p_net -- <file.g2p> < words.txt`: the spelling-to-phonemes model alone, one
//! lowercase word per line in, `word<TAB>phonemes` out.
use std::io::BufRead;

fn main() {
    let path = std::env::args().nth(1).expect("a .g2p file");
    let net = magpie_g2p::net::G2PNet::load(&std::fs::read(path).unwrap()).unwrap();
    for line in std::io::stdin().lock().lines() {
        let word = line.unwrap();
        println!("{}\t{}", word, net.phonemize(&word).unwrap_or_default());
    }
}
