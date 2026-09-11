# Changelog

The topmost section is sent to TestFlight as the **What to Test** notes for
every build, so write it for the person using the app rather than the person who
wrote the code. Most testers here are using VoiceOver or listening rather than
reading, so favour plain sentences over terse bullet fragments.

Add a new section at the top before tagging a release. The heading is the
version **without** the `v` — the tag `v1.1.0` wants `## 1.1.0`, because that is
also the `MARKETING_VERSION` testers see. Tagging `v1.1.0` while `## 1.0` is
still at the top fails the release rather than shipping stale notes.

## 1.4.1

Articles can now display supported YouTube and Vimeo videos. Open an article
containing a video and tap its play button. Videos wait for you to start them;
an "Open video in browser" link is available if a video cannot play inside Magpie.

This build also fixes the system playback controls becoming out of step with
article narration. Please try pausing and resuming from Control Centre and the
Lock Screen, including after switching from a podcast to an article.

## 1.4.1 — conversation improvements

Conversations now keep listening after Magpie replies. Wait for the listening
sound and vibration, then ask your next question. Staying quiet ends listening
without an error; say "That's all" to close the conversation. Starting an
article or podcast also ends listening. In Settings → Conversation, you can
change the waiting time or turn off listening after replies.

With VoiceOver, Magpie waits for its opening instruction before listening.
Inside the conversation, double-tap with two fingers to finish speaking,
interrupt a reply, or start listening again. Please try opening a conversation
with Siri, asking several questions, staying quiet, and closing it while Magpie
is speaking.

Settings → Siri and Shortcuts now explains how to launch Ask Magpie by tapping
the back of your iPhone three times. Save a shortcut containing the Ask Magpie
action, then assign it in iPhone Settings → Accessibility → Touch → Back Tap →
Triple Tap. Try it with Magpie closed, already open, and with a conversation
already on screen. Unlock the phone if asked and wait for the listening cue.

Magpie's spoken replies now use the Articles speed under Settings → Playback
Speed. Change that speed, then ask another question; the next reply should use
the same speaking speed as article narration.

## 1.4.1 — earlier builds

This build fixes three listening problems. Please check that finished articles
disappear from Latest, that the mini player's play/pause button responds when
you tap around its icon, and that saying "fast forward three minutes" skips
ahead three minutes without changing your playback speed.

Open Settings → Siri and Shortcuts for the action list. Please try:

- Say "Continue listening in Magpie" with the app open and closed. Podcasts
  and articles should resume from your saved place.
- Say "Run a request in Magpie", then describe what you want. If Siri asks a
  follow-up question or opens Magpie, you should not need to repeat yourself.
- Combine Find Listening Items, Play a Listening Item, Set Playback Speed,
  and Set Sleep Timer in a shortcut. Try filing an item and undoing that action.
- Add Ask Magpie and Continue Listening to Control Center or the Lock Screen.
  Check both controls with VoiceOver and headphones.

Report missing Siri actions, duplicate requests, lost positions, or wrong confirmations.

Combined sources now recognize the same article when a subscriber link adds an
access token. Please check that public and subscriber copies appear once and
keep their shared reading progress.

Reopening a feed preview now checks for new posts when its cached copy is more
than fifteen minutes old, even if nobody follows that feed yet. Please try a
publication you previewed a few days ago. Its new posts should appear without
subscribing first; saved posts remain available if the publisher cannot be
reached.

Publication pages now keep "Manage sources" and "Unsubscribe" in the three-dot
menu beside the title. With VoiceOver, the button is called "Manage" followed
by the publication's name. Please check both actions and the layout with larger
text sizes.

Publication sources can now be combined. Please try:

- Subscribe to two feeds from the same publication, then open one and choose
  "Manage sources" from its three-dot menu. Combine the other subscription and
  check that Library shows one publication with articles from both sources.
- Read or dismiss an article available in both feeds. Its copies should share
  progress and reading state. Short posts and paywalled previews remain visible.
- Use "Separate source" to return a source to Library. Its reading progress
  should be preserved, and older articles should not refill Latest.

This build improves voice control. Please try:

- Start a voice request. The listening vibration should be stronger, and a
  different tone should mark the end of listening. For a slow request, a short
  sound after a few seconds means Magpie is still working.
- Say a show or author's name, pause briefly while thinking, then finish your
  request. Check the transcript and whether Magpie carried out the whole request.
- Tap the voice button while listening to finish your sentence. Tap it during
  a response to interrupt and ask something else, or close and reopen voice.
- Say "go back two minutes", "skip forward ninety seconds", or "play at one
  and a half speed". These controls should work without an internet connection.
- Ask for two things together, such as "subscribe to that show and play its
  latest episode" or "play this at one and a half speed".
- Ask for something unheard, or open an article and say "read this". A request
  for an item under a particular length uses items with a known duration.
- After filing an item or following an RSS show by voice, say "undo that".
  Email signup and unsubscribe requests cannot be undone.
- If the connection drops during a request, reopen voice and say "did that
  work?" to recover its result. Please report any repeated action or misleading
  confirmation, and whether you were using the phone speaker or headphones.

After calls, playback should resume only if previously playing, never through
the speaker after disconnecting AirPods. Articles should restart their
paragraph; remaining time and retry position should stay correct.

## 1.4.0

This build can follow newsletters that only exist as email, such as Money
Stuff or Benedict's Newsletter. Worth trying:

- In Settings, find your newsletter address under **Newsletters**. Read
  Address Aloud should spell it out one letter at a time, Copy Address should
  put it on the clipboard, and Share Address should offer to send it to
  someone who can sign you up.
- Give that address to a newsletter, or simply send it an email yourself. The
  sender should appear at the top of Latest under **Waiting for your
  answer**, with how many messages it has sent and the latest subject, and
  nothing from it should be in the list below yet.
- A show with no artwork should show its initials on a colour of its own,
  the same colour every time, rather than a grey waveform — for written
  shows and podcasts alike.
- Tap **Follow**. The sender should become a show in Following, its messages
  should appear in Latest, and opening one should read the writing without
  the unsubscribe links, addresses and "view in browser" lines that emails
  carry.
- Tap **Block** on another sender and confirm. It should disappear, and a
  later email from it should not come back.
- Unsubscribe from a followed newsletter. It should leave Following, and the
  sender should be told to stop (a Substack should confirm by email or stop
  sending). A newsletter forwarded from another inbox is the exception: its
  page says so, and unsubscribing says to remove the forwarding rule there. If it writes again anyway, the issue should arrive as a fresh
  question with the earlier issues still counted, and following it again
  should bring them all back.
- With VoiceOver on, do all of the above with the screen curtain down. The
  Follow and Block buttons should name the sender, and the address should be
  spelled out rather than read as one word.
- Do it by voice instead. With a sender waiting, tap the microphone and say
  "yes, follow Matt Levine" or "block that one". It should confirm what it
  did and the lists should update. With two senders waiting and neither
  named, it should ask which you meant rather than guess. "What's my
  newsletter address?" should read the address out word by word.
- Let Magpie do the signing up. Paste a Substack's web address into search on
  the Following screen. When it says no feed was found, tap **Sign up by
  email**. It should say it has asked the newsletter to write to you, and the
  newsletter should appear in Following by itself when its first email
  arrives, with nothing left waiting for your answer. Try the same with a
  Bloomberg newsletter page: it should explain that one needs an account and
  read you the address to give it instead.
- By voice, "subscribe to" followed by a site's address that has no feed
  should do the same signing up, and say what happened.
- Open a followed newsletter that also publishes on the web, such as a
  Substack. Within a poll or two it should take the publication's name and
  artwork, and its page should list the archive from before you followed it
  as well as the issues you were sent, with nothing listed twice. Latest
  should still show only what arrived by email.

Also in this build:

- Podcasts and articles now keep separate playback speeds. In Settings,
  under **Playback Speed**, set one for podcasts and another for articles,
  then move between an episode and a written piece: each should come back
  at its own speed, and the speed you had before should carry over to both.
- Written pieces in Latest and on a show's page say how long they are in
  words, the way podcasts say minutes. Opening one whose feed only carried a
  teaser should fill the count in, and it should still be there afterwards.

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
