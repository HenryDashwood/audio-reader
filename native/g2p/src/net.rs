//! The spelling-to-phonemes model for words in no lexicon: a pre-norm transformer encoder over three slots per
//! letter, decoded greedily as CTC. Plain Rust, so the iOS and Android apps share it without another runtime.

use std::collections::HashMap;

#[derive(serde::Deserialize)]
struct Header {
    letters: Vec<String>,
    phonemes: Vec<String>,
    up: usize,
    heads: usize,
    layers: usize,
    tensors: HashMap<String, (Vec<usize>, usize)>,
}

struct Linear {
    w: Vec<f32>, // (out, in), row-major as PyTorch stores it
    b: Vec<f32>,
    out: usize,
    inp: usize,
}

impl Linear {
    fn apply(&self, x: &[f32], rows: usize) -> Vec<f32> {
        let mut y = vec![0f32; rows * self.out];
        for r in 0..rows {
            let xr = &x[r * self.inp..(r + 1) * self.inp];
            for o in 0..self.out {
                let w = &self.w[o * self.inp..(o + 1) * self.inp];
                y[r * self.out + o] = self.b[o] + xr.iter().zip(w).map(|(a, b)| a * b).sum::<f32>();
            }
        }
        y
    }
}

struct Norm {
    w: Vec<f32>,
    b: Vec<f32>,
}

impl Norm {
    fn apply(&self, x: &[f32], d: usize) -> Vec<f32> {
        x.chunks(d)
            .flat_map(|row| {
                let mean = row.iter().sum::<f32>() / d as f32;
                let var = row.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / d as f32;
                let inv = 1.0 / (var + 1e-5).sqrt();
                row.iter().enumerate().map(move |(i, v)| (v - mean) * inv * self.w[i] + self.b[i]).collect::<Vec<_>>()
            })
            .collect()
    }
}

struct Layer {
    norm1: Norm,
    qkv: Linear,
    proj: Linear,
    norm2: Norm,
    ff1: Linear,
    ff2: Linear,
}

pub struct G2PNet {
    letters: HashMap<char, usize>,
    phonemes: Vec<String>,
    embed: Vec<f32>,
    slot: Vec<f32>,
    pos: Vec<f32>,
    layers: Vec<Layer>,
    norm: Norm,
    out: Linear,
    up: usize,
    heads: usize,
    d: usize,
}

impl G2PNet {
    pub fn load(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() < 8 || &bytes[..4] != b"G2P1" {
            return Err("not a G2P1 file".into());
        }
        let n = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let h: Header = serde_json::from_slice(&bytes[8..8 + n]).map_err(|e| e.to_string())?;
        let data = &bytes[8 + n..];
        let get = |name: &str| -> Result<(Vec<f32>, Vec<usize>), String> {
            let (shape, offset) = h.tensors.get(name).ok_or(format!("missing {name}"))?;
            let count: usize = shape.iter().product();
            let raw = data.get(2 * offset..2 * (offset + count)).ok_or(format!("truncated {name}"))?;
            Ok((raw.chunks(2).map(|b| f16_to_f32(u16::from_le_bytes([b[0], b[1]]))).collect(), shape.clone()))
        };
        let linear = |name: &str| -> Result<Linear, String> {
            let (w, s) = get(&format!("{name}.weight"))?;
            let (b, _) = get(&format!("{name}.bias"))?;
            Ok(Linear { w, b, out: s[0], inp: s[1] })
        };
        let norm = |name: &str| -> Result<Norm, String> {
            Ok(Norm { w: get(&format!("{name}.weight"))?.0, b: get(&format!("{name}.bias"))?.0 })
        };
        let mut layers = Vec::new();
        for i in 0..h.layers {
            let p = format!("encoder.layers.{i}");
            let (w, s) = get(&format!("{p}.self_attn.in_proj_weight"))?;
            let (b, _) = get(&format!("{p}.self_attn.in_proj_bias"))?;
            layers.push(Layer {
                norm1: norm(&format!("{p}.norm1"))?,
                qkv: Linear { w, b, out: s[0], inp: s[1] },
                proj: linear(&format!("{p}.self_attn.out_proj"))?,
                norm2: norm(&format!("{p}.norm2"))?,
                ff1: linear(&format!("{p}.linear1"))?,
                ff2: linear(&format!("{p}.linear2"))?,
            });
        }
        let (embed, es) = get("embed.weight")?;
        let letters = h.letters.iter().enumerate().filter_map(|(i, s)| {
            let mut cs = s.chars();
            match (cs.next(), cs.next()) {
                (Some(c), None) => Some((c, i)),
                _ => None, // <pad>
            }
        });
        Ok(G2PNet {
            letters: letters.collect(),
            phonemes: h.phonemes,
            embed,
            slot: get("slot")?.0,
            pos: get("pos")?.0,
            layers,
            norm: norm("out.0")?,
            out: linear("out.1")?,
            up: h.up,
            heads: h.heads,
            d: es[1],
        })
    }

    /// Phonemes for a lowercase word, or None if it has a letter the model never saw.
    pub fn phonemize(&self, word: &str) -> Option<String> {
        let ids: Vec<usize> = word.chars().map(|c| self.letters.get(&c).copied()).collect::<Option<_>>()?;
        let (d, t) = (self.d, ids.len() * self.up);
        if ids.is_empty() || t * d > self.pos.len() {
            return None;
        }
        let mut x = vec![0f32; t * d];
        for (i, &id) in ids.iter().enumerate() {
            for s in 0..self.up {
                let r = i * self.up + s;
                for k in 0..d {
                    x[r * d + k] = self.embed[id * d + k] + self.slot[s * d + k] + self.pos[r * d + k];
                }
            }
        }
        for layer in &self.layers {
            let attended = self.attention(layer, &layer.norm1.apply(&x, d), t);
            x.iter_mut().zip(&attended).for_each(|(a, b)| *a += b);
            let mut h = layer.ff1.apply(&layer.norm2.apply(&x, d), t);
            h.iter_mut().for_each(|v| *v = v.max(0.0));
            x.iter_mut().zip(&layer.ff2.apply(&h, t)).for_each(|(a, b)| *a += b);
        }
        let logits = self.out.apply(&self.norm.apply(&x, d), t);
        let (mut out, mut prev) = (String::new(), 0usize);
        for row in logits.chunks(self.phonemes.len()) {
            let best = row.iter().enumerate().fold((0, f32::MIN), |m, (i, &v)| if v > m.1 { (i, v) } else { m }).0;
            if best != prev && best != 0 {
                out.push_str(&self.phonemes[best]);
            }
            prev = best;
        }
        Some(out)
    }

    fn attention(&self, layer: &Layer, x: &[f32], t: usize) -> Vec<f32> {
        let (d, hd) = (self.d, self.d / self.heads);
        let qkv = layer.qkv.apply(x, t); // (t, 3d): q, then k, then v
        let scale = 1.0 / (hd as f32).sqrt();
        let mut mixed = vec![0f32; t * d];
        let mut weights = vec![0f32; t];
        for h in 0..self.heads {
            for i in 0..t {
                let q = &qkv[i * 3 * d + h * hd..i * 3 * d + (h + 1) * hd];
                for j in 0..t {
                    let k = &qkv[j * 3 * d + d + h * hd..j * 3 * d + d + (h + 1) * hd];
                    weights[j] = q.iter().zip(k).map(|(a, b)| a * b).sum::<f32>() * scale;
                }
                let max = weights.iter().cloned().fold(f32::MIN, f32::max);
                let sum: f32 = weights.iter_mut().map(|w| {
                    *w = (*w - max).exp();
                    *w
                }).sum();
                for j in 0..t {
                    let v = &qkv[j * 3 * d + 2 * d + h * hd..j * 3 * d + 2 * d + (h + 1) * hd];
                    let w = weights[j] / sum;
                    for k in 0..hd {
                        mixed[i * d + h * hd + k] += w * v[k];
                    }
                }
            }
        }
        layer.proj.apply(&mixed, t)
    }
}

fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h >> 15) as u32) << 31;
    let exp = ((h >> 10) & 0x1f) as u32;
    let frac = (h & 0x3ff) as u32;
    let bits = match exp {
        0 if frac == 0 => sign,
        0 => {
            // Subnormal: normalise it
            let mut e = 127 - 15 + 1;
            let mut f = frac;
            while f & 0x400 == 0 {
                f <<= 1;
                e -= 1;
            }
            sign | (e << 23) | ((f & 0x3ff) << 13)
        }
        0x1f => sign | 0x7f80_0000 | (frac << 13),
        _ => sign | ((exp + 127 - 15) << 23) | (frac << 13),
    };
    f32::from_bits(bits)
}
