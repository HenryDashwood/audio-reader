# Reading articles with Kokoro

A working prototype of on-device neural narration, sitting behind the same
`SpeechSynthesizing` protocol as Apple's voice. `docs/tts-pricing.md` has the
reasoning — cost, device floor, and why Kokoro rather than something bigger.

**It does not build out of the box, on purpose.** The MLX package is not in
`Hearful.xcodeproj` and the weights are not in the repository, so a fresh
checkout compiles and runs exactly as it did before, on Apple's voices. Both
Kokoro files that need MLX are behind `#if canImport(KokoroSwift)`, and the
Settings section is behind `KokoroEngines.isAvailable`. Adding the package is
what switches it on.

## It runs, and here are the numbers

Measured 20 August 2026 on a **physical iPhone 17 Pro**, Release build, fp16
weights, reading one 261-character paragraph — the size `ArticleScript`
actually produces:

| | audio | render | real-time factor |
| --- | ---: | ---: | ---: |
| cold (includes loading the weights) | 14.70s | 2.32s | 6.3x |
| warm, speed 1.0 | 14.70s | 1.45s | **10.1x** |
| warm, speed 2.0 | 8.53s | 1.03s | 8.3x |
| warm, speed 3.0 | 7.47s | 0.84s | 8.9x |

Three things worth taking from that:

- **There is comfortable headroom on modern hardware.** At 3x playback the
  renderer still runs about 3x faster than the audio is consumed. A whole
  chunk takes 1.45s to render, and since chunks are rendered a sentence at a
  time, time-to-first-word is nearer 0.4s.
- **Kokoro's `speed` parameter under-delivers, badly.** `speed: 2.0` produced
  8.53s of audio where 1x produced 14.70s — a real speed-up of **1.7x**, not
  2x. `speed: 3.0` gave 1.97x, not 3x. So `KokoroSynthesizer.speed(forUtteranceRate:)`
  is honest about what it asks for, but the voice does not deliver it: her "3x"
  would land near 2x. Anyone continuing this should calibrate the mapping
  against measured output rather than trusting the parameter.
- **The character-rate estimate was right.** 261 characters became 14.70s, or
  17.8 characters per second, against the 16.4 assumed in
  `KokoroSynthesizer.charactersPerSecond`. The progress fraction starts out
  roughly right and converges as the chunk renders.

Still unmeasured, and still the number that decides this: an **iPhone 11**,
which is several generations slower than the phone above. Published figures put
an iPhone 13 Pro at 3.3x, so an iPhone 11 could plausibly land near real time —
fine at 1x, marginal at 2x. Nothing here settles that.

Also unverified: the audio was generated with **fp16** weights (see below) and
has not been listened to critically. Correct duration and clean completion are
not the same as sounding right.

## The 110-character limit, and why it is not negotiable

Give this model more than about 120 characters in one call and it stops
speaking and emits a **sustained tone** instead — one held note, seconds long,
in the middle of the sentence. It was immediately audible as "every other few
words is a high-pitched note".

Measured on device, longest run of held tone against input length, on two
unrelated paragraphs:

| characters per call | longest tone |
| ---: | ---: |
| 110 | 0.2s |
| 120 | 0.8s |
| 130 | 0.8s |
| 140 | 1.9s |
| 150 | 2.6s |
| 180 | 3.1s |
| 240 | 6.9s |
| 261 | 6.7s |

What it is not: not the playback path (the tone is in the raw samples, dumped
straight from the engine before anything of ours touches them); not the fp16
weights (fp32 produces the identical artefact at the identical position); not
the accent (British and American voices both); not punctuation or any single
word (two unrelated paragraphs degrade the same way, and the same text is clean
when shortened). It is also far below the 510-token ceiling the library
documents.

The note **replaces** speech rather than adding to it, which is why the fix
makes renders longer: the same paragraph went from 14.70s (of which 8.96s was
tone) to 16.82s of actual words.

`KokoroSynthesizer.segmentCharacterLimit` is therefore **110** — a correctness
limit, not a latency tuning knob. Segmenting a paragraph at that size, then
joining the pieces the way the player does, leaves a longest tone run of 0.26s,
which is ordinary phoneme transition:

| | total tone | longest run |
| --- | ---: | ---: |
| one 261-character call | 8.96s | 6.74s |
| same text, segmented at 110 | 1.19s | 0.26s |

If the model or the port is ever updated, re-run the sweep before raising it.

## Sibilants are speech too

A voiced-only test drops the first sound of words beginning /s/, /f/ or /ʃ/,
which is audible as a swallowed syllable — reported at 1.5x, where there is
less of the word left to recognise. Measured on the /s/ opening "cinematic":

| | 300Hz–4kHz | 5.5–8.5kHz |
| --- | ---: | ---: |
| /s/ | 0.4% | **50%** |
| the vowel after it | 75% | 0.1% |
| the buzz | 0.0% | **0.0%** |

So a frame counts as speech if it is voiced **or** sibilant, and 5.5–8.5kHz is
the band to ask: it sits between the buzz's two lines at 4.8kHz and 9.6kHz,
which is why the buzz still reads as silence there.

The sibilant test is a **share of the frame's own energy**, not a level. That
band is nearly empty through most of a segment, so a median-relative gate there
sits on the noise floor and lets the buzz back in — measured, at every filter
width from Q=2.5 to Q=6. As a share it is unambiguous: an /s/ is about half its
frame, the buzz is none of it, and anything from 0.1 to 0.3 behaves identically.

## The buzz eats words, so it has to be prevented, not filtered

The decisive fact, found late: **the buzz replaces speech rather than covering
it**. On a live article at a 110-character limit, the model rendered 310ms of
buzz where the word "From" should have been, and 890ms elsewhere. Silencing it
does not recover the word — it just turns a squeak into a skipped word, which
is exactly what happened when the silencing gate first worked.

So the fix is the segment limit, not the filter. At **90 characters** the buzz
does not appear at all on any segment of that article; at 110 it appeared on
two of the first six, both of them among the longest segments. The earlier
sweep put the cliff near 120 because it used synthetic prose — real article
text, with Greek, curly quotes and long clauses, falls over sooner.

The audio filtering below stays as a safety net, with one threshold changed:
nothing shorter than 150ms is silenced. A plosive closure is audible, lasts
60–110ms and carries little speech-band energy, so a shorter threshold eats
consonants — measured in every segment of the article, including a
34-character one. The buzz ran 310ms and 890ms. Nothing real sits in between.

## Two artefacts, and why loudness cannot find either

Real article text — Greek, curly quotes, en-dashes — produces a second
artefact that synthetic prose never did, and it is the one that made the app
unlistenable. Both are now trimmed by `KokoroAudio.trimmedToSpeech()`.

| | when | length | character |
| --- | --- | ---: | --- |
| **ring** | after the last word | up to 0.75s | loud decaying low sinusoid |
| **buzz** | before the first word | up to 0.9s | quiet, periodic, energy only at DC, 4.8kHz and 9.6kHz |

The buzz is the high-pitched note a listener hears between sentences: quiet —
a fifth of the speech level — but that 9.6kHz component is piercing. It does
not appear on every segment; on the article tested it was on two of the first
six, one of them right after the opening sentence, which is exactly where it
was reported.

**Loudness cannot separate either from speech**: the ring is *louder* than the
speech around it, the buzz much quieter. **High-frequency energy cannot
either** — that was the first attempt, and over half the buzz's energy is above
4kHz, so it sailed through.

What does separate them is the **speech band**. Speech always has energy
between 300Hz and 4kHz, where the formants are. Both artefacts have *none*:
measured at 0.0% of their energy. So the trim band-passes at 1.1kHz (two RBJ
biquads — one-pole cascades leak too much 9.6kHz to work), gates at 15% of the
median frame energy, and takes the first and last **run of three consecutive
frames** over that gate.

That last part matters more than it looks. The buzz begins with a step, and a
step is broadband: a single frame of it is indistinguishable from a consonant.
Requiring speech to persist for ~30ms rejects the onset while leaving every
real segment identical — measured, two frames is already enough, and two,
three and four all give the same answer on every segment tested.

Measured on the article, before and after:

| segment | before | after | removed |
| --- | ---: | ---: | ---: |
| 1 (buzz) | 6.50s | 6.21s | 0.29s |
| 4 (buzz) | 7.09s | 6.22s | 0.87s |
| 0, 2, 3, 5 (clean) | — | unchanged | 0.00s |

`HEARFUL_KOKORO_RAW=1` renders untrimmed, which is how the raw artefacts above
were measured; without it there is no way to see what the model actually
produced.

## The ring at the end of every segment

Shortening the segments removed the long held notes, but left a shorter one
every few words — and that one is not a length effect. **Every render comes
back with a decaying pure tone after the last word**, roughly a quarter of a
second of it, plus about 0.25s of silence before the first word and up to 0.6s
of silence after. Played one segment after another, that is a note and a pause
at every join.

Measured on four segments of one paragraph:

| segment | rendered | silence before | ring + silence after |
| --- | ---: | ---: | ---: |
| 0 | 5.03s | 0.25s | 0.72s |
| 1 | 3.02s | 0.23s | 0.70s |
| 2 | 6.72s | 0.27s | 0.76s |
| 3 | 2.05s | 0.26s | 0.57s |

`KokoroAudio.trimmedToSpeech()` cuts both ends, and `MLXKokoroEngine` applies
it to everything it renders. The test cannot be loudness — **the ring is louder
than the speech around it** — so it is high-frequency energy instead: speech
always carries energy above 1kHz, and a low sinusoid carries almost none. A
two-pole high-pass at 1kHz, a gate at 15% of the median frame energy, a 40ms
guard either side so no quiet consonant is clipped, and a 10ms fade so the
joins do not click. One pole is not enough: it leaves a 200Hz ring only ~14dB
down, still above the gate.

On the same paragraph that produces 16.82s of audio raw, this returns 13.40s —
all of it speech, with no silent bands and no rings between segments.

## What it takes to get there

Four things stand between a fresh checkout and that table, and none of them are
obvious.

### 1. MLX does not build for the iOS simulator

Linking fails on `_MTLIOErrorDomain`, which the simulator SDK does not provide.
Everything Kokoro has to be built and run on a physical device — which also
means **adding this package to the project breaks `make ios-build` and
`make ios-test`**, since both target the simulator. That is the strongest
argument for keeping the engine behind `#if canImport(KokoroSwift)` and out of
the default build, exactly as it is now.

### 2. MLX must be told the GPU limits, or iOS kills the app

This cost the most time by far, so it is worth stating plainly. Without

```swift
GPU.set(cacheLimit: 50 * 1024 * 1024)
GPU.set(memoryLimit: 900 * 1024 * 1024)
```

the app is killed with **signal 9** the moment it loads the weights. There is
no crash report, no exception, and no memory warning — `os_proc_available_memory()`
reported **3.2GB still free** immediately before each kill. It survives a
five-second delay past launch, happens identically in Debug and Release, and
happens with both fp32 and fp16 weights, so none of the obvious explanations
fit. MLX's defaults are simply sized for a Mac. `MLXKokoroEngine` now sets both
before constructing the engine; upstream's own sample app does the same, which
is where the values come from.

### 3. Both packages' resource bundles cannot be codesigned by Xcode 27

`KokoroSwift` and `MisakiSwift` both declare `.copy("../../Resources/")`, which
produces a bundle with an iOS-style root `Info.plist` *and* a macOS-style
`Resources/` subdirectory. Codesign rejects it outright:

```
KokoroSwift_KokoroSwift.bundle: bundle format unrecognized, invalid, or unsuitable
```

Confirmed directly: copy the built bundle, move `Resources/*` to the root, and
the identical `codesign` call succeeds. It is **not** a one-line fix, because
both packages read their resources with
`Bundle.module.url(forResource:withExtension:subdirectory: "Resources")` — one
call site in `KokoroSwift`, four in `MisakiSwift`. Fixing it means flattening
the layout *and* dropping the `subdirectory:` argument everywhere, which means
forking both packages or getting the change upstream.

The measurements above were taken with locally patched checkouts in
`~/kokoro-packages`, with the project pointed at them by relative path. That
edit is deliberately **not** committed: it hard-codes a path on one machine and
it breaks the simulator build for everyone.

### 4. Smaller things that still stop the build

- The tagged `Package.swift` omits `MLXFast`, which its own sources import;
  resolution picks an mlx-swift where that is a separate product, and the
  build fails on `Unable to resolve module dependency: 'MLXFast'`.
- `KokoroSwift` is declared `type: .dynamic`. A hand-written project reference
  links it without embedding it, and the app dies at launch on
  `Library not loaded: @rpath/KokoroSwift.framework/KokoroSwift`. Building it
  statically avoids needing an embed phase at all.
- The app target must link `MLXUtilsLibrary` itself, for `NpyzReader`. MLX's
  own `loadArrays(url:)` reads safetensors only, so the `.npz` of voices needs
  it.
- Xcode 27 ships without the Metal toolchain MLX needs:
  `xcodebuild -downloadComponent MetalToolchain` (839MB).

### The model files

- `kokoro-v1_0.safetensors`, 327,115,152 bytes, sha256 `4e9ecdf0…`, from the
  [KokoroTestApp](https://github.com/mlalma/KokoroTestApp) LFS store — which is
  also where `voices.npz` (28 English voices) comes from, already in the format
  MLX wants, so no PyTorch conversion is needed.
- An **fp16** copy, halved to 164MB by casting every F32 tensor in the
  safetensors file, renders identically to fp32 — same durations, same output,
  including reproducing the tone artefact at exactly the same position before
  the segment limit was fixed. Half the download for no measured difference.
- All thirteen voices in `KokoroVoice.catalogue` were confirmed present on the
  device, loaded in 0.39s.

## Setting it up

1. **Add the package.** In Xcode, *File → Add Package Dependencies…* and enter
   `https://github.com/mlalma/kokoro-ios` (MIT). It pulls MLX Swift, MisakiSwift
   and MLXUtilsLibrary with it. Add the `KokoroSwift` product to the `Hearful`
   target. Until the codesigning problem above is solved, point it at forks with
   the resource layout fixed rather than at upstream.

2. **Get the weights.** `kokoro-v1_0.safetensors` (~330MB) from
   [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M).

3. **Get the voices.** The upstream voice packs are PyTorch `.pt` files; MLX
   wants an `.npz` of the style tensors. Either take the prepared `voices.npz`
   from the [KokoroTestApp](https://github.com/mlalma/KokoroTestApp) project, or
   build one:

   ```python
   import numpy as np, torch, glob, os
   np.savez(
       "voices.npz",
       **{os.path.basename(p).replace(".pt", ".npy"): torch.load(p).numpy()
          for p in glob.glob("voices/*.pt")},
   )
   ```

4. **Put both files where the app looks.** Drag them into the Xcode project
   (target membership: `Hearful`) so they ride in the bundle.
   `KokoroModelStore` checks `Application Support/Kokoro` first, so a
   downloaded copy can shadow the bundled one later without any code changing
   — which is how this would ship, via On-Demand Resources rather than a
   400MB app.

5. **Run it.** Settings gains a *Natural voice* section. Pick a voice, hear the
   preview, open an article.

Everything renders on the phone. Nothing is sent anywhere, and it works in
flight mode once the files are on the device.

## How it fits together

```
ArticlePlayer ── SpeechSynthesizing ─┬─ SystemSpeechSynthesizer  (AVSpeechSynthesizer)
                                     └─ KokoroSynthesizer
                                          ├─ KokoroRendering  ── MLXKokoroEngine (actor, MLX)
                                          └─ KokoroAudioOutputting ── KokoroAudioEngineOutput
```

`ArticlePlayer` is untouched. It hands over an `AVSpeechUtterance` and waits for
the same two callbacks, and because the delegate asks for a *fraction* through
the chunk rather than word ranges, the playhead is enough — no alignment, no
forced timestamps. (Kokoro does return per-token timings; `MLXKokoroEngine`
drops them. They are what a word-highlighting view would be built on.)

Three things are worth knowing about the design:

- **A chunk is rendered in sentence-sized pieces.** Rendering a whole
  320-character chunk before saying anything is several seconds of silence
  after she presses play. The first sentence is spoken while the rest are still
  being made, and sequential buffers on one player node play back to back, so
  it still sounds like a paragraph.
- **Progress is estimated from the pace of what has already rendered**, not
  from words per minute — this voice, at this speed, on this text. Once the
  chunk is fully rendered the estimate becomes exact.
- **The speaking rate goes through Kokoro's own `speed`**, which scales
  predicted phoneme durations rather than time-stretching the waveform. 2x
  sounds like someone reading quickly. `KokoroSynthesizer.speed(forUtteranceRate:)`
  inverts `ArticlePlayer.utteranceRate(for:)` so the reader's existing knob
  still drives it; note that the reader's rate curve saturates, so the 3x
  setting arrives as about 2.8x.

## What is not done yet

- **The iPhone 11 is still unmeasured**, and it is the phone that decides
  whether this ships. Everything above was an iPhone 17 Pro.
- **No automatic fallback.** If the device is too slow, or the model is
  missing, she gets silence-then-skip rather than a graceful drop back to the
  Apple voice. `KokoroSynthesizer` already releases the chunk when a render
  fails, so the article keeps moving; deciding *before* playing is the missing
  piece.
- **The voice is read once at launch.** `ArticlePlayer.shared` builds its
  synthesiser in `init`, so changing the voice in Settings takes effect on the
  next article rather than the current one.
- **Text normalisation is untouched**, and it is where the real work is.
  `AVSpeechSynthesizer` reads "£4.99", "Dr.", "2019–24" and "https://…"
  sensibly; Kokoro takes phonemes and will mispronounce whatever Misaki's
  lexicon misses. A regression corpus of real feed text is the next
  substantial job.
- **Nothing measures battery or thermals** over a long listen, which is the
  argument for moving to Core ML on the ANE later.
- **Spoken confirmations stay on Apple's voice.** They are a sentence long,
  where waiting to render is worse than the voice is better.

## Where the code is

| File | What it does |
| --- | --- |
| `Speech/Kokoro/KokoroVoice.swift` | The voice shortlist and the `kokoro:` identifier scheme |
| `Speech/Kokoro/KokoroModelStore.swift` | Where the weights and voices are looked for |
| `Speech/Kokoro/KokoroRendering.swift` | What the synthesiser needs from an engine |
| `Speech/Kokoro/MLXKokoroEngine.swift` | Kokoro on MLX, an actor, lazily loaded |
| `Speech/Kokoro/KokoroEngines.swift` | The one engine per process |
| `Speech/Kokoro/KokoroAudioOutput.swift` | AVAudioEngine playback, and the seam tests use |
| `Speech/Kokoro/KokoroSynthesizer.swift` | The `SpeechSynthesizing` implementation |
| `HearfulTests/KokoroSynthesizerTests.swift` | Splitting, progress, finishing, stopping, rate mapping |
