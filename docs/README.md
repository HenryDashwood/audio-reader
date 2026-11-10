# Documentation

Use these guides for current behaviour and operating procedures. Workflow files,
build helpers and application code own executable settings; guides link to them
rather than maintaining separate version pins. Git history retains superseded
implementation notes.

## Development and releases

- [Repository setup and iOS development](../README.md)
- [Android development and feature guide](../android/README.md)
- [Android device acceptance](android-acceptance.md)
- [Manual iOS test plan](test-plan.md)
- [Backend staging, promotion and rollback](backend-releases.md)
- [Mobile releases](mobile-releases.md), with the
  [release skill](../.agents/skills/magpie-release/SKILL.md) as the agent entry point
- Store listing sources: [App Store](../app-store/README.md) and
  [Google Play](../play-store/README.md)

## Features and contracts

- [Sign-in and linked accounts](sign-in.md)
- [Saved articles and offline availability](saved-articles.md)
- [Browser extraction and capture reliability](capture-reliability.md)
- [Article PDF export](article-pdf-export.md)
- [PDF imports](pdf-imports.md), [Magpie Plus](magpie-plus.md) and
  [account feature flags](feature-flags.md)
- [Podcast downloads](podcast-downloads.md)
- [Playback progress synchronisation](progress-sync.md)
- [Combining publication sources](feed-sources.md)
- [OPML subscription import and export](opml.md)
- [Voice pipeline, clarification and verification](voice/pipeline.md)
- [Siri, Shortcuts and system controls](voice/siri-shortcuts.md)
- [Newsletter email worker](../cloudflare/email-worker/README.md)
- [Shared natural-voice phonemizer](../native/g2p/README.md)

## Evaluation and research

- [Running voice-command evaluations](../backend/evals/README.md)
- [GPT-6 Luna comparison, 22 September 2026](gpt-6-luna-evaluation-2026-09-22.md)
- [Jev evaluation, 20 September 2026](jev-evaluation-2026-09-20.md)
- [Future on-device voice research, 15 September 2026](on-device-tts-research.md)

These dated evaluations and research describe their stated experiments, not
current prices, production accuracy or release acceptance. Public version notes
are in the [changelog](CHANGELOG.md).
