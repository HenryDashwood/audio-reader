"""What she said, and what should happen.

Every case is one spoken sentence against the world in `world.py`, with the
behaviour it ought to produce. Cases come from two places: the manual test
plan in `docs/test-plan.md`, and requests that went wrong in real use — the
second kind is the more valuable, so add one every time something misbehaves,
before trying to fix it.

Expectations are written in terms of what the app *does*, not what the model
replies: which episode started playing, which show got subscribed, what speed
was set. A model that produces the right action with a clumsy sentence has
passed; one that says the right thing and plays the wrong episode has not.
"""

from dataclasses import dataclass, field

from audioreader.commands.intents import Action, Speaker, Turn
from evals.world import NEWSLETTERS, build_world


def _her(text: str) -> Turn:
    return Turn(speaker=Speaker.HER, text=text)


def _app(text: str) -> Turn:
    return Turn(speaker=Speaker.APP, text=text)


# Guids are derived from titles, so name them once here and let the cases read
# in English. A typo becomes an import-time error rather than a silent miss.
_WORLD = {show.key: show for show in build_world()}


def _guid(show_key: str, title: str) -> str:
    show = _WORLD[show_key]
    for item in show.items:
        if item.title == title:
            return item.guid
    raise KeyError(f"{show.title} has no episode titled {title!r}")


def _latest(show_key: str) -> str:
    return _WORLD[show_key].items[0].guid


def _newest_overall() -> str:
    """The newest item across everything she subscribes to, today.

    Computed rather than named: each show publishes on its own weekdays, so
    which one is newest depends on the day the corpus runs. Naming a show
    here made the case fail on the days after another show's release, with
    the model correctly playing the newer item and being marked wrong for it.
    """
    newest = max(
        (show.items[0] for show in _WORLD.values() if show.subscribed and show.items),
        key=lambda item: item.published_at,
    )
    return newest.guid


IN_OUR_TIME = "https://podcasts.files.bbci.co.uk/b006qykl.rss"
REST_IS_HISTORY = "https://feeds.megaphone.fm/GLT4787413333"
REST_IS_POLITICS = "https://feeds.megaphone.fm/GLT5347391293"
ASTRAL_CODEX_TEN = "https://www.astralcodexten.com/feed"
INFINITE_MONKEY_CAGE = "https://podcasts.files.bbci.co.uk/b00snr0w.rss"
SLOW_BORING = "https://www.slowboring.com/feed"
MONEY_STUFF = next(n.feed_url for n in NEWSLETTERS if n.key == "money-stuff")


@dataclass(frozen=True)
class Expect:
    """The behaviour a case is asking for.

    `action` is the outcome the app sees, so subscribing is SUBSCRIBED rather
    than SUBSCRIBE: what the model chose is its own business, what happened is
    the thing worth asserting.
    """

    action: Action
    #: For PLAY_EPISODE: the episode's guid, or any one of several when more
    #: than one answer is genuinely right.
    episode: str | None = None
    any_of: tuple[str, ...] = ()
    #: For SUBSCRIBED / UNSUBSCRIBED: the feed that must have changed.
    feed: str | None = None
    #: For SET_SPEED.
    speed: float | None = None
    #: Substrings the spoken response must contain, case-insensitively. Use
    #: sparingly — wording is the model's to choose — and only where the
    #: content of the sentence is the behaviour, as when it must ask which of
    #: two shows she meant.
    says: tuple[str, ...] = ()

    @property
    def episodes(self) -> tuple[str, ...]:
        return (self.episode,) if self.episode else self.any_of


@dataclass(frozen=True)
class Case:
    id: str
    said: str
    expect: Expect
    #: What breaks if this regresses. Read out in failure reports, so write it
    #: for whoever is looking at a red line six months from now.
    why: str
    tags: tuple[str, ...] = field(default_factory=tuple)
    #: Whether asking a question instead is a tolerable answer. Usually yes:
    #: for a listener who cannot see the screen, "which one did you mean?" is
    #: a poor outcome but a safe one, and worth distinguishing from playing
    #: the wrong thing. Set False where the request is unambiguous enough that
    #: a question is itself the bug.
    question_is_acceptable: bool = True
    #: Episodes that would be actively wrong to play. Picking one of these is
    #: always a failure, even if the action was right.
    never: tuple[str, ...] = field(default_factory=tuple)
    #: The guid of what is playing as she speaks. Set it on any case whose
    #: sentence contains a "this" or a "that" — those words have no referent
    #: at all without it, and a case that leaves it unset is asking the model
    #: to guess.
    now_playing: str | None = None
    #: What was already said before `said`, oldest first — the exchange the app
    #: would have been holding. Set it on any case that is the second half of a
    #: request: "the one about Agincourt" is not a command on its own, and a
    #: case that leaves this out is testing a sentence nobody would ever say.
    context: tuple[Turn, ...] = field(default_factory=tuple)


CASES: tuple[Case, ...] = (
    # -- The failure this corpus was written for --------------------------
    Case(
        id="deep-catalogue-by-topic",
        said="Play the In Our Time episode about Athelstan",
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "Æthelstan")),
        why=(
            "Reported from real use: it played a different In Our Time episode, then a "
            "blog post from another subscription entirely. The episode is real, she named "
            "the show, and it is roughly seventy episodes down — further back than the "
            "candidate window reaches. Anything other than this episode is wrong; playing "
            "something from another show is the worst of the wrong answers."
        ),
        tags=("play", "back-catalogue", "regression"),
        never=(_latest("astral_codex_ten"), _latest("rest_is_history")),
    ),
    Case(
        id="deep-catalogue-second-instance",
        said="Play the In Our Time about the Dead Sea Scrolls",
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "The Dead Sea Scrolls")),
        why=(
            "The same shape as the Athelstan request, to show whether that one was bad "
            "luck or the back catalogue being unreachable in general."
        ),
        tags=("play", "back-catalogue"),
    ),
    Case(
        id="deep-catalogue-narrows-to-show",
        said="Play the In Our Time one about the Anglo-Saxons",
        expect=Expect(
            Action.PLAY_EPISODE,
            any_of=(
                _guid("in_our_time", "Æthelstan"),
                _guid("in_our_time", "The Anglo-Saxon Chronicle"),
            ),
        ),
        why=(
            "The Rest Is History has a recent Anglo-Saxon episode and In Our Time's are "
            "both deep in the catalogue. A show name narrows the choice — it is not a "
            "hint — so reaching for the recent one from the wrong show is a failure even "
            "though it is about the right subject."
        ),
        tags=("play", "back-catalogue", "show-narrowing"),
        never=(_guid("rest_is_history", "The Anglo-Saxons: Alfred the Great"),),
    ),
    # -- Requests that should already work --------------------------------
    Case(
        id="latest-of-named-show",
        said="Play the latest In Our Time",
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("in_our_time")),
        why=(
            "The blog posts more often, so the newest thing in her library is almost "
            "never the newest In Our Time. Naming the show must beat recency."
        ),
        tags=("play", "latest", "show-narrowing"),
        question_is_acceptable=False,
        never=(_latest("astral_codex_ten"),),
    ),
    Case(
        id="latest-of-everything",
        said="Play the latest",
        expect=Expect(Action.PLAY_EPISODE, episode=_newest_overall()),
        why="With no show named, the newest item across every subscription is the answer.",
        tags=("play", "latest"),
        question_is_acceptable=False,
    ),
    Case(
        id="show-named-no-episode",
        said="Play the In Our Time",
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("in_our_time")),
        why=(
            "Naming a show and no episode means its newest one. Reported from real use, "
            "and it is the reliability that fails rather than the reasoning: the same "
            "request played the right episode twice and the second-newest once. Run this "
            "with --repeat; a single pass proves nothing."
        ),
        tags=("play", "latest", "show-narrowing", "regression"),
        question_is_acceptable=False,
        never=(_WORLD["in_our_time"].items[1].guid,),
    ),
    Case(
        id="show-name-misheard",
        said="play the in our stand",
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("in_our_time")),
        why=(
            "The transcript she actually produced: speech recognition turned 'In Our "
            "Time' into 'in our stand'. Near enough to identify the show, so the newest "
            "episode of it is right — and 'stand' must not be searched for as a bare "
            "substring, which found 'understanding' in 173 episodes."
        ),
        tags=("play", "mishearing", "regression"),
        never=(_WORLD["in_our_time"].items[1].guid,),
    ),
    Case(
        id="recent-by-topic",
        said="Play the one about dark matter",
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "Dark Matter")),
        why="The plainest request there is: a topic, well inside the candidate window.",
        tags=("play", "topic"),
        question_is_acceptable=False,
        never=(_guid("in_our_time", "Dark Energy"),),
    ),
    Case(
        id="recent-by-guest",
        said="Play the one with Patricia Fara",
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "Rosalind Franklin")),
        why=(
            "She remembers who was on more often than what it was called. The guest is "
            "in the description, not the title."
        ),
        tags=("play", "guest"),
    ),
    Case(
        id="article-by-name",
        said="Read me the latest Astral Codex Ten",
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("astral_codex_ten")),
        why=(
            "A blog is chosen exactly like a podcast, and 'read me' is the same request "
            "as 'play' — the app decides how it comes out of the speaker, not her."
        ),
        tags=("play", "article"),
        question_is_acceptable=False,
    ),
    Case(
        id="sleep-is-a-subject",
        said="Play the one about sleep",
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "Sleep")),
        why=(
            "The trap the sleep timer sets: 'sleep' is a thing people make programmes "
            "about. The phone's own matcher must let this through, and the model must "
            "then play the episode. Leaving her in silence is the worst outcome in the "
            "corpus, because nothing tells her anything went wrong."
        ),
        tags=("play", "topic", "regression", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="by-weekday",
        said="Play Tuesday's one",
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("rest_is_politics")),
        why=(
            "Only The Rest Is Politics publishes on a Tuesday, so this is unambiguous — "
            "to anyone who knows what day it is. Nothing in the prompt says, which is "
            "the point of keeping the case."
        ),
        tags=("play", "date", "test-plan"),
    ),
    # -- Not in her library -----------------------------------------------
    Case(
        id="play-unsubscribed-show",
        said="Play the latest Infinite Monkey Cage",
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("infinite_monkey_cage")),
        why=("A show she does not subscribe to still plays, without quietly subscribing her to it."),
        tags=("play-from-show", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="play-unsubscribed-episode",
        said="Play the Infinite Monkey Cage episode about volcanoes",
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("infinite_monkey_cage", "Volcanoes")),
        why=(
            "Two model calls: find the show, then pick from that show's episodes alone. "
            "In Our Time has a volcanoes episode too, and it must not win."
        ),
        tags=("play-from-show",),
        never=(_guid("in_our_time", "Vulcanology"),),
    ),
    # -- Subscribing and unsubscribing ------------------------------------
    Case(
        id="subscribe-podcast",
        said="Subscribe to The Rest Is Entertainment",
        expect=Expect(Action.SUBSCRIBED, feed="https://feeds.megaphone.fm/GLT8891234567"),
        why="The directory path, on a show whose name overlaps two she already has.",
        tags=("subscribe", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="subscribe-by-domain",
        said="Subscribe to the RSS feed of slowboring.com",
        expect=Expect(Action.SUBSCRIBED, feed=SLOW_BORING),
        why=(
            "Naming a site means she wants that site's own feed, resolved from its "
            "homepage — never something similarly named in the podcast directory."
        ),
        tags=("subscribe", "discovery", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="subscribe-already-subscribed",
        said="Subscribe to In Our Time",
        expect=Expect(Action.UNKNOWN, says=("already",)),
        why="Saying so is right; a second subscription, or a silent no-op, is not.",
        tags=("subscribe",),
    ),
    Case(
        id="unsubscribe-plain",
        said="Get rid of The Rest Is Politics",
        expect=Expect(Action.UNSUBSCRIBED, feed=REST_IS_POLITICS),
        why="'Get rid of' is an unsubscribe, and it must take the show she named.",
        tags=("unsubscribe", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="unsubscribe-ambiguous",
        said="Unsubscribe from The Rest Is",
        expect=Expect(Action.UNKNOWN, says=("history", "politics")),
        why=(
            "Two subscriptions match. Removing the wrong one silently is far worse than "
            "one more question, so the question naming both is the correct behaviour."
        ),
        tags=("unsubscribe", "test-plan"),
    ),
    # -- Newsletters waiting for her answer ---------------------------------
    Case(
        id="newsletter-approve-by-name",
        said="Yes, follow Matt Levine",
        expect=Expect(Action.SUBSCRIBED, feed=MONEY_STUFF),
        why=(
            "A sender waiting in her list is followed by the name it was listed under. "
            "The outcome is a subscription, so the app reloads Following and Latest."
        ),
        tags=("newsletter", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="newsletter-approve-by-publication",
        said="Accept the Money Stuff newsletter",
        expect=Expect(Action.SUBSCRIBED, feed=MONEY_STUFF),
        why=(
            "She knows the newsletter's name, not the sender's. Money Stuff is only in "
            "the subjects listed under Matt Levine, and that has to be enough."
        ),
        tags=("newsletter",),
        question_is_acceptable=False,
    ),
    Case(
        id="newsletter-block",
        said="Block Benedict Evans, I don't want that one",
        expect=Expect(Action.UNSUBSCRIBED, says=("blocked benedict evans",)),
        why="Refusing a sender is permanent, and the confirmation names who was refused.",
        tags=("newsletter", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="newsletter-ambiguous",
        said="Follow that newsletter",
        expect=Expect(Action.UNKNOWN, says=("matt levine", "benedict evans")),
        why=(
            "Two senders are waiting and she named neither. Following the wrong one puts "
            "a stranger's mail in Latest, so the right answer is the question naming both."
        ),
        tags=("newsletter",),
    ),
    Case(
        id="newsletter-address",
        said="What's my newsletter address?",
        expect=Expect(Action.UNKNOWN, says=("newsletter address is",)),
        why="The address is the one thing she has to be able to ask for out loud.",
        tags=("newsletter", "test-plan"),
        question_is_acceptable=False,
    ),
    # -- Speed --------------------------------------------------------------
    Case(
        id="speed-double",
        said="Play at double speed",
        expect=Expect(Action.SET_SPEED, speed=2.0),
        why="The one transport-ish command that goes to the server rather than the phone.",
        tags=("speed", "test-plan"),
        question_is_acceptable=False,
    ),
    Case(
        id="speed-one-and-a-half",
        said="Play it at one and a half times speed",
        expect=Expect(Action.SET_SPEED, speed=1.5),
        why="Spoken fractions are the common phrasing and must not round to 1 or 2.",
        tags=("speed",),
        question_is_acceptable=False,
    ),
    Case(
        id="speed-normal",
        said="Go back to normal speed",
        expect=Expect(Action.SET_SPEED, speed=1.0),
        why="'Normal' is 1, not 'unknown'.",
        tags=("speed", "test-plan"),
        question_is_acceptable=False,
    ),
    # -- Filing episodes away -----------------------------------------------
    Case(
        id="mark-this-played",
        said="I've already heard this one, mark it as played",
        expect=Expect(Action.MARK_PLAYED, episode=_latest("rest_is_history")),
        why=(
            "The commonest of these by far, and the one that only works by voice: she is "
            "listening to it as she says it. 'This one' has no referent unless what is "
            "playing is put in front of the model, so a regression here shows up as the "
            "model picking the top of the list — which is right by luck when the latest "
            "episode is playing and wrong every other time."
        ),
        tags=("filing", "now-playing"),
        now_playing=_latest("rest_is_history"),
        question_is_acceptable=False,
    ),
    Case(
        id="mark-named-episode-played",
        said="Mark the In Our Time about Athelstan as played, I listened to it last night",
        expect=Expect(Action.MARK_PLAYED, episode=_guid("in_our_time", "Æthelstan")),
        why=(
            "Filing works on the back catalogue too, and by the same search that finds an "
            "episode to play. Filing the wrong row is worse than playing the wrong one: "
            "nothing announces it, and she finds out weeks later when the episode is "
            "missing from her list."
        ),
        tags=("filing", "back-catalogue"),
        never=(_latest("in_our_time"),),
    ),
    Case(
        id="dismiss-this",
        said="I'm not interested in this one, get rid of it",
        expect=Expect(Action.DISMISS, episode=_latest("rest_is_politics")),
        why=(
            "Not the same as having heard it. The two are stored separately precisely so "
            "her list never claims she listened to something she skipped."
        ),
        tags=("filing", "now-playing"),
        now_playing=_latest("rest_is_politics"),
        question_is_acceptable=False,
    ),
    Case(
        id="restore-this",
        said="Actually put that one back, I haven't heard it",
        expect=Expect(Action.RESTORE, episode=_latest("in_our_time")),
        why=(
            "The undo. Without it a mistake made by voice can only be corrected by sight, "
            "which for her means not at all."
        ),
        tags=("filing", "now-playing"),
        now_playing=_latest("in_our_time"),
    ),
    Case(
        id="skip-ahead-is-not-dismissal",
        said="Skip ahead a bit",
        expect=Expect(Action.UNKNOWN),
        why=(
            "'Skip' means two opposite things, and the transport word is answered on the "
            "phone — so anything reaching the server is either a mis-hearing or a phrase "
            "the phone did not recognise. Reading it as 'remove this episode' would take "
            "away the thing she is enjoying, in answer to a request to hear more of it."
        ),
        tags=("filing", "unknown"),
        now_playing=_latest("rest_is_history"),
        never=(_latest("rest_is_history"),),
    ),
    # -- Saying no ----------------------------------------------------------
    Case(
        id="nothing-matches",
        said="Play the one about beekeeping in Tanzania",
        expect=Expect(Action.UNKNOWN),
        why=(
            "Nothing in the library is about this. Asking is right; playing whatever was "
            "nearest is the failure mode that makes the app untrustworthy, because she "
            "cannot see that it picked wrong."
        ),
        tags=("unknown", "test-plan"),
    ),
    Case(
        id="meaningless",
        said="Um, the thing, you know, with the",
        expect=Expect(Action.UNKNOWN),
        why="A short question back, not silence and not a guess.",
        tags=("unknown", "test-plan"),
    ),
    # -- Requests that take more than one sentence --------------------------
    Case(
        id="follow-up-names-the-episode",
        said="the one about Agincourt",
        context=(
            _her("Play something from The Rest Is History"),
            _app("Which episode would you like?"),
        ),
        expect=Expect(Action.UNKNOWN),
        why=(
            "The shape every clarification has: the app asked, she answered, and her "
            "answer is a fragment that means nothing on its own. The Rest Is History has "
            "no Agincourt episode, so the right answer is another question — but it must "
            "be a question about that show, not a blank 'which show did you mean?', and "
            "it must never be an episode of something else that happens to mention a "
            "battle. This is the case that fails outright if the exchange is not read."
        ),
        tags=("conversation", "unknown"),
        never=(_latest("astral_codex_ten"), _latest("rest_is_politics")),
    ),
    Case(
        id="follow-up-picks-from-the-named-show",
        said="the Alexander one",
        context=(
            _her("Play me a Rest Is History"),
            _app("Which episode would you like?"),
        ),
        expect=Expect(
            Action.PLAY_EPISODE,
            any_of=(
                _guid("rest_is_history", "Alexander the Great in India"),
                _guid("rest_is_history", "Alexander the Great: The Persian Campaign"),
            ),
        ),
        why=(
            "Her answer names the episode and the earlier line names the show. Read "
            "together they are one unambiguous request, so a question here is the bug: "
            "she has now said everything needed twice over."
        ),
        tags=("conversation", "play"),
        question_is_acceptable=False,
    ),
    Case(
        id="follow-up-answers-with-a-show-name",
        said="In Our Time",
        context=(
            _her("Play the latest one"),
            _app("Which show did you mean?"),
        ),
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("in_our_time")),
        why=(
            "A show name on its own, after a question. The trap is reading it as "
            "'subscribe to In Our Time' — a bare name is what a subscribe request looks "
            "like — when the exchange plainly says she is choosing between shows to play "
            "from. Subscribing to something she already has is the visible failure; the "
            "quiet one is asking again."
        ),
        tags=("conversation", "play"),
        question_is_acceptable=False,
    ),
    Case(
        id="follow-up-does-not-swallow-a-new-request",
        said="Actually, play the latest Astral Codex Ten",
        context=(
            _her("Play the Rest Is History about the Borgias"),
            _app("Playing The Borgias, Part One."),
        ),
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("astral_codex_ten")),
        why=(
            "The other half of reading an exchange: history is context, not gravity. She "
            "has changed her mind, and the sentence stands on its own — carrying on with "
            "the Borgias because they were mentioned a moment ago is the failure that "
            "arrives the day multi-turn is switched on."
        ),
        tags=("conversation", "play"),
        question_is_acceptable=False,
        never=(
            _guid("rest_is_history", "The Borgias, Part One"),
            _guid("rest_is_history", "The Borgias, Part Two"),
        ),
    ),
    Case(
        id="follow-up-reaches-the-back-catalogue",
        said="the Athelstan one",
        context=(
            _her("Play an In Our Time"),
            _app("Which episode would you like?"),
        ),
        expect=Expect(Action.PLAY_EPISODE, episode=_guid("in_our_time", "Æthelstan")),
        why=(
            "The candidate search has to read both halves too, not just her latest "
            "sentence. Athelstan is seventy episodes down: search 'the Athelstan one' "
            "alone and the show is missing, search the first line alone and the episode "
            "is. Either way the answer is outside the window and the clarification the "
            "app just asked for cannot be acted on."
        ),
        tags=("conversation", "back-catalogue", "play"),
        question_is_acceptable=False,
    ),
)


def by_id(case_id: str) -> Case:
    for case in CASES:
        if case.id == case_id:
            return case
    raise KeyError(case_id)


def select(patterns: tuple[str, ...]) -> tuple[Case, ...]:
    """Cases whose id or tags match any of the given substrings."""
    if not patterns:
        return CASES
    return tuple(case for case in CASES if any(pattern in case.id or pattern in case.tags for pattern in patterns))
