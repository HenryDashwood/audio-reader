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

## Setting it up

1. **Add the package.** In Xcode, *File → Add Package Dependencies…* and enter
   `https://github.com/mlalma/kokoro-ios` (MIT). It pulls MLX Swift, MisakiSwift
   and MLXUtilsLibrary with it. Add the `KokoroSwift` product to the `Hearful`
   target. This is the one step that has to be done in Xcode rather than here:
   it edits `project.pbxproj`, and the repository's own rule is not to hand-edit
   that file.

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

- **Nothing is measured.** The published figure is 3.3x real time on an
  iPhone 13 Pro; this has been run on nothing. The first thing to do is time a
  render on an **iPhone 11** — the oldest phone iOS 26 supports, and the one
  that decides whether this ships — at 1x, 2x and 3x. If it cannot stay ahead
  of the playhead, that is the answer.
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
