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
from datetime import UTC, datetime

from audioreader.auth.service import development_user
from audioreader.config import settings
from audioreader.db import SessionMaker, engine
from audioreader.models import Base, Episode, Feed, PlaybackPosition, Subscription

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
) -> Episode:
    return Episode(
        feed=source,
        guid=f"{source.url}#{number}",
        title=title,
        description=summary,
        content_html=f"<p>{summary}</p>" if article else None,
        author="Mara Bell" if article else None,
        article_text=summary if article else None,
        article_html=f"<p>{summary}</p>" if article else None,
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
        session.add_all((history, science, essays))
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
            ),
        ]
        session.add_all(episodes)
        session.add_all(Subscription(user_id=user.id, feed_id=item.id) for item in (history, science, essays))
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
    print("Seeded 3 fictional shows and 6 episodes for the simulator account")


if __name__ == "__main__":
    asyncio.run(seed())
