# Changelog

The topmost section is sent to TestFlight as the **What to Test** notes for
every build, so write it for the person using the app rather than the person who
wrote the code. Most testers here are using VoiceOver or listening rather than
reading, so favour plain sentences over terse bullet fragments.

Add a new section at the top before tagging a release. The heading is the
version **without** the `v` — the tag `v1.1.0` wants `## 1.1.0`, because that is
also the `MARKETING_VERSION` testers see. Tagging `v1.1.0` while `## 1.0` is
still at the top fails the release rather than shipping stale notes.

## 1.2.0

This build can be asked a question back, reads written articles on screen as
well as aloud, and lets you tell it you have already heard something. Worth
trying:

- Ask for something it cannot pin down on its own — "play a Rest Is History"
  — and answer the question it asks you without touching the phone. It should
  start listening again by itself, and treat your answer as the rest of what
  you were saying rather than a new request.
- Change your mind halfway through an exchange and ask for something
  completely different. The new request should win.
- While an episode is playing, say "I've already heard this, mark it as
  played", or "I'm not interested in this one". Both stop it and take the
  episode out of Latest; "put that one back" undoes it. The same two actions
  are on a swipe from the right of a Latest row, and in the VoiceOver rotor.
- Open a blog post rather than a podcast. Articles now have a page of their
  own, with the author, the links and the pictures kept rather than stripped
  out, and any formulas are read as maths instead of spelled out symbol by
  symbol.
- Look for an old episode using the magnifying glass at the top of a show's
  page, instead of pulling the list down to find a search field.
- Swipe the mini player away when you have finished with it. It also puts
  itself away on its own when an episode reaches the end.

Please say what you asked for and what happened, especially if it heard you
wrongly — the exact words matter more than the outcome.

## 1.0

First external build. Worth trying:

- Ask it to play a podcast by describing the episode rather than naming it, for
  example "play the one about the aliens lady".
- Ask for something from a show's back catalogue, not just the newest episode.
- Set a sleep timer and check it stops when you expected.
- Tell it to go back or skip forward while something is playing.

Please say what you asked for and what happened, especially if it heard you
wrongly — the exact words matter more than the outcome.
