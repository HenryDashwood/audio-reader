# Android client

Follow the repository root guidance. This directory contains the native Magpie
Android client; it must not change released Swift contracts implicitly.

- Use Kotlin, Compose and Media3. Playback belongs to the service, not an activity
  or composable. UI and system controls must operate the same player.
- Keep the sample library explicitly labelled and isolated from real accounts.
  Never report locally rendered article seconds through the existing backend
  position API. See README.md for the prototype's text-bookmark convention.
- Preserve TalkBack labels, heading semantics, 48dp targets, scrollability,
  system text scaling, and dark mode. Do not put essential actions behind swipes.
- Use capability detection for speech engines and models. Never silently switch
  to network speech recognition or narration.
- Run `make android-check` for changes here. Run `make android-test` on a running
  emulator for UI/service changes. Report emulator and physical-device coverage
  separately; missing voice models are not proof that narration works.
- Keep generated build files, local SDK paths, signing keys, and Android Studio
  workspace settings out of Git. Do not publish, register an app, or change
  signing/release configuration unless explicitly requested.
