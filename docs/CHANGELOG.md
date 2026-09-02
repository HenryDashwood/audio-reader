# Changelog

The topmost section is sent to TestFlight as the **What to Test** notes for
every build, so write it for the person using the app rather than the person who
wrote the code. Most testers here are using VoiceOver or listening rather than
reading, so favour plain sentences over terse bullet fragments.

Add a new section at the top before tagging a release. The heading is the
version **without** the `v` — the tag `v1.1.0` wants `## 1.1.0`, because that is
also the `MARKETING_VERSION` testers see. Tagging `v1.1.0` while `## 1.0` is
still at the top fails the release rather than shipping stale notes.

## 1.4.0

This build can follow newsletters that only exist as email, such as Money
Stuff or Benedict's Newsletter. Worth trying:

- In Settings, find your newsletter address under **Newsletters**. Read
  Address Aloud should spell it out one letter at a time, Copy Address should
  put it on the clipboard, and Share Address should offer to send it to
  someone who can sign you up.
- Give that address to a newsletter, or simply send it an email yourself. The
  sender should appear at the top of Following under **Waiting for your
  answer**, with how many messages it has sent and the latest subject, and
  nothing from it should be in Latest yet.
- Tap **Follow**. The sender should become a show in Following, its messages
  should appear in Latest, and opening one should read the writing without
  the unsubscribe links, addresses and "view in browser" lines that emails
  carry.
- Tap **Block** on another sender and confirm. It should disappear, and a
  later email from it should not come back.
- Unsubscribe from a followed newsletter. It should leave Following, and the
  next issue it sends should arrive as a fresh question rather than silently.
- With VoiceOver on, do all of the above with the screen curtain down. The
  Follow and Block buttons should name the sender, and the address should be
  spelled out rather than read as one word.

Please say which newsletter you tried and whether anything in the email
chrome was still read aloud, or anything from the writing was missing.

## 1.3.0

This build is much better at finding publications, makes articles nicer to
read and hear, and tidies up playback. Worth trying:

- Search for a podcast, blog or newsletter by name, then try again by pasting
  its homepage, feed address or an Apple Podcasts sharing link. It should find
  the canonical publication without creating duplicates.
- Open a show after subscribing. Check that its artwork, description and
  website link make sense, including for a publication whose feed has sparse
  metadata.
- Open a written article containing headings, pictures and links. The page
  should keep that structure, links should open reliably, and the reading
  controls should remain easy to reach as you scroll.
- In Settings, choose an installed Premium or Eloquence English voice, then
  listen to a longer article. Try changing speed, pausing and resuming, and
  listen for clipped endings, buzzing or unnatural pauses.
- Move between the full player, mini player and the rest of the app while
  something is playing. Playback and the visible controls should stay in sync.
- In Latest, use **Clear Latest** and reopen the app. The list should stay
  clear until something new arrives. Following a new show should leave its
  existing archive on the show's page instead of filling Latest with it.

Please say which publication or article you tried and what happened,
especially if discovery chose the wrong feed or spoken text sounded odd.

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
