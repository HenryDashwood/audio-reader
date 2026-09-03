"""Undo a newsletter's wrong companion, and reopen a signup that claimed
the wrong mail.

A signup made before senders were judged strictly could take a forwarded
issue from another publication as its reply, follow that sender, and lend
it the signup's site as a companion. This puts the pieces back: the
newsletter loses the companion (the next sweep looks again, from its own
sender), takes back its sender's name, and the signup waits once more for
the publication it was made for.

    DATABASE_URL='<Railway public connection string>' \\
        uv run python scripts/newsletter_repair.py her@example.com list
    ... unlink --feed 123
    ... reopen-signup --publication "Understanding AI"
"""

import argparse
import asyncio
import os
import sys
from urllib.parse import parse_qs, urlsplit, urlunsplit

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

from audioreader.auth.service import user_for_email
from audioreader.models import FEED_SOURCE_EMAIL, Episode, Feed, NewsletterSignup, User
from audioreader.newsletters.signup import site_domain


def engine_for(url: str) -> AsyncEngine:
    parts = urlsplit(url)
    modes = parse_qs(parts.query).get("sslmode")
    if not modes:
        return create_async_engine(url)
    stripped = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    return create_async_engine(stripped, connect_args={"ssl": modes[0] != "disable"})


async def newsletters_of(session: AsyncSession, user: User) -> list[tuple[Feed, Feed | None, str | None]]:
    """Her newsletters, each with its companion and the name its sender used."""
    feeds = (
        await session.scalars(
            select(Feed).where(Feed.owner_user_id == user.id, Feed.source == FEED_SOURCE_EMAIL).order_by(Feed.id)
        )
    ).all()
    rows = []
    for feed in feeds:
        companion = await session.get(Feed, feed.companion_feed_id) if feed.companion_feed_id else None
        author = await session.scalar(
            select(Episode.author).where(Episode.feed_id == feed.id).order_by(Episode.id.desc()).limit(1)
        )
        rows.append((feed, companion, author))
    return rows


async def unlink(session: AsyncSession, feed: Feed) -> None:
    """Take the companion away and give the newsletter its sender's name back."""
    author = await session.scalar(
        select(Episode.author).where(Episode.feed_id == feed.id).order_by(Episode.id.desc()).limit(1)
    )
    feed.companion_feed_id = None
    feed.companion_checked_at = None
    feed.companion_latest_after_episode_id = None
    feed.image_url = feed.site_image_url = feed.site_url = feed.description = None
    if author:
        feed.title = author
    await session.commit()


async def reopen_signup(session: AsyncSession, signup: NewsletterSignup) -> None:
    """Wait again for the publication it was made for, expecting only its site."""
    signup.completed_at = None
    signup.feed_id = None
    signup.expected_senders = site_domain(signup.site_url)
    await session.commit()


async def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("email")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    commands.add_parser("unlink").add_argument("--feed", type=int, required=True)
    commands.add_parser("reopen-signup").add_argument("--publication", required=True)
    args = parser.parse_args(argv)

    url = os.environ.get("DATABASE_URL")
    if not url:
        print("set DATABASE_URL", file=sys.stderr)
        return 2
    if url.startswith("postgresql://"):
        url = "postgresql+asyncpg://" + url.removeprefix("postgresql://")
    engine = engine_for(url)
    try:
        async with async_sessionmaker(engine, expire_on_commit=False)() as session:
            user = await user_for_email(session, args.email)
            if user is None:
                print(f"no account for {args.email}", file=sys.stderr)
                return 1
            if args.command == "list":
                for feed, companion, author in await newsletters_of(session, user):
                    linked = f" -> [{companion.id}] {companion.title!r} {companion.url}" if companion else ""
                    print(f"[{feed.id}] {feed.title!r} {feed.approval} sender={author!r}{linked}")
                for signup in await session.scalars(
                    select(NewsletterSignup).where(NewsletterSignup.user_id == user.id).order_by(NewsletterSignup.id)
                ):
                    print(
                        f"signup [{signup.id}] {signup.publication!r} site={signup.site_url} "
                        f"expects={signup.expected_senders!r} confirmed={signup.confirmed_at} "
                        f"completed={signup.completed_at} feed={signup.feed_id}"
                    )
            elif args.command == "unlink":
                feed = await session.get(Feed, args.feed)
                if feed is None or feed.owner_user_id != user.id or feed.source != FEED_SOURCE_EMAIL:
                    print("not one of her newsletters", file=sys.stderr)
                    return 1
                await unlink(session, feed)
                print(f"[{feed.id}] is {feed.title!r} again, with no companion; the next sweep looks afresh")
            else:
                signup = await session.scalar(
                    select(NewsletterSignup)
                    .where(NewsletterSignup.user_id == user.id, NewsletterSignup.publication == args.publication)
                    .order_by(NewsletterSignup.id.desc())
                )
                if signup is None:
                    print("no such signup", file=sys.stderr)
                    return 1
                await reopen_signup(session, signup)
                print(f"signup [{signup.id}] waits again for {signup.publication!r} from {signup.expected_senders}")
    finally:
        await engine.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1:])))
