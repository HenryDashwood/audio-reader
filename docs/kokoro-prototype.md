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

## What the app adds to the model, and what it does not

The upstream demo renders one utterance and plays it, and sounds fine. This app
splits an article into segments, so it needs two things the demo does not — and
it should need nothing else.

**1. A segment limit of 90 characters.** Everything that ever sounded wrong
came from giving the model too much text at once: a held tone, and a buzz that
*replaces* words rather than covering them. See below for the measurements. At
90 characters neither appears, on any segment of the article tested.

**2. Trimming the silence between segments.** Every render arrives with about
0.29s of digital silence before the first word and 0.68s after the last. In the
demo that is unnoticeable. Concatenated segment to segment it is nearly a
second of dead air at every join. `KokoroAudio.trimmedSilence()` cuts it, on an
absolute level threshold of about -54 dBFS, keeping 20ms either side.

**And nothing else.** An earlier version of this file classified every frame as
speech or not-speech — band-pass filters, energy gates, run-length rules, a
separate sibilant band — to strip artefacts out of the audio. It was a mistake,
and every version of it clipped real sounds: a word-initial /s/ has almost no
energy where vowels do, so "cinematic" lost its first syllable, and the fade
applied at the cut point ate the start of "Everyone". Filtering could not have
worked in any case, because the buzz *consumes* the word rather than sitting on
top of it — silencing it perfectly still leaves the word missing.

The lesson is worth keeping: when the model produces something wrong, fix what
is handed to the model. Do not build a classifier to clean up after it. The
only safe thing to cut is silence, because silence is unambiguous.

For diagnosis, `HEARFUL_KOKORO_RAW=1` renders untrimmed, and
`HEARFUL_KOKORO_SPEED` sets the rate — without those there is no way to see
what the model actually produced.

## Why 90 characters

Give the model more text than that in one call and it stops speaking and emits
a **sustained tone** instead, or drops a word and emits a **buzz** in its
place. Measured on device, longest run of tone against input length, on two
unrelated paragraphs:

| characters per call | longest tone |
| ---: | ---: |
| 110 | 0.2s |
| 130 | 0.8s |
| 150 | 2.6s |
| 180 | 3.1s |
| 240 | 6.9s |

Synthetic prose survives 110; real article text does not. At 110 the model
dropped whole words on a live article — 310ms of buzz where "From" should have
been, 890ms elsewhere — which is what the artefact does: it consumes speech
rather than adding noise. At 90 it does not happen at all.

The artefacts are worth recognising if they ever return. The tone is a loud
decaying low sinusoid. The buzz is quiet, periodic, and puts its energy only at
DC, 4.8kHz and 9.6kHz, with *nothing* between 300Hz and 4kHz where speech
formants live — that 9.6kHz component is what a listener hears as a
high-pitched squeak.

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
