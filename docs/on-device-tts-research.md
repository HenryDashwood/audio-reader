# Building a compact, reliable on-device reading voice

Research brief · 15 September 2026

## Conclusion

This is a credible research project. The strongest starting hypothesis is that a single-language reading voice can combine explicit pronunciation and timing with a small neural acoustic model and an efficient waveform generator. Rebuilding a classical recorded-unit voice is also possible, but its storage requirements make it a less obvious first choice for bundling.

The goal should be **better than Alex for sustained reading on the target phone**, measured through intelligibility, reading accuracy, listening comfort, responsiveness and resource use. Sounding more human in a short demonstration is insufficient evidence.

This brief distinguishes published results, historical repository observations, and proposed experiments. No new models were trained or benchmarked for it. English and one initial voice are working assumptions, not final product constraints.

## 1. What Alex and Siri actually establish

### Alex: a recorded-unit lineage

There is direct historical evidence, beyond guessing from Alex's sound. Apple's Jerome Bellegarda describes an **Alex** corpus in a 2007 paper on pruning units for concatenative speech synthesis, identifying it as a MacinTalk voice database. This supports placing Alex in the recorded-unit tradition. It does not disclose every component of every subsequently shipped Alex version. [Bellegarda, 2007, author-uploaded paper](https://www.researchgate.net/publication/4249168_LSM-Based_Unit_Pruning_for_Concatenative_Speech_Synthesis).

In this approach, a speaker records a corpus. The system segments it into small units, finds a sequence matching the desired sounds and intonation, and joins the recordings. A sound changes with its neighbours, stress and position in a phrase, so keeping only one recording per sound loses useful variation. Removing redundant units reduces storage, but aggressive pruning can sacrifice coverage. That storage–quality tradeoff is the subject of the paper above.

**Interpretation:** modern alignment, recording selection and pruning could improve such a system. However, more training recordings can also produce a larger deployed database. The age of an algorithm does not imply a small voice package.

### Siri: several generations of technology

Apple's 2017 account describes a hybrid system: neural networks guide the selection of recorded half-phones. It reports at least 15 hours of high-quality recordings per voice, yielding roughly 1–2 million units. Its text frontend handles normalisation, pronunciation, stress and phrasing. Thus, neural guidance and concatenative synthesis can coexist. [Apple, 2017](https://machinelearning.apple.com/research/siri-voices).

By 2021, Apple described a fully neural mobile system using improvements to acoustic modelling and waveform generation, reporting 24 kHz speech generated three times faster than real time on mobile devices. These are that paper's results, not measurements of today's Siri or the oldest Magpie phone. [Apple, 2021](https://machinelearning.apple.com/research/on-device-neural-speech).

### The closest published match to this project

Apple's **Compact Neural TTS Voices for Accessibility** (2025) reports:

| Component | Optimised footprint |
| --- | ---: |
| Text frontend | 12 MB |
| FastSpeech 2 acoustic model | 2.6 MB |
| WaveRNN vocoder | 3.1 MB |
| Total, rounded | 18 MB |

It uses weight sharing, quantisation, smaller networks and sparsity. Reported latency is 13 ms; listening scores are 4.09 versus 4.19 for its larger baseline. Training used 36 hours of proprietary speech and five million frontend examples labelled by Apple's production system. The phone is described only as a recent iOS device. These results establish feasibility; they do not establish Alex superiority, long-reading battery life or reproducibility with public data. I found no accompanying released weights or complete training recipe in the cited materials. [Apple paper, 2025](https://arxiv.org/html/2501.17332v1).

## 2. The main ways to create a voice

The assessments below are engineering interpretations for this project, rather than a benchmark ranking.

| Approach | How it makes speech | Useful property | Main research concern |
| --- | --- | --- | --- |
| Formant synthesis | Rules drive a simplified model of speech resonances | Very small; direct control | Achieving the desired timbre and listening comfort |
| Diphone synthesis | Joins recordings of transitions between sounds | Modest inventory; predictable sound sequence | Limited contextual variation and audible joins |
| Large unit selection | Searches many recorded examples for compatible pieces | Preserves detail from real recordings | Storage, coverage and join quality |
| Statistical parametric synthesis | Predicts pitch, duration and spectral shape; reconstructs audio | Compact voice representation; explicit controls | Buzziness or overly smooth sound |
| Small neural acoustic model plus vocoder | Predicts a time–frequency representation, then generates audio | Flexible division of pronunciation, timing and timbre | Training quality and deployment efficiency |
| Generative speech models with audio tokens | Predicts sequences of encoded audio | Flexible voices and expression | Whether their capabilities justify the resources for this task |

Useful primary references and implementations: [eSpeak NG](https://github.com/espeak-ng/espeak-ng), [Flite](https://github.com/festvox/flite), [HTS](https://hts.sp.nitech.ac.jp/), [FastSpeech 2](https://arxiv.org/abs/2006.04558), and [VITS](https://github.com/jaywalnut310/vits).

The distinction between **training end to end** and **unconstrained generation at runtime** matters. A neural system can still have explicit phonemes and durations. Conversely, a small system can pronounce the wrong word very consistently.

### A particularly relevant middle path: signal processing plus a small network

LPCNet combines linear prediction—using recent waveform samples to predict the next—with a neural network modelling what remains. Its original work reports synthesis below 3 GFLOPS; the 2022 follow-up reports a further 2.5-fold speed improvement and operation on phones. These are vocoder results, not a complete text-reading application. [Original LPCNet research](https://research.google/pubs/lpcnet-improving-neural-speech-synthesis-through-linear-prediction/), [2022 efficiency paper](https://arxiv.org/abs/2202.11169).

A separate IBM paper demonstrates a full modular TTS system with prosody prediction, acoustic prediction and LPCNet, reporting three times real-time synthesis on a CPU. This provides precedent for combining these components. [Kons et al., 2019](https://arxiv.org/abs/1905.00590).

**Research implication:** an efficient vocoder is a serious candidate, but it must be tested with features predicted from text. Reconstructing a recording from its measured acoustic features is an easier task and can overstate final TTS quality.

## 3. What “reliability over naturalness” should mean

Separate at least five dimensions:

1. **Text fidelity:** no omitted, repeated, invented or truncated content.
2. **Pronunciation:** numbers, names, abbreviations and context-dependent words are spoken correctly.
3. **Intelligibility:** listeners can identify words at their preferred rate.
4. **Continuity:** no tones, clipping, unexplained pauses or playback starvation.
5. **Listening comfort:** a full article remains tolerable and easy to follow.

Expressive acting, voice cloning and multilingual coverage can be deferred. Phrase boundaries, stress and sufficient consonant detail cannot simply be discarded: include them in listening tests rather than treating all prosody as decoration.

FastSpeech specifically addressed word skipping/repetition through explicit duration prediction and expansion of the phoneme sequence before parallel acoustic generation. This is a useful structural bias, not a guarantee of error-free output. FastSpeech 2 adds duration, pitch and energy supervision using recorded speech. [FastSpeech](https://arxiv.org/abs/1905.09263), [FastSpeech 2](https://arxiv.org/abs/2006.04558).

An autoregressive waveform generator such as WaveRNN or LPCNet is not the same thing as a text-to-audio model losing its place in a sentence. Evaluate each stage's actual failure modes instead of banning all recurrence.

## 4. The text frontend deserves its own research programme

Proposed pipeline:

**Article text → spoken words → phonemes and stress → durations/acoustics → waveform → playback**

Examples of decisions that happen before voice generation:

| Input | Decision to make |
| --- | --- |
| `£4.99` | Currency and decimal expansion |
| `Dr. Smith` / `Elm Dr.` | Doctor versus Drive |
| `I read it yesterday` / `I read daily` | Past versus present pronunciation |
| `03/04/2026` | Locale-dependent date interpretation |
| `US`, `us`, `SQL`, a new surname | Acronym, ordinary word or pronunciation lookup |

Apple's historical pipeline explicitly separates these operations from sound generation. [Frontend description](https://machinelearning.apple.com/research/siri-voices).

For an initial prototype, I would use inspectable normalisation rules, a pronunciation dictionary, a fallback grapheme-to-phoneme model, and a small set of contextual exceptions. Keep raw text, normalised words, phonemes and source-text offsets available in the research harness. This makes it possible to identify whether a wrong output came from language processing or sound synthesis.

Word timestamps still require careful mapping through number expansion, phonemes, pauses and any audio speed changes. A duration predictor makes this tractable; it does not make correct application-level timestamps automatic.

## 5. Why the phone may sound worse than the demo

Possible causes include different checkpoints or voice embeddings, different phonemisation, conversion mistakes, reduced precision, input-length handling, sentence splitting, audio trimming, resampling and playback-rate processing. These are hypotheses to isolate, not explanations to assume.

There is unusually useful local evidence. Historical commits `a9ccf44` and `4e031b7`, and `docs/kokoro-prototype.md` at commit `8db283c`, record:

- Sustained tones replacing speech in the raw on-device Kokoro output as input length increased.
- Similar artefacts with FP16 and FP32 in that experiment, weakening a simple “quantisation caused it” explanation.
- Trimming that removed initial consonants such as /s/ and /f/.
- Differences between the requested synthesis speed and measured audio duration.
- Measurements on an iPhone 17 Pro, with the older phone still unmeasured.

These are historical observations, not independently reproduced results from this review. The notes contain successive, partly conflicting segment-limit recommendations; none should become a new specification without replication. They do not establish whether the original model or the port caused the sustained tones.

**First diagnostic experiment:** preserve exactly the same text, checkpoint, voice, phonemes and settings, then compare:

1. Original reference implementation at full precision.
2. Exported model on a desktop runtime.
3. That exported model on the phone, saving raw samples.
4. The same samples through the app's audio processing and playback.

Change precision only after the unquantised export agrees sufficiently with the reference. Compare intermediate outputs where possible; exact waveform equality may be inappropriate for stochastic models. Use fixed seeds where supported and repeated renders otherwise.

## 6. Data and computational cost

Inference cost, training cost and recording/curation effort are different budgets. A small single-speaker model makes a bounded training project plausible; it does not make reliable pronunciation or studio-quality data free.

Public starting points:

- **LJ Speech:** approximately 24 hours from one speaker, with transcripts and normalised text. Useful for reproducible initial experiments. The recordings originate from MP3, so it is not an ideal lossless studio reference. [Dataset creator](https://keithito.com/LJ-Speech-Dataset/).
- **LibriTTS-R:** a sound-quality-restored version of LibriTTS, designed for TTS, listed under CC BY 4.0. Useful for broader training experiments; restored audio should still be inspected. [OpenSLR](https://www.openslr.org/141/).
- **Commissioned recordings:** my preferred eventual route for a distinctive reading voice, after the architecture proves useful. Plan an initial 10–30 hours of usable, carefully transcribed material as an experimental range, not an established minimum. Include conversationally neutral reading, names, numbers and varied sentence structures.

Keep recording sessions and document sections separated between training and evaluation. Clean clips and accurate transcripts matter more than the dataset's publication date alone. Modern articles can improve text coverage without necessarily requiring a new acoustic architecture.

Piper provides an accessible training/export workflow and recommends starting from a checkpoint. Its documentation reports successful training with as little as 8 GB VRAM, while describing larger GPUs used for many existing voices. This supports testing modest hardware; it does not give a dependable training-time or cost estimate for our proposed model. [Piper training documentation](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/TRAINING.md).

Measure one pilot run before estimating GPU-hours for the project. Fine-tuning a voice and reproducing a complete frontend/acoustic/vocoder stack from scratch are very different scopes.

For bundling, record licences for code, weights, dictionaries and training data separately. The current OHF Piper engine is GPL-3.0; the older repository's MIT description must not be carried forward indiscriminately. [Current Piper repository](https://github.com/OHF-Voice/piper1-gpl). This is a dependency fact, not a conclusion that every Piper-derived model has the same licence.

## 7. A focused experimental programme

### A. Establish the benchmark before training

Build a fixed, versioned collection of roughly 300 difficult sentences plus 10 complete articles. These are proposed starting quantities. Include names, amounts, dates, abbreviations, quotations, lists, short fragments and long sentences. Specify acceptable spoken expansions explicitly.

Compare Alex, one available higher-quality Apple voice, and two external baselines:

- **Kokoro:** valuable because of the existing experiment history; reproduce the upstream reference before judging another port. Its model card describes an 82-million-parameter model. [Model card](https://huggingface.co/hexgrad/Kokoro-82M).
- **KittenTTS Nano:** directly tests whether an existing small model is sufficient. The current repository lists Nano at 56 MB and its INT8 variant at 25 MB, while noting reported problems with that INT8 release. Those are advertised model sizes, not measured total app overhead. [Official repository](https://github.com/KittenML/KittenTTS).

Piper can substitute as the trainable baseline if a suitable voice is available. No model should be declared better than Alex from unrelated mean-opinion-score tables.

### B. Compare two development directions

**Primary experiment:** a small duration-based acoustic model, initially with an existing neural vocoder. Establish correct, intelligible speech first. Then reduce acoustic-model width and precision, and compare an efficient WaveRNN/LPCNet path against the initial vocoder. LPCNet needs appropriate acoustic features; it is not automatically a drop-in replacement for a mel-spectrogram vocoder.

**Classical comparison:** use the same speaker data for a compact parametric system, with a conventional vocoder such as WORLD. First assess analysis–resynthesis from real features to estimate the vocoder's quality ceiling; then assess text-predicted features. [WORLD implementation](https://github.com/mmorise/World).

If the classical system is comfortable and more efficient at the listening rates that matter, it deserves further work. If its sound is already unacceptable with real acoustic features, better text modelling is unlikely to rescue that configuration.

A full unit-selection rebuild is a subsequent experiment if recorded timbre becomes compelling and its measured inventory fits the storage budget. Use modern forced alignment, coverage-based recording selection and pruning; the underlying optimisation problem is already documented in the Alex research.

### C. Suggested initial success criteria

These are **proposed targets**, not user-approved requirements or demonstrated performance:

| Dimension | Initial target or measurement |
| --- | --- |
| Language/voice | One English reading voice |
| Incremental installed assets | Aim below 50 MB; stretch below 25 MB, including frontend assets |
| Fidelity | No observed omissions, repetitions or sustained-tone failures in the fixed evaluation set |
| Pronunciation | Human-reviewed error counts against acceptable verbalisation references |
| Warm start | Aim for first audible speech within 300 ms; report cold start separately |
| Sustained speed | Stay ahead of playback at the user's preferred rate on the oldest target phone |
| Listening | Randomised, loudness-matched comparisons with Alex at normal and accelerated rates |
| Runtime cost | Peak process memory, total installed size, energy and thermal behaviour over a long article session |

Define real-time factor explicitly as **synthesis seconds / generated-audio seconds**. Lower is better. For normal-rate audio later played at 3×, sustaining playback requires RTF below approximately 1/3, plus headroom. If speed is applied during synthesis, measure against the resulting audio duration instead of applying that adjustment again.

Use automatic speech recognition to find suspicious outputs, then listen: recognisers can conceal or introduce errors. Include comprehension and comfort tests with intended listeners, especially experienced fast listeners. Zero observed failures is evidence about the tested set, not a proof of universal reliability.

## 8. Recommended starting decision

Start with **reference-versus-phone reproduction and an Alex comparison**, followed by a small modular neural voice experiment. This distinguishes a deployment problem from a model-capacity problem before investing in new recordings or training.

The most useful research question is:

> How small can a purpose-built English reading voice become while preserving pronunciation, complete text delivery and comfortable listening at accelerated rates?

Read first: the Apple accessibility paper for a feasibility target; FastSpeech for structural reliability; LPCNet for the signal-processing/neural combination; and Bellegarda's Alex paper for the classical storage tradeoff. All are linked above.

Remaining uncertainties are concrete: the desired accent and timbre, acceptable total bundle size, minimum physical phone, preferred listening rates, and whether the old model failures reproduce in their original reference implementations.
