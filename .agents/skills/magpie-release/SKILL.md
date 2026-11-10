---
name: magpie-release
description: Prepare, publish, and monitor Magpie iOS releases through TestFlight and App Review, and Android releases through Google Play, in the audio-reader repository. Use for mobile release requests, release preparation, distribution retries, or release status checks; backend promotion and phone installs use their own workflows.
---

# Magpie Release

Use the repository's canonical [mobile release guide](../../../docs/mobile-releases.md)
instead of reconstructing the procedure from workflow comments or old release
notes. Work from the repository root and read [AGENTS.md](../../../AGENTS.md).

Establish the requested platform and destination from the user's request and
session context: preparation, internal testing, external testing, or public
store submission. Honor existing authorization without asking again; invoking
this skill to inspect status or edit documentation does not authorize publishing.

Read the guide's preparation and monitoring sections and only the platform
section needed for the request. Inspect the current workflow files it links
before acting: they define the executable inputs and gates. Follow the requested
release through its terminal stage and report the exact commit, version,
build/code, workflow result, and any remaining store review. Do not treat a
successful upload as proof of public availability.

Keep release procedure changes in `docs/mobile-releases.md`; this skill is the
discovery and invocation entry point. Backend production promotion remains a
separate workflow in [docs/backend-releases.md](../../../docs/backend-releases.md).
