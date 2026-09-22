"""Turning one run of one case into a verdict.

Three verdicts rather than two, because for someone who cannot see the screen
the difference between "it asked" and "it did the wrong thing" is the whole
difference between a usable app and an untrustworthy one. A question costs her
a second sentence. A wrong episode costs her the trust that anything she says
lands, and she has no way to check.
"""

from dataclasses import dataclass, replace
from enum import StrEnum

from audioreader.commands.intents import Action, CommandStatus, InterpretResult
from evals.cases import Case


class Grade(StrEnum):
    PASS = "pass"
    #: It asked instead of acting. Not the intended behaviour, but safe.
    ASKED = "asked"
    FAIL = "fail"
    #: The pipeline raised — a provider outage, a timeout, malformed output.
    #: Kept apart from FAIL so a flaky upstream is not read as a bad model.
    ERROR = "error"


@dataclass(frozen=True)
class Observed:
    """What actually happened, flattened for comparison.

    Subscriptions are read from the database either side of the call rather
    than from the spoken response: what the model said it did and what it did
    are exactly the pair worth keeping separate.
    """

    action: Action
    spoken: str
    episode_guid: str | None = None
    episode_show: str | None = None
    episode_title: str | None = None
    speed: float | None = None
    steps: tuple["Observed", ...] = ()
    subscribed_added: frozenset[str] = frozenset()
    subscribed_removed: frozenset[str] = frozenset()
    status: CommandStatus = CommandStatus.COMPLETED
    positions_before: dict[str, tuple[bool, bool, float]] | None = None
    positions_after: dict[str, tuple[bool, bool, float]] | None = None

    @classmethod
    def of(
        cls,
        result: InterpretResult,
        before: frozenset[str],
        after: frozenset[str],
    ) -> "Observed":
        episode = result.episode
        return cls(
            steps=tuple(cls.of(step, before, after) for step in result.actions),
            action=result.action,
            status=result.status,
            spoken=result.spoken_response,
            episode_guid=episode.guid if episode else None,
            episode_show=episode.feed.title if episode and episode.feed else None,
            episode_title=episode.title if episode else None,
            speed=result.speed,
            subscribed_added=after - before,
            subscribed_removed=before - after,
        )

    #: How each episode-shaped action reads in a failure line. Without this
    #: every one of them says "played", which is the one word a filing bug
    #: must not be reported in.
    _VERBS = {
        Action.MARK_PLAYED: "marked played",
        Action.DISMISS: "dismissed",
        Action.RESTORE: "restored",
    }

    def describe(self) -> str:
        if self.episode_title:
            verb = self._VERBS.get(self.action, "played")
            return f"{verb} {self.episode_title!r} ({self.episode_show})"
        if self.subscribed_added:
            return f"subscribed to {', '.join(sorted(self.subscribed_added))}"
        if self.subscribed_removed:
            return f"unsubscribed from {', '.join(sorted(self.subscribed_removed))}"
        if self.speed is not None:
            return f"set speed {self.speed:g}"
        if self.action is Action.UNKNOWN:
            label = "asked" if self.status is CommandStatus.NEEDS_CLARIFICATION else self.status.value
            return f"{label}: {self.spoken!r}" if self.spoken.strip() else "said nothing"
        return f"{self.action}: {self.spoken!r}"


def readable_aloud(text: str) -> bool:
    """Can an English voice say this?

    Every response is read out by the phone's English speech synthesiser, so a
    reply in another script is not a slightly worse answer — it is a noise she
    cannot act on, with no screen to fall back to. Latin letters through
    Extended-B are fine (Æthelstan, Rubaiyat, Björk); anything beyond is not.
    """
    return all(not char.isalpha() or ord(char) < 0x0250 for char in text)


def grade(case: Case, observed: Observed) -> tuple[Grade, str]:
    """The verdict, and one line saying why."""
    expected = case.expect.steps or (case.expect,)
    allowed_additions = {step.feed for step in expected if step.action is Action.SUBSCRIBED}
    allowed_removals = {step.feed for step in expected if step.action is Action.UNSUBSCRIBED}
    if observed.subscribed_added - allowed_additions or observed.subscribed_removed - allowed_removals:
        return Grade.FAIL, "Unrequested subscription change"
    if observed.positions_before is not None and observed.positions_after is not None:
        wanted = dict(observed.positions_before)
        for step in expected:
            performed = any(
                result.action is step.action and result.status is CommandStatus.COMPLETED
                for result in observed.steps or (observed,)
            )
            if performed and step.action in {Action.RESTORE, Action.DISMISS, Action.MARK_PLAYED} and step.episode:
                completed, dismissed, position = wanted.get(step.episode, (False, False, 0.0))
                if step.action is Action.RESTORE:
                    completed, dismissed = False, False
                    position = 0.0
                elif step.action is Action.DISMISS:
                    dismissed = True
                else:
                    completed = True
                wanted[step.episode] = (completed, dismissed, position)
        # A missing position row and an untouched default row are equivalent.
        keys = wanted.keys() | observed.positions_after.keys()
        if any(
            wanted.get(key, (False, False, 0.0)) != observed.positions_after.get(key, (False, False, 0.0))
            for key in keys
        ):
            return Grade.FAIL, "Missing or unexpected filing/progress change"
    if observed.steps and not case.expect.steps:
        return Grade.FAIL, "Unrequested additional action"
    return _grade_action(case, observed)


def _grade_action(case: Case, observed: Observed) -> tuple[Grade, str]:
    expect = case.expect
    did = observed.describe()
    if expect.steps:
        if len(observed.steps) != len(expect.steps):
            return Grade.FAIL, f"expected {len(expect.steps)} actions, received {len(observed.steps)}"
        # Speed may precede playback. Require every effect exactly once,
        # without requiring an arbitrary order for independent effects.
        remaining = list(observed.steps)
        for expected in expect.steps:
            match = next(
                (step for step in remaining if _grade_action(replace(case, expect=expected), step)[0] is Grade.PASS),
                None,
            )
            if match is None:
                return Grade.FAIL, f"missing or incorrect {expected.action} action"
            remaining.remove(match)
        return Grade.PASS, "all requested actions completed"

    if observed.episode_guid and observed.episode_guid in case.never:
        return Grade.FAIL, f"{did} — the one outcome this case rules out"

    # Both of these are failures whatever else was right, so they are checked
    # before the action: a silent app and an app talking in another language
    # are indistinguishable to her from a broken one.
    if observed.action is Action.UNKNOWN and not observed.spoken.strip():
        return Grade.FAIL, "went silent — nothing happened and nothing was said about it"
    if not readable_aloud(observed.spoken):
        return Grade.FAIL, f"unreadable aloud: {observed.spoken!r}"

    if observed.action is not expect.action:
        if observed.action is Action.UNKNOWN:
            if case.question_is_acceptable and observed.status is CommandStatus.NEEDS_CLARIFICATION:
                return Grade.ASKED, did
            return Grade.FAIL, f"{did} — requested action was not completed"
        return Grade.FAIL, f"expected {expect.action}, {did}"

    if observed.action is not Action.UNKNOWN and observed.status is not CommandStatus.COMPLETED:
        return Grade.FAIL, f"{did} — action did not complete"

    if expect.episodes and observed.episode_guid not in expect.episodes:
        return Grade.FAIL, f"{did} — wrong episode"

    if expect.feed:
        changed = observed.subscribed_added if expect.action is Action.SUBSCRIBED else observed.subscribed_removed
        if expect.feed not in changed:
            return Grade.FAIL, f"{did} — expected {expect.feed}"

    if expect.speed is not None and observed.speed != expect.speed:
        return Grade.FAIL, f"{did} — expected {expect.speed:g}"

    spoken = observed.spoken.casefold()
    if missing := [phrase for phrase in expect.says if phrase.casefold() not in spoken]:
        return Grade.FAIL, f"{did} — did not mention {', '.join(missing)}"

    return Grade.PASS, did
