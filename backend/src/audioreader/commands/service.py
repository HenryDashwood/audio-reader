"""Turn a spoken request into an action, using an LLM to pick the episode."""

import asyncio
import logging
import operator
import re
from collections.abc import Sequence
from datetime import UTC, date, datetime
from functools import reduce

from pydantic import ValidationError
from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader import positions, telemetry
from audioreader.commands.intents import (
    Action,
    Candidate,
    InterpretResult,
    ModelDecision,
    Speaker,
    Turn,
)
from audioreader.config import settings
from audioreader.episode_search import mentions
from audioreader.feeds import service as feed_service
from audioreader.feeds.discovery import (
    DiscoveredFeed,
    find_feed_by_name,
    resolve_feed,
    spoken_domains,
)
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import (
    PodcastMatch,
    PodcastSearchError,
    matches_name,
    mentions_substack,
    publication_display_name,
    publication_name,
    search_podcasts,
    select_unambiguous_match,
)
from audioreader.feeds.service import AlreadySubscribedError
from audioreader.models import PLAYABLE_EPISODE, Episode, Feed, Subscription, User, utcnow
from audioreader.newsletters import service as newsletters
from audioreader.newsletters.service import PendingSender, spoken_address
from audioreader.text import search_key, summarise

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You help a blind listener control a listening app by voice.
The app plays podcast episodes and reads written articles aloud; articles are
marked in the list and are chosen exactly like episodes.

You will be given today's date, what she said, and a numbered list of episodes
and articles she subscribes to. Decide what she wants and reply with the
matching action.

The list is newest first, and holds her most recent items plus older ones
matching what she said — so a much older episode appearing near the bottom is
there because it answers to her words, and is very likely the one she means.

- Choose play_episode only when one item is a clear match. She may refer to
  it by topic, by guest, by date ("Tuesday's one"), or by position
  ("the latest"). Prefer the most recent item when a request is ambiguous
  between several of the same show.
- "The latest" with no show named means the first item in the list, whatever
  show it belongs to. Play it rather than asking which show she meant.
- If she names a show, only episodes from that show may be chosen. A show name
  narrows the choice, it is not a hint: "the latest In Our Time" means the most
  recent In Our Time episode, never a newer episode of something else.
- Choose play_from_show when she asks to hear an episode of a show that has no
  episodes in the list — she can listen without subscribing. Put just the
  show's name in search_query. Put what identifies the episode in
  episode_query ("the one about Agincourt"), or leave it empty when she wants
  the latest. Leave spoken_response empty: the app says what was found.
- Choose subscribe when she wants to follow a show she does not have yet
  ("subscribe to", "add", "start following"). Shows include blogs, newsletters
  and Substacks as well as podcasts — "subscribe to Astral Codex Ten" is a
  subscribe even though it is a blog. Put just the show's name in
  search_query — no "subscribe to", no "the podcast", nothing else. If she
  names a website ("the RSS feed of astralcodexten.com"), keep the domain in
  search_query exactly as she said it — naming a site means she wants that
  site's own feed. Leave spoken_response empty: the app says what was
  actually found.
  Speech recognition may split a brand into ordinary words. In particular,
  "sub stack" means Substack. A platform or publication type describes where
  to look and is not part of the name: "subscribe to semi analysis sub stack"
  means action subscribe and search_query "semi analysis".
- Choose unsubscribe when she wants to stop following a show she already has
  ("unsubscribe from", "remove", "stop following", "get rid of"). Put just the
  show's name in search_query, and leave spoken_response empty.
- She may be shown newsletter senders waiting for her answer: emails that
  arrived at her newsletter address from someone she has not yet said yes or
  no to. Choose approve_newsletter when she wants to follow, accept, allow or
  keep one ("yes, follow Matt Levine", "accept the Bloomberg newsletter",
  "follow that newsletter"), and block_newsletter when she wants to refuse,
  block or never hear from one ("block it", "no, I don't want that one").
  Put the sender's number in newsletter_id, copied exactly from that list.
  When only one sender is waiting, "it", "that one" and "the newsletter" mean
  that sender. When several are waiting and she has not said which — "follow
  that newsletter", "block it" — never pick one: choose unknown and ask which
  she means, naming them. Following the wrong one puts a stranger's mail in
  her list, and blocking the wrong one is permanent. Only senders in that
  list can be approved or blocked; if she names one that is not waiting,
  choose unknown and say so. Leave spoken_response empty for
  approve_newsletter and block_newsletter: the app confirms what it did.
- Choose newsletter_address when she asks for her newsletter address, or for
  the email address to give a newsletter ("what is my newsletter address",
  "what email do I use to sign up for newsletters"). Leave spoken_response
  empty: the app reads the address out.
- Choose mark_played when she says she has already heard something ("mark
  this as played", "I have listened to that one", "I have already heard the
  Athelstan one"). Put the item's id in episode_id.
- Choose dismiss when she wants an item out of her list without hearing it
  ("skip that one", "get rid of this", "I am not interested in that", "do not
  show me that again"). Put the item's id in episode_id.
- Choose restore when she wants one of those two undone ("put that back", "I
  have not heard that after all", "unmark it").
- For those three, "this", "that" and "it" on their own mean the item she is
  listening to, which is named above the list whenever something is playing.
  If nothing is playing and she has not otherwise said which item she means,
  choose unknown and ask which one. Never guess: filing the wrong episode is
  invisible to her until the day she goes looking for it.
  Leave spoken_response empty — the app confirms these itself, naming what it
  actually changed.
- Wanting to skip an item is not the same as wanting to skip forward inside
  one. "Skip that episode" is dismiss; "skip ahead" is not, and reaches you
  only by mistake — choose unknown for it.
- Choose set_speed when she asks for a playback speed ("one and a half times",
  "play at double speed", "half speed", "normal speed"). Put the multiplier in
  speed: "double" is 2, "normal" is 1, "half" is 0.5. Sensible values are 0.5
  to 3. Leave spoken_response empty: the app confirms the speed itself.
- Choose unknown when nothing matches, or when several episodes match equally
  well and guessing would be worse than asking. Your sentence is then a
  question, and she will answer it out loud straight away.
- You may be shown what has already been said in this exchange. Only the last
  thing she said is the request; the lines before it are context for it. When
  your own last line was a question, what she has just said is almost
  certainly the answer to it, and the two are one request: after you asked
  "Which show did you mean?", "the Rest Is History" means play a Rest Is
  History episode — it is not a request to subscribe to it. After "Which
  episode?", "the one about Agincourt" names an episode of the show she asked
  about a moment ago, not of any show in the list.
- When your last line offered two similarly named shows, her answer chooses
  between them and completes the action she originally requested. Preserve
  whether that action was subscribe or play; do not turn the answer into a
  new, unrelated request.
- A request you have already carried out is finished. If what she says next
  stands on its own, treat it as a new request and ignore what came before;
  only read it against the earlier lines when it plainly refers back to them
  ("no, the other one", "the one before that", "actually make it faster").
- episode_id must be copied exactly from the list. Never invent one.
- spoken_response is read aloud to her and she waits through every word of it
  before the episode starts, so make it as short as possible.
  For play_episode use at most six words: enough to recognise the episode and
  catch a wrong pick, nothing more. "Playing Diana Pasulka." or "Playing the
  Delian League." — never the show name, episode number, guest list or topic
  unless that is the only way to identify it.
  For unknown, one short question naming what you need.
"""


#: The second, scoped stage of play_from_show: one show's episodes only, so
#: the only decision left is which episode she described.
EPISODE_PICK_PROMPT = """You help a blind listener control a listening app by
voice. The app plays podcast episodes and reads written articles aloud.

She asked for an episode of one particular show. You will be given what she
said and a numbered list of that show's episodes and articles. Choose
play_episode with the item that matches what she described — by topic, by
guest, or by date — or unknown when nothing clearly matches.

- episode_id must be copied exactly from the list. Never invent one.
- spoken_response is read aloud and she waits through every word of it before
  the episode starts. For play_episode use at most six words, enough to catch
  a wrong pick: "Playing the Agincourt episode."
  For unknown, one short question naming what you need.
"""


async def build_candidates(
    session: AsyncSession,
    user: User,
    transcript: str | None = None,
    limit: int | None = None,
    search_limit: int | None = None,
) -> list[Candidate]:
    """The episodes and articles the model may choose between, newest first.

    Only the user's own subscriptions, and only playable items: audio, or
    article text the app can read aloud.

    Recency alone is not enough. A feed like In Our Time carries its whole
    archive — over a thousand episodes, back to 1998 — so with a handful of
    subscriptions the newest sixty items reach back only a couple of months,
    and everything before that is invisible to the model however clearly she
    names it. So the list is the newest items *plus* whatever the words she
    used match anywhere in her library.
    """
    subscribed = select(Episode).join(Subscription, Subscription.feed_id == Episode.feed_id)
    return _to_candidates(
        await _recent_and_matching(
            session, subscribed, Subscription.user_id == user.id, transcript, limit, search_limit
        )
    )


async def feed_candidates(
    session: AsyncSession,
    feed_id: int,
    transcript: str | None = None,
    limit: int | None = None,
    search_limit: int | None = None,
) -> list[Candidate]:
    """One show's playable items, newest first, subscription not required.

    Searched the same way as her own library: a long-running show's back
    catalogue is out of reach of a recency window whether she subscribes to
    it or not.
    """
    return _to_candidates(
        await _recent_and_matching(
            session, select(Episode), Episode.feed_id == feed_id, transcript, limit, search_limit
        )
    )


async def _recent_and_matching(
    session: AsyncSession,
    base,
    scope,
    transcript: str | None,
    limit: int | None,
    search_limit: int | None,
) -> list[Episode]:
    limit = limit if limit is not None else settings.command_candidate_limit
    search_limit = search_limit if search_limit is not None else settings.command_search_limit

    newest = (Episode.published_at.desc().nulls_last(), Episode.id.desc())
    recent = list(
        await session.scalars(
            base.where(scope, PLAYABLE_EPISODE).options(joinedload(Episode.feed)).order_by(*newest).limit(limit)
        )
    )

    words = spoken_keywords(transcript or "")
    if not words or search_limit <= 0:
        return recent
    words = await _identifying(session, base, scope, words, search_limit)
    if not words:
        return recent

    score = _match_score(words)
    seen = {episode.id for episode in recent}
    # Over-fetch, because the highest-scoring matches are usually the recent
    # ones already in hand and it is the rest we are here for.
    matched = await session.scalars(
        base.where(scope, PLAYABLE_EPISODE, score > 0)
        .options(joinedload(Episode.feed))
        .order_by(score.desc(), *newest)
        .limit(limit + search_limit)
    )
    older = [episode for episode in matched if episode.id not in seen][:search_limit]

    # Newest first overall, so "the latest" is still the top of the list and
    # an older match simply sits further down with its date beside it.
    return sorted(
        recent + older,
        key=lambda episode: (episode.published_at or _UNDATED, episode.id),
        reverse=True,
    )


#: A word matching more than this share of the library is describing the
#: library rather than an episode in it.
_TOO_COMMON = 0.1


async def _identifying(session: AsyncSession, base, scope, words: list[str], search_limit: int):
    """The words that actually narrow the library down.

    "Play the In Our Time episode about Athelstan" carries two searchable
    words. "Athelstan" is the title of one episode in eleven hundred; "time"
    is in a third of them, because it is the show's own name and turns up in
    every other blurb. Counting them equally buries the answer under whatever
    matched "time" most recently, which is exactly the wrong episode of the
    right show — the failure this all began with.

    So a word matching a large share of the library is dropped. The floor
    matters as much as the share: a word matching fewer episodes than there
    are slots to spare cannot crowd anything out, however common it looks in
    a small library.

    Dropping every word — and so searching for nothing — is a real answer,
    not a failure to avoid. "Play the In Our Time" leaves only "time" once
    the command words are gone, and searching for it fills fifteen slots and
    about a thousand tokens with whatever last mentioned the word. Those
    slots are better left empty.
    """
    counted = (
        await session.execute(
            base.with_only_columns(
                func.count(),
                *(func.sum(case((mentions(word), 1), else_=0)) for word in words),
            ).where(scope, PLAYABLE_EPISODE)
        )
    ).one()
    total, *counts = counted
    if not total:
        return words

    ceiling = max(search_limit, total * _TOO_COMMON)
    return [word for word, count in zip(words, counts, strict=True) if (count or 0) <= ceiling]


def _match_score(words: list[str]):
    """How many of the words she used this episode answers to.

    A plain LIKE scan, which is fast enough for one person's library — under
    40ms across eleven hundred episodes. If it ever is not, the upgrade is a
    tsvector index rather than a shorter list.
    """
    return reduce(operator.add, [case((mentions(word), 1), else_=0) for word in words])


#: Words that say what she wants done, not which episode she wants. Dropped
#: before searching, since every one of them appears throughout the library.
_COMMAND_WORDS = {
    "play", "read", "listen", "hear", "start", "want", "would", "like",
    "please", "the", "one", "ones", "about", "with", "episode", "episodes",
    "show", "programme", "podcast", "article", "post", "latest", "newest",
    "recent", "last", "next", "that", "this", "there", "here", "and", "for",
    "from", "was", "were", "his", "her", "their", "its", "you", "know",
    "thing", "something", "anything", "back", "again", "some", "any", "all",
    "give", "find", "have", "has", "had", "can", "could", "will",
}  # fmt: skip


def spoken_keywords(transcript: str, limit: int = 6) -> list[str]:
    """The words in what she said that could name a subject, guest or title.

    Short words go too: "in", "our" and "of" match half of everything, and
    losing them costs nothing, because a show she named is narrowed by the
    model afterwards rather than by this search.

    Folded by the same function that built the column being searched, so the
    two sides always agree about what a word looks like.
    """
    keywords: list[str] = []
    for word in search_key(transcript).split():
        if len(word) > 3 and word not in _COMMAND_WORDS and word not in keywords:
            keywords.append(word)
    return keywords[:limit]


_UNDATED = datetime.min.replace(tzinfo=UTC)


def _to_candidates(episodes) -> list[Candidate]:
    return [
        Candidate(
            id=episode.id,
            title=episode.title,
            feed_title=episode.feed.title,
            # The model sees stripped, truncated text: feed descriptions are
            # HTML soup and would otherwise dominate the token bill.
            description=summarise(episode.description, limit=300),
            published_at=episode.published_at,
            duration_seconds=episode.duration_seconds,
            is_article=episode.audio_url is None,
        )
        for episode in episodes
    ]


def build_prompt(
    transcript: str,
    candidates: list[Candidate],
    today: date | None = None,
    now_playing: Candidate | None = None,
    turns: Sequence[Turn] = (),
    pending: Sequence[PendingSender] = (),
) -> str:
    """The per-request half of the prompt.

    Today's date goes here rather than in the system prompt, which is fixed
    text a provider can cache. Without it "Tuesday's one" and "last week's"
    cannot be answered at all: every episode carries a date and the model has
    nothing to measure them against.

    What is playing is named for the same reason: "mark this as played" is a
    sentence about something the phone can see and the backend cannot, and
    without this line the only honest answer to it is a question.

    Anything already said comes first and her latest sentence last, so the
    request is the line nearest the list it has to be answered from.
    """
    today = today or utcnow().date()
    lines = [f"Today is {today.strftime('%A %d %B %Y')}.", ""]
    if turns:
        lines.append("Already said in this exchange, oldest first:")
        for turn in turns:
            who = "She said" if turn.speaker is Speaker.HER else "You said"
            lines.append(f'    {who}: "{turn.text}"')
        lines += ["", "And now she said:"]
    else:
        lines.append("She said:")
    lines += [f'"{transcript}"', ""]
    if now_playing is not None:
        lines += [
            f"She is listening to [{now_playing.id}] {now_playing.title} — {now_playing.feed_title} right now.",
            "",
        ]
    if pending:
        # Numbered apart from the episodes, and labelled, so a sender's
        # number is never mistaken for an episode's — the two lists are
        # answered with different fields.
        lines.append("Newsletter senders waiting for her answer (use newsletter_id):")
        for item in pending:
            line = f"[newsletter {item.feed.id}] {item.feed.title} — {_spoken_count(item.message_count)}"
            if item.latest_title:
                line += f" — latest: {item.latest_title}"
            lines.append(line)
        lines.append("")
    lines.append("Episodes and articles she subscribes to:")
    for candidate in candidates:
        published = candidate.published_at.strftime("%A %d %B %Y") if candidate.published_at else "undated"
        header = f"[{candidate.id}] {candidate.title} — {candidate.feed_title} — {published}"
        if candidate.is_article:
            header += " — article"
        elif candidate.duration_seconds:
            header += f" — {round(candidate.duration_seconds / 60)} min"
        lines.append(header)
        if candidate.description:
            lines.append(f"    {candidate.description}")
    return "\n".join(lines)


def spoken_so_far(transcript: str, turns: Sequence[Turn] = ()) -> str:
    """Every word she has said in this exchange, for the candidate search.

    The episode she wants may have been named a sentence ago: "play the Rest Is
    History" — "which episode?" — "the one about Agincourt". Searching the
    latest line alone looks for Agincourt without the show; searching the first
    alone looks for the show without the episode. The answer is only in the two
    together, and without this the clarification the model just asked for
    arrives with the episode still outside the candidate window.

    Her lines only. The app's own questions are our words, not hers, and
    searching them would spend the back-catalogue slots on whatever most
    recently mentioned "episode" or "show".

    Her latest sentence first, then the earlier ones newest-first — which is
    backwards as prose and right as a search. Only the first handful of
    identifying words are searched for, so whatever comes first is what gets
    looked up: put the exchange in the order it was spoken and a wordy opening
    line spends the whole budget, dropping the one word she has just said that
    names the episode. Order is otherwise immaterial here, since every keyword
    is scored alike.
    """
    said = [transcript]
    said += [turn.text for turn in reversed(turns) if turn.speaker is Speaker.HER]
    return " ".join(said)


def _asking(question: str) -> InterpretResult:
    """An answer that is itself a question, so the app listens for the reply.

    A function rather than a flag passed at each site, because the flag is easy
    to leave off and a question with it missing is a dead end she has no way to
    see: the app falls silent and waits to be tapped, having just asked her
    something.
    """
    return InterpretResult(action=Action.UNKNOWN, spoken_response=question, expects_reply=True)


async def interpret(
    session: AsyncSession,
    llm,
    transcript: str,
    user: User,
    discovery_llm=None,
    now_playing_episode_id: int | None = None,
    turns: Sequence[Turn] = (),
    country: str | None = None,
) -> InterpretResult:
    # Feed discovery gets its own client (web search, long timeout); without
    # one, the ordinary client still handles the easy, well-known cases.
    discovery_llm = discovery_llm if discovery_llm is not None else llm
    candidates = await build_candidates(session, user, spoken_so_far(transcript, turns))
    # What she is listening to has to be choosable, and it often is not: a
    # 2003 In Our Time episode is decades outside the recency window and
    # matches none of the words in "mark this as played". Without this, the
    # one command she is most likely to give about the thing in her ears
    # would be the one command that cannot name it.
    now_playing = await _now_playing(session, now_playing_episode_id)
    if now_playing is not None and all(candidate.id != now_playing.id for candidate in candidates):
        candidates.append(now_playing)
    pending = await newsletters.pending_senders(session, user)
    # What the model had to work with. An episode she asked for by name and did
    # not get is a different failure depending on whether it was in this list
    # at all: one is the model misreading her, the other is the candidate
    # window being too narrow to contain the answer. `feed_count` separates
    # those again — sixty candidates drawn from two shows and from twenty are
    # very different haystacks.
    telemetry.annotate(
        candidate_count=len(candidates),
        feed_count=len({candidate.feed_title for candidate in candidates}),
    )

    raw = await llm.decide(
        system=SYSTEM_PROMPT,
        user=build_prompt(transcript, candidates, now_playing=now_playing, turns=turns, pending=pending),
        output_model=ModelDecision,
    )

    try:
        decision = ModelDecision.model_validate(raw)
    except ValidationError as exc:
        logger.warning("model returned an unusable decision (%s): %r", exc, raw)
        telemetry.annotate(failure="invalid_decision")
        return _asking(_CLARIFY)

    # What the model asked for, which is not always what we let it have. The
    # difference between this and the `action` on the enclosing span is the
    # count of times we overrode it, and every one of those is a command she
    # spoke and did not get.
    #
    # `search_query` is the show name it heard. When a subscribe fails, that
    # name is the difference between the directory not carrying a show and us
    # having gone looking for the wrong one.
    telemetry.annotate(model_action=decision.action.value, search_query=decision.search_query)

    if decision.action is Action.SUBSCRIBE:
        return await _subscribe(session, decision.search_query, transcript, user, discovery_llm, country=country)

    if decision.action is Action.PLAY_FROM_SHOW:
        return await _play_from_show(
            session,
            llm,
            transcript,
            decision.search_query,
            decision.episode_query,
            discovery_llm,
            country=country,
        )

    if decision.action is Action.UNSUBSCRIBE:
        return await _unsubscribe(session, decision.search_query, user)

    if decision.action is Action.SET_SPEED:
        return _set_speed(decision.speed)

    if decision.action in (Action.APPROVE_NEWSLETTER, Action.BLOCK_NEWSLETTER):
        return await _answer_newsletter(session, decision, pending, user)

    if decision.action is Action.NEWSLETTER_ADDRESS:
        return await newsletter_address(session, user)

    if decision.action in _FILING:
        return await _file_episode(session, decision.action, decision.episode_id, candidates, user)

    if decision.action is not Action.PLAY_EPISODE:
        # Never pass an empty sentence through: the app would simply go quiet,
        # and she has no screen to check whether anything happened at all.
        #
        # An `unknown` from the model is a question by construction — the
        # prompt allows it nothing else — so it is one she can answer aloud.
        return _asking(decision.spoken_response.strip() or _CLARIFY)

    if not candidates:
        # Not a question, and the microphone must not reopen on it: what she
        # needs to do next is subscribe to something, which the sentence says.
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="You have no podcasts yet. Say subscribe, and the name of a show.",
        )

    # Never trust the model with a primary key: only ids we offered are valid.
    if decision.episode_id not in {candidate.id for candidate in candidates}:
        logger.warning("model chose episode_id %r, which was not offered", decision.episode_id)
        telemetry.annotate(failure="episode_not_offered")
        return _asking(_CLARIFY)

    # Feed loaded eagerly: the router folds show artwork into the response.
    episode = await session.get(Episode, decision.episode_id, options=[joinedload(Episode.feed)])
    if episode is None:
        return _asking(_CLARIFY)

    return InterpretResult(
        action=Action.PLAY_EPISODE,
        spoken_response=decision.spoken_response,
        episode=episode,
    )


def _set_speed(speed: float | None) -> InterpretResult:
    """Hand a validated multiplier to the app; the phone applies it."""
    if speed is None or not (0.5 <= speed <= 3.0):
        return _asking("What speed would you like? Between half and triple speed works.")
    # Round to the nearest quarter: the model can produce 1.499999, and "one
    # point five times speed" must never be read out as anything stranger.
    speed = round(speed * 4) / 4
    return InterpretResult(
        action=Action.SET_SPEED,
        spoken_response=f"{_spoken_speed(speed)} speed.",
        speed=speed,
    )


#: What each filing action writes, and how it is confirmed aloud. The two live
#: together because they must not drift apart: the sentence she hears is the
#: only evidence she has of which row changed.
_FILING: dict[Action, tuple[tuple[bool | None, bool | None], str]] = {
    Action.MARK_PLAYED: ((True, None), "Marked as played:"),
    # Only the dismissed flag: she has not heard it, and a list that says
    # otherwise is one she cannot trust about anything.
    Action.DISMISS: ((None, True), "Taken off your list:"),
    Action.RESTORE: ((False, False), "Back in your list:"),
}


async def _now_playing(session: AsyncSession, episode_id: int | None) -> Candidate | None:
    """What the phone says is playing, as a candidate the model can choose."""
    if episode_id is None:
        return None
    episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
    if episode is None:
        # The phone is ahead of us, or the episode has been pruned. Not worth
        # failing the whole command over: everything else still works.
        logger.warning("now-playing episode %r is not in the catalog", episode_id)
        return None
    return _to_candidates([episode])[0]


async def _file_episode(
    session: AsyncSession,
    action: Action,
    episode_id: int | None,
    candidates: list[Candidate],
    user: User,
) -> InterpretResult:
    """Mark an episode heard, put it aside, or put it back in the list."""
    if not candidates:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="You have no episodes yet. Say subscribe, and the name of a show.",
        )

    # Never trust the model with a primary key, and least of all here: playing
    # the wrong episode announces itself in a second, whereas filing the wrong
    # one is silent until the day she goes looking for it.
    if episode_id not in {candidate.id for candidate in candidates}:
        logger.warning("model chose episode_id %r for %s, which was not offered", episode_id, action)
        telemetry.annotate(failure="episode_not_offered")
        return _asking(_CLARIFY)

    # Feed loaded eagerly: the router folds show artwork into the response.
    episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
    if episode is None:
        return _asking(_CLARIFY)

    (played, dismissed), said = _FILING[action]
    await positions.set_episode_state(session, user, episode.id, played=played, dismissed=dismissed)
    # Our sentence, not the model's: this one names the row that actually
    # changed, which is the only way she can catch it having changed the wrong
    # one — and the only place that mistake ever surfaces.
    return InterpretResult(
        action=action,
        spoken_response=f"{said} {_spoken_title(episode.title)}.",
        episode=episode,
    )


#: A leading episode number and its punctuation: "696. ", "Ep 12: ", "5) ".
_LEADING_NUMBER = re.compile(r"^\s*(?:ep(?:isode)?\.?\s*)?\d+\s*[.:)\-]\s*", re.IGNORECASE)


def _spoken_title(title: str, words: int = 6) -> str:
    """Enough of a title to recognise, and no more.

    She waits through every word of a confirmation, and podcast titles are
    written to be scanned rather than heard: "696. Elizabeth I vs The
    Catholics: Killing the Queen (Part 5)". The filing number goes first — it
    identifies the episode to nobody — and what is left is cut to a few words,
    which is all it takes to notice the wrong one.
    """
    spoken = _LEADING_NUMBER.sub("", title).strip() or title.strip()
    parts = spoken.split()
    return " ".join(parts[:words]) if len(parts) > words else spoken


def _spoken_speed(speed: float) -> str:
    if speed == 1:
        return "Normal"
    if speed == int(speed):
        return f"{int(speed)} times"
    return f"{speed:g} times"


class AmbiguousShowError(Exception):
    """Several directory results are plausible enough that voice must ask."""

    def __init__(self, matches: list[PodcastMatch]) -> None:
        self.matches = matches


# A spoken command should never wait through the discovery client's full
# research timeout. Typed discovery can remain exhaustive; voice gets one
# web-search pass and a firm end-to-end deadline after the cheap deterministic
# guesses and podcast directory have run.
_VOICE_DISCOVERY_TIMEOUT_SECONDS = 15.0


async def _find_show(
    query: str,
    transcript: str,
    discovery_llm,
    country: str | None = None,
) -> DiscoveredFeed | None:
    """A show or publication by spoken name.

    A spoken domain wins outright: "the RSS feed of astralcodexten.com"
    names a website, and its own feed must be resolved directly — never
    outranked by a similarly-named show in the podcast directory. The
    transcript is checked as well as the model's extracted query, because
    the model sometimes strips the domain down to a bare name. Otherwise:
    the directory first (fast, covers essentially every podcast), then LLM
    web discovery for blogs and newsletters the directory does not know.
    """
    for domain in spoken_domains(f"{transcript} {query}"):
        try:
            feed_url, parsed = await resolve_feed(f"https://{domain}", preference=f"{transcript} {query}")
        except (FeedFetchError, FeedParseError):
            continue
        return DiscoveredFeed(feed_url=feed_url, title=parsed.title)

    lookup_query = publication_name(query)
    try:
        matches = await search_podcasts(lookup_query, country=country)
    except PodcastSearchError as exc:
        # The directory being down does not stop web discovery from working.
        logger.warning("podcast search failed for %r: %s", lookup_query, exc)
        matches = []
    if matches:
        if chosen := select_unambiguous_match(matches, lookup_query):
            return DiscoveredFeed(feed_url=chosen.feed_url, title=chosen.title)
        raise AmbiguousShowError(matches)
    discovery_query = lookup_query
    if mentions_substack(f"{transcript} {query}"):
        discovery_query += " substack"
    try:
        return await asyncio.wait_for(
            find_feed_by_name(
                discovery_query,
                discovery_llm,
                attempts=1,
                candidate_limit=4,
            ),
            timeout=_VOICE_DISCOVERY_TIMEOUT_SECONDS,
        )
    except TimeoutError:
        logger.warning("voice feed discovery timed out for %r", discovery_query)
        telemetry.annotate(failure="feed_discovery_timeout")
        return None


def _ambiguous_show_question(matches: list[PodcastMatch]) -> str:
    named: list[str] = []
    for match in matches:
        label = match.title
        if match.publisher:
            label += f" by {match.publisher}"
        if label not in named:
            named.append(label)
        if len(named) == 2:
            break
    if len(named) == 1:
        return f"I found more than one version of {named[0]}. Which did you mean?"
    return f"I found {named[0]} and {named[1]}. Which did you mean?"


async def _subscribe(
    session: AsyncSession,
    query: str | None,
    transcript: str,
    user: User,
    discovery_llm,
    country: str | None = None,
) -> InterpretResult:
    """Find a show or publication by spoken name and follow it."""
    if not query or not query.strip():
        return _asking("Which show would you like to subscribe to?")

    display_name = publication_display_name(query)
    try:
        found = await _find_show(query, transcript, discovery_llm, country=country)
    except AmbiguousShowError as exc:
        return _asking(_ambiguous_show_question(exc.matches))
    if found is None:
        # A site with no feed may still have a newsletter. Only when she named
        # the site herself, so her address goes where she pointed.
        if (signed_up := await sign_up_by_domain(session, user, transcript, query)) is not None:
            return signed_up
        # Worth separating from the other dead ends: this one is usually the
        # directory and the web search both coming up empty on a name that was
        # heard correctly, which no amount of prompt work will fix.
        telemetry.annotate(failure="show_not_found")
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I could not find a podcast or publication called {display_name}.",
        )

    try:
        await feed_service.subscribe(session, found.feed_url, user)
    except AlreadySubscribedError:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"You are already subscribed to {found.title}.",
        )
    except (FeedFetchError, FeedParseError) as exc:
        logger.warning("could not subscribe to %s: %s", found.feed_url, exc)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I found {found.title}, but could not load its episodes.",
        )

    return InterpretResult(
        action=Action.SUBSCRIBED,
        spoken_response=f"Subscribed to {found.title}.",
    )


async def _play_from_show(
    session: AsyncSession,
    llm,
    transcript: str,
    show_query: str | None,
    episode_query: str | None,
    discovery_llm,
    country: str | None = None,
) -> InterpretResult:
    """Play an episode of a show she is not subscribed to.

    The show is found in the directory (or, for a publication the directory
    does not know, by web discovery) and ingested into the shared catalog —
    but not subscribed to: asking to hear one episode is not asking to follow
    the show. The common case ("the latest X") is resolved here without a
    second model call; only a described episode needs the model again, and
    then it only reads this one show's episodes.
    """
    if not show_query or not show_query.strip():
        return _asking("Which show would you like to hear?")

    try:
        found = await _find_show(show_query, transcript, discovery_llm, country=country)
    except AmbiguousShowError as exc:
        return _asking(_ambiguous_show_question(exc.matches))
    if found is None:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I could not find a podcast or publication called {show_query}.",
        )

    try:
        feed = await feed_service.ensure_feed(session, found.feed_url)
    except (FeedFetchError, FeedParseError) as exc:
        logger.warning("could not load feed %s: %s", found.feed_url, exc)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I found {found.title}, but could not load its episodes.",
        )

    # Searched on what she said about the episode rather than the whole
    # sentence, so the show's own name does not become a search term. When she
    # only wants the latest, that is empty and no search runs at all.
    candidates = await feed_candidates(session, feed.id, episode_query or "")
    if not candidates:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"{feed.title} has no episodes I can play.",
        )

    if _wants_latest(episode_query):
        episode = await session.get(Episode, candidates[0].id, options=[joinedload(Episode.feed)])
        return InterpretResult(
            action=Action.PLAY_EPISODE,
            spoken_response=f"Playing the latest {feed.title}.",
            episode=episode,
        )

    raw = await llm.decide(
        system=EPISODE_PICK_PROMPT,
        user=build_prompt(transcript, candidates),
        output_model=ModelDecision,
    )
    try:
        decision = ModelDecision.model_validate(raw)
    except ValidationError as exc:
        logger.warning("model returned an unusable episode pick (%s): %r", exc, raw)
        telemetry.annotate(failure="invalid_episode_pick")
        return _asking(_CLARIFY)

    if decision.action is not Action.PLAY_EPISODE or decision.episode_id not in {
        candidate.id for candidate in candidates
    }:
        telemetry.annotate(failure="episode_not_in_show")
        # She has the show right and the episode wrong, which is the most
        # answerable of the dead ends: another word or two usually settles it.
        return _asking(decision.spoken_response or f"Which episode of {feed.title} did you mean?")

    episode = await session.get(Episode, decision.episode_id, options=[joinedload(Episode.feed)])
    return InterpretResult(
        action=Action.PLAY_EPISODE,
        spoken_response=decision.spoken_response,
        episode=episode,
    )


def _wants_latest(episode_query: str | None) -> bool:
    """Does the episode description just mean "the newest one"?

    Resolving this here saves a second model call for the most common request
    by far. Anything more specific goes to the model.
    """
    if episode_query is None:
        return True
    words = set(re.sub(r"[^a-z0-9 ]", " ", episode_query.casefold()).split())
    words -= {"the", "one", "episode", "show", "of", "their", "her", "his"}
    return not words or words <= {"latest", "newest", "most", "recent", "new", "last"}


async def _unsubscribe(session: AsyncSession, query: str | None, user: User) -> InterpretResult:
    """Stop following a show she already has."""
    if not query or not query.strip():
        return _asking("Which show would you like to remove?")

    feeds = (
        await session.scalars(
            select(Feed).join(Subscription, Subscription.feed_id == Feed.id).where(Subscription.user_id == user.id)
        )
    ).all()
    if not feeds:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="You are not subscribed to anything yet.",
        )

    matches = [feed for feed in feeds if matches_name(query, feed.title)]

    if not matches:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"You are not subscribed to {query}.",
        )

    if len(matches) > 1:
        # Removing the wrong show silently is far worse than one more question.
        names = " or ".join(feed.title for feed in matches)
        return _asking(f"Did you mean {names}?")

    feed = matches[0]
    title = feed.title
    # Only this user's subscription goes; the feed and its episodes stay in
    # the shared catalog for other subscribers.
    await feed_service.unsubscribe(session, feed.id, user)
    return InterpretResult(
        action=Action.UNSUBSCRIBED,
        spoken_response=f"Unsubscribed from {title}.",
    )


async def _answer_newsletter(
    session: AsyncSession,
    decision: ModelDecision,
    pending: Sequence[PendingSender],
    user: User,
) -> InterpretResult:
    """Follow or refuse a sender waiting for her answer.

    The model names the sender by the number it was shown, or failing that
    by name. With one sender waiting, "follow it" needs neither. With
    several and no clear pick, it asks: refusing the wrong newsletter is
    permanent, and following the wrong one puts a stranger's mail in Latest.
    """
    if not pending:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="No newsletters are waiting for your answer.",
        )
    chosen = _pending_choice(decision, pending)
    if chosen is None:
        names = " or ".join(item.feed.title for item in pending[:3])
        return _asking(f"Which sender did you mean: {names}?")
    if decision.action is Action.APPROVE_NEWSLETTER:
        return await approve_newsletter(session, user, chosen.feed.id)
    return await block_newsletter(session, user, chosen.feed.id)


def _pending_choice(decision: ModelDecision, pending: Sequence[PendingSender]) -> PendingSender | None:
    by_id = {item.feed.id: item for item in pending}
    if decision.newsletter_id in by_id:
        return by_id[decision.newsletter_id]
    if decision.newsletter_id is not None:
        # A number that is not a waiting sender: never let it fall through to
        # a guess, the model may have copied an episode's number.
        logger.warning("model chose newsletter_id %r, which was not offered", decision.newsletter_id)
        telemetry.annotate(failure="newsletter_not_offered")
        return None
    if decision.search_query and decision.search_query.strip():
        matches = [item for item in pending if matches_name(decision.search_query, item.feed.title)]
        if len(matches) == 1:
            return matches[0]
        return None
    return pending[0] if len(pending) == 1 else None


async def approve_newsletter(session: AsyncSession, user: User, feed_id: int) -> InterpretResult:
    """Follow a waiting sender. Shared with the streamed conversation."""
    feed = await newsletters.approve(session, user, feed_id)
    if feed is None:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="That newsletter is not waiting for your answer.",
        )
    count = await session.scalar(select(func.count(Episode.id)).where(Episode.feed_id == feed.id)) or 0
    return InterpretResult(
        action=Action.SUBSCRIBED,
        spoken_response=f"Following {feed.title}. Its {_spoken_count(count)} are in Latest."
        if count != 1
        else f"Following {feed.title}. Its message is in Latest.",
    )


async def block_newsletter(session: AsyncSession, user: User, feed_id: int) -> InterpretResult:
    """Refuse a waiting sender for good. Shared with the streamed conversation."""
    feed = await newsletters.owned_email_feed(session, user, feed_id)
    if feed is None or not await newsletters.block(session, user, feed_id):
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="That newsletter is not waiting for your answer.",
        )
    return InterpretResult(
        action=Action.UNSUBSCRIBED,
        spoken_response=f"Blocked {feed.title}. Anything it sends from now on is dropped.",
    )


async def newsletter_address(session: AsyncSession, user: User) -> InterpretResult:
    """Say the address she gives to newsletters, minting it if she has none."""
    try:
        address = await newsletters.inbound_address(session, user)
    except newsletters.NewslettersDisabledError:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="Newsletters by email are not set up on this server yet.",
        )
    return InterpretResult(
        action=Action.UNKNOWN,
        spoken_response=f"Your newsletter address is {spoken_address(address)}. It is also in Settings.",
    )


__all__ = ["spoken_address"]


async def sign_up_by_domain(
    session: AsyncSession, user: User, transcript: str, query: str | None
) -> InterpretResult | None:
    """When she named a site and it has no feed, ask it for its newsletter.

    Only a site she actually spoke: a name alone is not enough to know where
    to send her address, and guessing a domain from a name is how a stranger
    ends up with it.
    """
    domains = spoken_domains(f"{transcript} {query or ''}")
    if not domains:
        return None
    try:
        outcome = await newsletters.sign_up(session, user, f"https://{domains[0]}")
    except newsletters.NewslettersDisabledError:
        return None
    telemetry.annotate(newsletter_signup=outcome.status)
    return InterpretResult(action=Action.UNKNOWN, spoken_response=outcome.spoken_response)


def _spoken_count(count: int) -> str:
    return f"{count} message" if count == 1 else f"{count} messages"


_CLARIFY = "Sorry, I did not catch which episode you meant. Could you say that again?"
