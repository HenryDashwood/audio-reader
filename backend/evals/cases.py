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

from audioreader.commands.intents import Action
from evals.world import build_world

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


IN_OUR_TIME = "https://podcasts.files.bbci.co.uk/b006qykl.rss"
REST_IS_HISTORY = "https://feeds.megaphone.fm/GLT4787413333"
REST_IS_POLITICS = "https://feeds.megaphone.fm/GLT5347391293"
ASTRAL_CODEX_TEN = "https://www.astralcodexten.com/feed"
INFINITE_MONKEY_CAGE = "https://podcasts.files.bbci.co.uk/b00snr0w.rss"
SLOW_BORING = "https://www.slowboring.com/feed"


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
        expect=Expect(Action.PLAY_EPISODE, episode=_latest("astral_codex_ten")),
        why="With no show named, the newest item across every subscription is the answer.",
        tags=("play", "latest"),
        question_is_acceptable=False,
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
