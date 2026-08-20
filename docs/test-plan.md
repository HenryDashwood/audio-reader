# Manual test plan

Everything the automated tests cannot reach: real audio, real speech, real interruptions, and how any of it feels to someone who cannot see the screen.

Work through it before a release that matters. Each item is an action and the result to expect — if the result differs, that is a finding worth writing down even when it seems small.

**Legend**

- 📱 needs a physical device (audio, microphone, calls, Bluetooth)
- 👁️ needs VoiceOver on
- 🌐 needs a network change (aeroplane mode)
- ⏱️ takes real time to observe

---

## Before you start

- [ ] Install the build you actually intend to test, and note its version and build number here: `________`
- [ ] 📱 Download a **Premium** English voice — Settings → Accessibility → Spoken Content → Voices → English. Without one, every article is read in the robotic compact voice and you are not testing what she will hear.
- [ ] Know how to reset: **Settings → Delete Account** inside the app gives you a genuinely fresh account. Deleting and reinstalling the app does not, because the account lives on the server.
- [ ] Have a second device or simulator signed into the same account if you want to check positions follow her.

---

## 1. First run and sign-in

- [ ] Fresh install, first launch → the sign-in screen appears, not a blank library
- [ ] Sign in with Apple completes → lands on the Shows tab
- [ ] Choose **Hide My Email** on a fresh account → sign-in still works
- [ ] Empty library shows "No shows yet" with a way forward, not a bare screen
- [ ] Force-quit and reopen → still signed in, no second sign-in prompt
- [ ] 📱 First tap of the microphone prompts for **microphone** and **speech recognition** permission

### Permission refused

- [ ] Deny the microphone (or revoke it in iOS Settings), open the voice sheet → she is **told what is wrong and where to fix it**, not "I could not hear you, tap and try again"
- [ ] An **Open Settings** button is present and opens Hearful's settings
- [ ] Grant permission, return to the app, try again → works, and the button disappears

---

## 2. Voice: the main loop

The heart of the app. Try each phrasing out loud, not typed.

- [ ] "Subscribe to In Our Time" → finds it, subscribes, confirms aloud, appears in Shows
- [ ] "Subscribe to Astral Codex Ten" → a blog, not a podcast, still works
- [ ] "Subscribe to the RSS feed of astralcodexten.com" → resolves the site's own feed
- [ ] "Play the latest In Our Time" → plays the newest episode **of that show**, not a newer episode of something else
- [ ] "Play the one about \<topic in a real episode\>" → picks it by subject
- [ ] "Play the one with \<a guest\>" → picks it by guest
- [ ] "Play Tuesday's one" → picks by date
- [ ] "Play the latest" with several subscriptions → plays the newest across all of them
- [ ] Ask for a show you are **not** subscribed to → it plays without subscribing you
- [ ] "Unsubscribe from In Our Time" → removes it, confirms aloud
- [ ] Subscribe to two shows with similar names, then unsubscribe by that name → **asks which one** rather than guessing
- [ ] Say something meaningless → a short question back, not silence
- [ ] Say nothing at all → "I did not hear anything", and the app is usable again
- [ ] ⏱️ Ask something that takes a while → "One moment" fills the silence, then the real answer

### Requests that take more than one sentence

The app asks, she answers, and the two are one request. Do these out loud without touching the screen between sentences.

- [ ] 📱 "Play a Rest Is History" → it asks which episode, then **listens again on its own** — the listening tone comes back with no tap
- [ ] 📱 Answer with just the episode — "the Alexander one" → it plays that episode of **that show**. Being asked "which show?" again is the failure
- [ ] 📱 "Play the latest one" with several subscriptions, then answer with only a show name → it plays that show's newest. It must not **subscribe** you to a show you already have
- [ ] 📱 After it starts something, ask for something completely different → the new request wins. Carrying on with the previous subject is the failure this introduces
- [ ] 📱 Answer a question with silence → "I did not hear anything", and the microphone **stays shut** rather than asking again
- [ ] 📱 Let it ask the same thing three or four times over → it eventually stops asking and hands you back the screen, rather than reopening the microphone forever
- [ ] 📱 An answer that lands after a long wait → "One moment" still fills the gap, and does **not** appear in the transcript
- [ ] 📱 Close the sheet while it is asking you something → nothing further is said and the microphone does not reopen
- [ ] 📱 While an episode is playing, go through a two-sentence request → the episode comes back **once**, at the end, not between the question and your answer
- [ ] ⏱️ Ask something, wait a few minutes with the sheet open, then tap and ask something unrelated → the old exchange is not read as context for the new one

### The transcript

- [ ] Each thing you say appears on screen under **You**, and each reply under **Hearful**
- [ ] A misheard word is visible there — this is the fastest way to tell a mis-hearing from a bad answer
- [ ] Drag the sheet up to the large size → a longer exchange can be scrolled back through
- [ ] The newest turn is the one showing; you do not have to scroll to find it
- [ ] The microphone is still easy to hit without aiming, with the transcript on screen
- [ ] 👁️ Swipe through the sheet → the microphone first, then the conversation as one group, then Close. Each turn reads as "You said: …" or "Hearful said: …"
- [ ] 👁️ Turn text size up to a large accessibility size → the transcript still reads and scrolls

### Filing episodes

- [ ] While an episode is **playing**, "I've already heard this, mark it as played" → confirms aloud naming that episode, and **stops** — it must not carry on playing
- [ ] ⏱️ Wait a minute, then pull to refresh **Latest** → still gone. If it is back, the position reporter has overwritten the filing
- [ ] While playing, "I'm not interested in this one" → same, and the show's page says "Not in Latest" rather than "Played"
- [ ] "Put that one back" → returns to **Latest**, and plays from the beginning rather than the end
- [ ] Name an episode instead of saying "this" — "mark the one about \<topic\> as played" → files **that** one, and whatever is playing keeps playing
- [ ] With **nothing** playing, "mark this as played" → asks which episode, rather than filing whatever was newest
- [ ] "Skip ahead" while listening → jumps forward. It must never be heard as "remove this episode"

### Cost and limits

- [ ] ⏱️ Make a dozen requests inside a minute → it eventually says you are going too fast, spoken not silent, and recovers shortly after

---

## 3. Voice: transport

These resolve on the phone with no network. Try them **in aeroplane mode** to prove it.

- [ ] "Pause" → stops immediately, no spoken confirmation needed
- [ ] Also try: "stop", "be quiet", "shush", "wait"
- [ ] "Carry on" → resumes. Also: "continue", "keep going", "play"
- [ ] "Skip" → jumps forward 30 seconds
- [ ] "Go back" → jumps back 15 seconds. Also: "rewind", "say that again"
- [ ] "Faster" then "slower" → speed changes in steps, audibly
- [ ] "Normal speed" → returns to 1×
- [ ] "Play at double speed" → sets 2× (this one goes to the server, so it needs signal)
- [ ] Speaking while something is playing → the episode pauses so she can be heard, and **resumes afterwards** if the command did not start anything new

---

## 4. Voice: sleep timer

- [ ] "Stop in twenty minutes" → confirms aloud, chip on the player shows a countdown
- [ ] "Set a sleep timer" with no duration → confirms half an hour
- [ ] "Stop in half an hour" / "in an hour" / "in an hour and a half" → all understood
- [ ] "Cancel the sleep timer" → confirms it is off
- [ ] ⏱️ Let one actually expire → playback stops and you hear the end tone
- [ ] Set a timer, then pause it yourself, then let the timer expire → **no sound**, since it was already stopped

### Must NOT happen

- [ ] "Play the one about sleep" → plays an episode. **Does not set a timer.**
- [ ] "Play the sleep episode" → same
- [ ] Bare "stop" → pauses. **Does not set a timer.**

---

## 5. Siri and Shortcuts

📱 all of these — Siri does not work properly in the simulator.

- [ ] Hearful appears in the **Shortcuts** app. If not, reboot the phone before debugging phrases; the index goes stale after repeated installs
- [ ] "Hey Siri, ask Hearful" → the app opens with the microphone live
- [ ] "Hey Siri, play the latest on Hearful" → plays **without** bringing the app to the front
- [ ] "Hey Siri, play the latest \<show\> on Hearful" → correct show
- [ ] "Hey Siri, subscribe to \<something\> on Hearful" → subscribes, confirms aloud, no app launch
- [ ] Subscribe to a new show, then immediately use its name in a Siri phrase → recognised
- [ ] Run a play intent with the phone locked → either plays, or comes forward and explains why
- [ ] Run an intent while signed out → says to open Hearful and sign in

---

## 6. Playback and audio

- [ ] 📱 An audio episode plays, and sounds right at 1×
- [ ] 📱 An **article** is read aloud in the chosen voice
- [ ] Scrub the slider → audio follows, and the position sticks
- [ ] Skip forward and back with the on-screen buttons
- [ ] Change speed on screen → takes effect immediately, and survives to the next episode
- [ ] Stop mid-episode, leave, come back → resumes **where you left off**
- [ ] Play something you have already finished → starts from the beginning, not the outro
- [ ] ⏱️ Let an episode run to the very end → a short tone and a buzz, then silence. **Nothing plays automatically afterwards**

### Lock screen and elsewhere

- [ ] 📱 Lock the phone → title and artwork on the lock screen, controls work
- [ ] 📱 Play/pause from the lock screen, and scrub from it
- [ ] 📱 AirPods: pinch to pause and resume
- [ ] 📱 "Hey Siri, pause" while listening

### Interruptions — the ones that used to be broken

- [ ] 📱 Take a **phone call** mid-episode → pauses, and **resumes by itself** when the call ends
- [ ] 📱 Same during an **article** → same behaviour
- [ ] 📱 Set an alarm to fire mid-episode → pauses, resumes after
- [ ] 📱 Pull **headphones** out mid-episode → goes quiet, does **not** continue out loud on the speaker
- [ ] 📱 Same during an **article** — this is the one the speech synthesiser gets wrong if unhandled
- [ ] 📱 Walk out of Bluetooth range → same
- [ ] Pause it yourself, then take a call → stays paused afterwards. Being interrupted must not start it playing

### Across launches

- [ ] Force-quit mid-episode, reopen → the mini player has it loaded and paused, at the right position
- [ ] Background the app mid-episode and leave it a while → audio keeps playing

---

## 7. Screens and navigation (visual)

- [ ] **Shows**: list shows artwork, title, episode count
- [ ] Search as you type → subscribed shows, whole-library episodes and public podcasts appear in labelled sections without pressing Search
- [ ] Switch between **All**, **Shows** and **Episodes** → only the requested result types remain
- [ ] Search with the podcast directory unavailable → matching subscribed shows and episodes remain usable, with the failure explained separately
- [ ] Paste a feed URL, bare domain, Apple Podcasts sharing link, `itpc://` URL or `pcast://` URL → "Open podcast or feed" appears immediately and previewing works
- [ ] Paste a URL while the directory is unavailable → the URL result remains present and usable
- [ ] Make a one-letter typo or transpose adjacent letters in a show name → the intended local/directory result is still found
- [ ] Search for an episode older than the newest 50 in a show → it is returned under **Episodes in your library**, with its show name
- [ ] Search for a publication absent from the directory → **Search the web** appears; it asks for AI permission if needed and returns only a feed that can be verified
- [ ] Tap a search result → preview page, Subscribe works
- [ ] Subscribe to something already subscribed → says so rather than duplicating
- [ ] Show detail → episodes newest first, Unsubscribe present
- [ ] Unsubscribe → returns to the library, show gone
- [ ] **Latest**: newest episodes across subscriptions
- [ ] Start an episode, leave it part-heard, return to Latest → it appears under **Continue listening**, and not twice
- [ ] Finished episodes read "Played"; part-heard ones read "N min left"
- [ ] Swipe a **Latest** row from the right → **Mark played** and **Not interested**; either one removes the row
- [ ] Pull to refresh afterwards → the removed episode does not come back
- [ ] The same episode on its **show's page** is still there, reading "Played" or "Not in Latest"
- [ ] Swipe that row → **Put back**, and it returns to **Latest** on the next refresh
- [ ] Play an episode to the end → it leaves **Latest** on the next refresh, without being marked by hand
- [ ] **Mini player** appears when something is playing, tapping it opens the full player
- [ ] Full player closes again — by swipe **and** by the close button
- [ ] Pull to refresh on both lists

---

## 8. Offline and failures

- [ ] 🌐 Aeroplane mode, open **Shows** → your shows are still listed, with an offline note
- [ ] 🌐 Same for **Latest**
- [ ] 🌐 Open a show → its episodes are still listed, with an offline note
- [ ] 🌐 Try to play a streamed episode offline → a spoken failure, not silence
- [ ] 🌐 Ask by voice offline → transport words still work; anything needing the server says it cannot reach the internet
- [ ] 🌐 Fresh install + offline → an honest error, since there is nothing cached yet
- [ ] Sign out and back in → the previous account's library is not visible in between
- [ ] Subscribe to a feed that no longer exists, wait for polling → the show is marked **"Not updating"**

---

## 9. VoiceOver 👁️

Do this with the **screen curtain** on — three-finger triple-tap. If you can see the screen you are not testing what she experiences.

- [ ] Every control announces something meaningful. Nothing reads as "button" alone
- [ ] Flick through **Shows** → each row reads title and episode count as one sensible phrase
- [ ] A failing show also announces "not updating"
- [ ] Flick through **Latest** → rows read title, date, length and progress without running together
- [ ] The **offline note** is reachable in the swipe order, not skipped
- [ ] On a **Latest** row, the rotor's **Actions** offer "Mark played" and "Not interested" — this is the only way she can reach them at all
- [ ] Choosing one → the row goes **and** she is told which episode and what happened to it
- [ ] Do it with the network off → she is told it failed, rather than the row simply not moving
- [ ] **Mini player** → "Now playing: \<title\>" and a separate Play/Pause, and the first one opens the player
- [ ] **Full player** → every control labelled; the scrubber announces its position; **Close player** works
- [ ] **Voice sheet** → lands on "Ask Hearful" *before* "Close", so the double tap does what the screen says
- [ ] Double tap → it starts listening, and the go-ahead tone comes **after** VoiceOver has finished talking
- [ ] Speak → it hears you, and does not transcribe VoiceOver's own voice
- [ ] With VoiceOver off, opening the voice sheet starts listening **immediately** — that behaviour must survive
- [ ] Sleep timer and speed controls announce their current value, not just their name
- [ ] **Delete Account** → the consequence is read out before you reach the destructive button
- [ ] Nothing is announced twice; nothing important is silent

---

## 10. Other accessibility

- [ ] **Larger Text** at the biggest accessibility size → nothing truncates, overlaps, or becomes unreachable
- [ ] **Dark mode** → every screen legible, no invisible text
- [ ] **Reduce Motion** on → nothing feels broken
- [ ] Every tap target is comfortably hittable without looking

---

## 11. iPad

- [ ] Installs and launches
- [ ] **Portrait** → layouts sensible, nothing stretched across the full width
- [ ] **Landscape** → same, and rotating mid-episode does not interrupt playback
- [ ] Sign-in screen: the button is a sensible width, not the full screen
- [ ] The player and voice sheet present properly as sheets

---

## 12. Account and privacy

- [ ] **Sign Out** → returns to sign-in, and the library is not visible afterwards
- [ ] Sign back in → subscriptions and positions are all still there
- [ ] The privacy policy loads: <https://audio-reader-production.up.railway.app/privacy>
- [ ] **Delete Account** → confirmation explains the consequence; cancelling really cancels
- [ ] Confirm deletion → returns to sign-in
- [ ] Sign in again with the same Apple ID → a **fresh, empty** account, not the old one
- [ ] Check **Settings → Apple Account → Sign in with Apple** on the device → Hearful should no longer be listed, because deletion revokes it

---

## 13. Regression traps

Things that were broken at some point and would be easy to break again.

- [ ] Skipping repeatedly does **not** send a flood of position updates — one per tap
- [ ] After skipping, closing the app immediately, and reopening → resumes where you skipped **to**, not where you skipped from
- [ ] "Play the one about sleep" is a play request, never a sleep timer
- [ ] The voice sheet under VoiceOver does not start listening before she has activated it
- [ ] The full player and the voice sheet can both be **left** without a swipe gesture
- [ ] An episode ending produces a tone; it does not simply go quiet
- [ ] Siri shortcuts still register from a **Release** build (they never do from Debug)

---

## Recording what you find

For anything that fails, note: what you did, what you expected, what happened,
and whether VoiceOver was on. "It went quiet after I asked for the Agincourt
one, with VoiceOver on" is a fixable report. "The voice thing is broken" is not.
