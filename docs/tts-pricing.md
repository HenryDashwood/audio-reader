# Hosted text to speech: what it costs and how it would have to be priced

Prices checked **20 August 2026**. Every figure below is list price in USD;
they move often, so re-check before committing to a number in the App Store.

## Where we are now

Articles are read by `AVSpeechSynthesizer` on the phone (`ArticlePlayer`,
`Speaker`). That is free, offline, private, and works while she is on the tube.
Apple's enhanced and premium voices are respectable but they are audibly
synthetic over a 3,000-word essay, and that is exactly where a listener spends
most of her time. A hosted voice is the upgrade — and the only part of the app
with a per-minute-of-use marginal cost, which is why it has to be a paid tier
rather than something switched on for everybody.

`ArticlePlayer`'s doc comment already anticipates this: server-rendered
narration arrives as an ordinary episode with an `audio_url` and never touches
the on-device path.

## The unit that matters

Every provider bills the **input text**, not the audio. Silence, pauses and
playback speed are free; a 2x listener pays the same per article as a 1x
listener, she just gets through more articles.

Working assumptions used throughout:

| Quantity | Value |
| --- | --- |
| Characters per word (incl. space) | 5.8 |
| Narration rate | ~170 wpm ≈ **1,000 characters per minute** |
| One narration hour | **~59,000 characters** |
| Typical blog/Substack post | 1,200 words ≈ 7,000 characters ≈ 7 minutes |
| Long essay (ACX, LRB, magazine feature) | 4,000 words ≈ 23,000 characters ≈ 23 minutes |

Note the second-order effect for our users specifically: VoiceOver listeners
routinely run at 1.5–3x. Cost tracks *text consumed*, so a subscriber who
listens at 2x for an hour costs twice what the "one hour of listening" figure
suggests. Model in articles per day, not hours per day.

## What the providers charge

| Engine | $ / 1M chars | $ / narration hour | $ / 1,200-word article |
| --- | ---: | ---: | ---: |
| Kokoro-82M, self-hosted (Apache-2.0) | ~0.60 (compute only) | 0.04 | 0.004 |
| Gemini 2.5 Flash TTS | ~10 | 0.59 | 0.07 |
| OpenAI `tts-1` (legacy) | 15 | 0.89 | 0.10 |
| OpenAI `gpt-4o-mini-tts` | ~15 equiv. | 0.89 | 0.10 |
| Azure prebuilt neural | 15–16 | 0.92 | 0.11 |
| Amazon Polly Neural | 16 | 0.95 | 0.11 |
| Azure Neural HD | 22 | 1.30 | 0.15 |
| Google Chirp 3: HD | 30 | 1.78 | 0.21 |
| Amazon Polly Generative | 30 | 1.78 | 0.21 |
| Deepgram Aura-2 | 30 | 1.78 | 0.21 |
| OpenAI `tts-1-hd` | 30 | 1.78 | 0.21 |
| ElevenLabs Flash / Turbo v2.5 | 50 | 2.96 | 0.35 |
| Cartesia Sonic 3 (Pro) | ~50 | 2.96 | 0.35 |
| ElevenLabs Multilingual v2 / v3 | 100 | 5.92 | 0.70 |
| Amazon Polly Long-form | 100 | 5.92 | 0.70 |

Details worth knowing:

- **`gpt-4o-mini-tts` is billed in tokens**, $0.60/1M text-input +
  $12/1M audio-output tokens, which works out at roughly $0.015 per minute of
  audio — the ~$15/1M-character figure above is a conversion, not a list price,
  so it drifts with how verbose the text is.
- **Gemini 2.5 Flash TTS** ($0.50/1M in, $10/1M audio-out tokens) is the
  cheapest genuinely modern voice. Quality is good; it is a preview model, so
  treat availability and price as unstable.
- **ElevenLabs** is the quality benchmark and prices like it. Subscription
  credits and the newer pay-as-you-go rates both land around $0.05/1k chars for
  Flash/Turbo and $0.10/1k for v2/v3 — 3–6x the mid-tier field. Their May 2026
  repricing cut API rates by up to 55%, so the gap has already narrowed once.
- **Free tiers** are irrelevant at scale but useful in development: Google gives
  1M characters/month on Chirp 3 HD, Azure 500k/month, Polly's generative free
  tier is 100k/month for the first 12 months.
- **Committed-use discounts** are real: Azure commitment tiers reach ~$7.50/1M,
  and Deepgram's Growth tier drops Aura-2 to $27/1M. Not worth chasing until the
  spend justifies the lock-in.
- **Self-hosting** (Kokoro-82M, Apache-2.0) runs 30–90x faster than real time on
  a mid-range GPU, so one $1/hour instance covers thousands of narration hours a
  day. Marginal cost effectively disappears; you buy an ops burden and a voice
  that is good-but-not-ElevenLabs instead.

## What one subscriber costs

Monthly cost per user, assuming 1,200-word articles and no caching:

| Profile | Articles/mo | Chars/mo | Narration hrs | Gemini Flash | `gpt-4o-mini-tts` | Chirp 3 HD | 11L Flash | 11L v3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Light — 3/week | 13 | 90k | 1.5 | $0.90 | $1.36 | $2.71 | $4.52 | $9.04 |
| Moderate — 1/day | 30 | 209k | 3.5 | $2.09 | $3.13 | $6.26 | $10.44 | $20.88 |
| Committed — 3/day | 90 | 626k | 10.6 | $6.26 | $9.40 | $18.79 | $31.32 | $62.64 |
| Heavy — 6/day | 180 | 1.25M | 21.2 | $12.53 | $18.79 | $37.58 | $62.64 | $125.28 |
| Power — 12/day | 360 | 2.51M | 42.4 | $25.06 | $37.58 | $75.17 | $125.28 | $250.56 |

For an app whose core audience reads *only* by listening, "committed" is the
realistic middle of the distribution, not the tail. That is the uncomfortable
fact underneath everything below.

Delivery costs are noise by comparison: a narration hour at 32 kbps mono is
14 MB, which is $0.0002/month to store on R2 and about a tenth of a cent to
serve from S3. Use R2 (zero egress) and stop thinking about it.

## What the app would have to charge

Apple takes 30%, or 15% under the Small Business Program (under $1M/year, which
this is). Net revenue and the narration hours it buys:

| Price | Net (15%) | Gemini Flash | `gpt-4o-mini-tts` | Chirp 3 HD | 11L Flash | 11L v3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| $4.99 | $4.24 | 7.2h | 4.8h | 2.4h | 1.4h | 0.7h |
| $7.99 | $6.79 | 11.5h | 7.7h | 3.8h | 2.3h | 1.1h |
| $9.99 | $8.49 | 14.4h | 9.6h | 4.8h | 2.9h | 1.4h |
| $14.99 | $12.74 | 21.5h | 14.4h | 7.2h | 4.3h | 2.2h |

At 30% those numbers drop by a sixth. Read the ElevenLabs columns carefully:
a $9.99 subscription buys **84 minutes** of v3 narration. Nobody's month of
reading fits in that.

Blended across a plausible mix (35% light, 35% moderate, 20% committed, 8%
heavy, 2% power — a mean of 6.4 narration hours per subscriber per month):

| Engine | Cost/subscriber | With 50% cache hits | With 80% |
| --- | ---: | ---: | ---: |
| Gemini 2.5 Flash TTS | $3.80 | $1.90 | $0.76 |
| `gpt-4o-mini-tts` | $5.71 | $2.85 | $1.14 |
| Chirp 3 HD | $11.41 | $5.71 | $2.28 |
| ElevenLabs Flash | $19.02 | $9.51 | $3.80 |
| ElevenLabs v3 | $38.04 | $19.02 | $7.61 |

So: a mid-tier engine at $9.99/month clears its costs with room for the rest of
the hosting bill. A premium ElevenLabs voice does not, at any price a reader
app can plausibly charge, unless caching carries most of the load.

## The levers that change the arithmetic

1. **Cache by article, not by user.** Feeds are shared. One rendering of a new
   Astral Codex Ten post serves every subscriber who opens it, and the cost per
   listen falls as `1/listeners`. This is by far the biggest lever, and it is
   the structural advantage a *feed reader* has over Speechify or ElevenReader,
   which mostly narrate documents the user supplied. It also means **voice
   choice is expensive**: every voice option multiplies the cache and divides the
   hit rate. Ship one or two premium voices, not two hundred.
2. **Synthesise lazily.** Render the first two or three minutes on open, then
   continue in the background while she listens. Article abandonment is high —
   half the spend on a naive render-the-whole-thing design is on audio nobody
   hears. Pre-render at ingest only for articles whose feed has enough
   subscribers to pay for the latency win.
3. **Trim before synthesising.** `backend/src/audioreader/text.py` already strips
   chrome; every subscribe-CTA, footnote block and cookie banner that survives
   into the text is billed at full rate.
4. **Fall back rather than cut off.** When a cap is reached, drop to the
   on-device voice with a spoken notice. For a blind user a hard paywall
   mid-article is a broken app, not a nudge to upgrade.
5. **Self-host the floor.** Kokoro on one small GPU gives a voice clearly better
   than Apple's at near-zero marginal cost, and it caps the downside if a whale
   subscribes. Worth prototyping before signing up for per-character billing.

## Recommendation

- **Free tier stays as it is**: on-device Apple voices, unlimited, offline.
- **Premium at $9.99 / £7.99 a month, or $79.99 / £69.99 a year**, comparable to
  ElevenReader Ultra at $11/month and undercutting Speechify Premium at
  $139/year. Annual billing is worth pushing: it cuts churn and Apple's cut
  falls to 15% after year one regardless of the Small Business Program.
- **Use `gpt-4o-mini-tts` or Gemini 2.5 Flash TTS as the workhorse voice.** Both
  are around $0.60–0.90 per narration hour, both are a large step up from
  `AVSpeechSynthesizer`, and both leave a margin at $9.99. Benchmark them on
  actual feed content — long essays with names, quotes and em-dashes — before
  choosing.
- **Include ~15 narration hours a month** (about 90 typical articles, or three a
  day). Worst case, if every subscriber maxed it: $8.87/month on Gemini Flash,
  $13.31 on `gpt-4o-mini-tts`. Blended, it costs a fraction of that. Past the
  cap, fall back to the on-device voice and offer a top-up.
- **Do not use the word "unlimited".** One power user at 12 articles a day on
  ElevenLabs v3 is $250 a month.
- **Treat ElevenLabs as a garnish, not the engine**: a named premium voice on a
  higher tier ($19.99+, capped at ~5 hours), or a per-article "read this one in
  the good voice" action. Its Flash model at $0.35 an article is affordable for
  the pieces she actually cares about; its v3 model at $0.70 an article is not
  affordable for a feed.
- **Offer bring-your-own-API-key** for the handful of power users who will ask.
  Zero marginal cost, and it defuses the exact segment that breaks the unit
  economics.

The uncomfortable caveat: all of this assumes usage looks like a general-purpose
reader app. If the audience is predominantly blind users for whom this is the
primary reading channel, shift every profile up a row — "committed" becomes the
median, "heavy" becomes common, and the honest options narrow to a self-hosted
voice, a lower cap, or a higher price. Instrument narration hours per user from
the first day the feature ships; the distribution, not this document, should set
the final cap.

## Sources

- [ElevenLabs API pricing](https://elevenlabs.io/pricing/api) and
  [API/Agents price reduction + PAYG](https://elevenlabs.io/blog/weve-lowered-api-agents-pricing-and-introduced-pay-as-you-go)
- [ElevenReader pricing](https://elevenreader.io/pricing)
- [OpenAI API pricing](https://platform.openai.com/docs/pricing) —
  [TTS breakdown](https://texttolab.com/blog/openai-tts-pricing)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Google Cloud Text-to-Speech pricing](https://cloud.google.com/text-to-speech/pricing)
- [Amazon Polly pricing](https://aws.amazon.com/polly/pricing/)
- [Azure Neural HD price change](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/azure-speech-%e2%80%93-neural-hd-text-to-speech-recent-voice-updates/4505380)
- [Deepgram pricing](https://texttolab.com/blog/deepgram-pricing)
- [Cartesia pricing](https://www.cloudtalk.io/blog/cartesia-pricing/)
- [Self-hosted Kokoro deployment costs](https://www.spheron.network/blog/deploy-open-source-tts-gpu-cloud-2026/)
- [Speechify pricing](https://texttolab.com/blog/speechify-pricing)
