# Changelog

The topmost section is sent to TestFlight as the **What to Test** notes for
every build, so write it for the person using the app rather than the person who
wrote the code. Most testers here are using VoiceOver or listening rather than
reading, so favour plain sentences over terse bullet fragments.

Add a new section at the top before tagging a release. The heading is the
version **without** the `v` — the tag `v1.1.0` wants `## 1.1.0`, because that is
also the `MARKETING_VERSION` testers see. Tagging `v1.1.0` while `## 1.0` is
still at the top fails the release rather than shipping stale notes.

## 1.0

First external build. Worth trying:

- Ask it to play a podcast by describing the episode rather than naming it, for
  example "play the one about the aliens lady".
- Ask for something from a show's back catalogue, not just the newest episode.
- Set a sleep timer and check it stops when you expected.
- Tell it to go back or skip forward while something is playing.

Please say what you asked for and what happened, especially if it heard you
wrongly — the exact words matter more than the outcome.
