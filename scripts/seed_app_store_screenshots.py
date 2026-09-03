#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Seed the local development account with stable, fictional screenshot data.

Run from ``backend/`` so uv uses the backend environment. The script refuses
anything except the development environment and rebuilds only the isolated
SQLite database configured by ``make app-store-fixtures``.
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime

from audioreader.auth.service import development_user
from audioreader.config import settings
from audioreader.db import SessionMaker, engine
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_PENDING,
    FEED_SOURCE_EMAIL,
    Base,
    Episode,
    Feed,
    PlaybackPosition,
    Subscription,
)

FIXTURE_PREFIX = "https://hearful.invalid/app-store/"


def feed(
    slug: str,
    title: str,
    description: str,
    colour: str,
    artwork_text: str,
    *,
    article_feed: bool = False,
) -> tuple[Feed, bool]:
    artwork = f"https://placehold.co/512x512/{colour}/FFFFFF.png?text={artwork_text}"
    return (
        Feed(
            url=f"{FIXTURE_PREFIX}{slug}.xml",
            title=title,
            description=description,
            image_url=artwork,
            site_url=f"{FIXTURE_PREFIX}{slug}",
            site_image_url=None,
            site_artwork_checked_at=datetime.now(UTC),
            last_polled_at=datetime.now(UTC),
            consecutive_failures=0,
            last_error=None,
            etag=None,
            last_modified=None,
        ),
        article_feed,
    )


def episode(
    source: Feed,
    number: int,
    title: str,
    summary: str,
    _age_days: int,
    *,
    article: bool = False,
    author: str = "Mara Bell",
    body: str | None = None,
) -> Episode:
    # A written piece carries its whole text so the app can say how long it
    # is in words, as it does for a real article once it has been read.
    text = body or summary
    return Episode(
        feed=source,
        guid=f"{source.url}#{number}",
        title=title,
        description=summary,
        content_html=paragraphs(text) if article else None,
        author=author if article else None,
        article_text=text if article else None,
        article_html=paragraphs(text) if article else None,
        audio_url=None if article else f"{FIXTURE_PREFIX}audio/{number}.mp3",
        duration_seconds=None if article else 2_700 + number * 240,
        # SQLite drops timezone information, while the production Postgres
        # database preserves it. A naive timestamp is not part of the API
        # contract and the iOS decoder rightly refuses it, so the isolated
        # fixture database leaves publication dates absent.
        published_at=None,
        link=f"{FIXTURE_PREFIX}episodes/{number}",
        image_url=source.image_url,
    )


def paragraphs(text: str) -> str:
    return "".join(f"<p>{part.strip()}</p>" for part in text.split("\n\n") if part.strip())


def newsletter(
    user_id: uuid.UUID,
    sender_key: str,
    title: str,
    sender_address: str,
    *,
    approval: str,
) -> Feed:
    """A sender that has written to her address, the way the inbound mail
    handler records one: no artwork, its address as the description, and
    the private email:// identifier in place of a feed URL."""
    return Feed(
        url=f"email://{user_id}/{sender_key}",
        title=title,
        source=FEED_SOURCE_EMAIL,
        owner_user_id=user_id,
        approval=approval,
        description=sender_address,
        image_url=None,
        site_url=None,
        site_image_url=None,
        site_artwork_checked_at=datetime.now(UTC),
        companion_checked_at=datetime.now(UTC),
        last_polled_at=None,
        consecutive_failures=0,
        last_error=None,
        etag=None,
        last_modified=None,
    )


# Issue bodies long enough to read as writing rather than a caption, so
# a newsletter's page and its rows show a plausible length in words.
SUNDAY_ESSAY_ATTENTION = """
Somewhere in the last decade, doing one thing at a time became a skill rather
than a default. We speak of it now the way earlier generations spoke of
handwriting: admirable, slightly old-fashioned, and a little suspicious in
anyone under forty.

Yet the people I know who seem happiest in their work all share it. They
answer messages at set hours. They read whole chapters. When they cook, the
phone is in another room. None of them describe this as discipline; they
describe it as relief.

This essay is about what attention feels like when we stop dividing it, and
about why the feeling is so easy to forget between one attempt and the next.
"""

SUNDAY_ESSAY_OBJECTS = """
My grandmother's kitchen scales sit on a shelf I pass every morning. They
have not weighed anything in twenty years. They are not beautiful, and they
are not rare; the same model turns up in every second charity shop in the
country. I would carry them out of a burning house.

We keep objects for what they remember on our behalf. A scale that once
measured flour for a cake I was too small to see over the counter for is
not a scale at all, but a small brass witness.

This week: the things we cannot throw away, and what they are really for.
"""

SLOW_LETTER_ISSUE_ONE = """
There is a particular kind of quiet that only arrives once the kettle has
boiled and the house has settled into itself. This week I have been trying to
notice it on purpose, which turns out to be harder than noticing it by
accident.

A friend who keeps bees told me that the hive sounds different in the hour
before rain. She cannot describe the difference, only that she hears it, and
that she has stopped checking the forecast. I have been thinking about what
else we know that way, and how rarely we trust it.

So this week's small suggestion: pick one ordinary sound in your day and
listen to it as if it were new. The lift arriving. The radiator ticking. The
gate. Then write to me about what you heard.
"""

SLOW_LETTER_ISSUE_TWO = """
The allotment was under water for most of March, and I had written the year
off. Then the beans came up anyway, all at once, as if they had been waiting
for me to stop looking.

I want to write this week about the things that happen while we are not
paying attention, and about the difference between neglect and patience,
which from the outside can look exactly alike. A garden knows which one it
is getting. So, I suspect, do most of the people in our lives.

Next week I will be away, so the letter will be a short one. Thank you, as
ever, for reading.
"""


async def seed() -> None:
    if settings.environment.casefold() != "development":
        raise SystemExit("refusing to seed screenshot fixtures outside the development environment")

    # This database is dedicated to screenshots and lives under ignored build
    # output. Rebuilding it is faster and more deterministic than trying to
    # make every historical production migration portable to SQLite.
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.drop_all)
        await connection.run_sync(Base.metadata.create_all)

    async with SessionMaker() as session:
        user = await development_user(session)
        user.ai_consent_version = 2
        user.ai_data_sharing_consented_at = datetime.now(UTC)
        user.ai_data_sharing_withdrawn_at = None
        # Her newsletter address. Invented words, so nothing sent to it
        # arrives anywhere, but the shape is the real one.
        user.inbound_token = "amber-finch-meadow"

        history, _ = feed(
            "history-hour",
            "The History Hour",
            "Stories from the past, told by the people who know them best.",
            "315A78",
            "HISTORY%0AHOUR",
        )
        science, _ = feed(
            "science-clearly",
            "Science, Clearly",
            "Big scientific ideas explained without the jargon.",
            "0A7D6C",
            "SCIENCE%0ACLEARLY",
        )
        essays, _ = feed(
            "sunday-essay",
            "The Sunday Essay",
            "Long-form writing about culture, technology and everyday life.",
            "8A4F7D",
            "SUNDAY%0AESSAY",
            article_feed=True,
        )
        # A newsletter she has followed, and one still waiting for her answer.
        slow_letter = newsletter(
            user.id,
            "theslowletter.example",
            "The Slow Letter",
            "iris@theslowletter.example",
            approval=APPROVAL_APPROVED,
        )
        ledger = newsletter(
            user.id,
            "morningledger.example",
            "The Morning Ledger",
            "briefing@morningledger.example",
            approval=APPROVAL_PENDING,
        )
        session.add_all((history, science, essays, slow_letter, ledger))
        await session.flush()

        episodes = [
            episode(
                history,
                1,
                "The map that changed how we see the world",
                "A forgotten atlas and the argument hidden inside it.",
                0,
            ),
            episode(
                science,
                2,
                "Why birds know when to leave",
                "The remarkable senses behind a journey across continents.",
                1,
            ),
            episode(
                essays,
                3,
                "In praise of doing one thing at a time",
                "What attention feels like when we stop dividing it.",
                2,
                article=True,
                body=SUNDAY_ESSAY_ATTENTION,
            ),
            episode(
                history,
                4,
                "A city beneath the fields",
                "Archaeologists piece together a place absent from every record.",
                4,
            ),
            episode(
                science,
                5,
                "The quiet life of a forest at night",
                "Listening to the signals that pass between roots and leaves.",
                6,
            ),
            episode(
                essays,
                6,
                "The objects we keep",
                "Why ordinary possessions can carry extraordinary memories.",
                8,
                article=True,
                body=SUNDAY_ESSAY_OBJECTS,
            ),
            episode(
                slow_letter,
                7,
                "Listening for the rain",
                "On the sounds we know without being able to say how.",
                1,
                article=True,
                author="Iris Marlow",
                body=SLOW_LETTER_ISSUE_ONE,
            ),
            episode(
                slow_letter,
                8,
                "What the beans knew",
                "Patience and neglect look alike from the outside.",
                7,
                article=True,
                author="Iris Marlow",
                body=SLOW_LETTER_ISSUE_TWO,
            ),
        ]
        # Without publication dates, the newest message is the last one
        # added; keep Thursday's after Wednesday's so it is the one named.
        waiting = [
            episode(
                ledger,
                9,
                "Wednesday: the quiet return of the fixed-rate bond",
                "Why the safest product on the shelf is suddenly popular again.",
                1,
                article=True,
                author="The Morning Ledger",
            ),
            episode(
                ledger,
                10,
                "Thursday: what the rate decision means for savers",
                "Three things to check before the end of the month.",
                0,
                article=True,
                author="The Morning Ledger",
            ),
        ]
        session.add_all(episodes + waiting)
        session.add_all(
            Subscription(user_id=user.id, feed_id=item.id) for item in (history, science, essays, slow_letter)
        )
        await session.flush()
        session.add(
            PlaybackPosition(
                user_id=user.id,
                episode_id=episodes[3].id,
                position_seconds=1_280,
                completed=False,
                dismissed=False,
            )
        )
        await session.commit()

    await engine.dispose()
    print("Seeded 4 fictional shows, 8 episodes and 1 waiting newsletter sender for the simulator account")


if __name__ == "__main__":
    asyncio.run(seed())
