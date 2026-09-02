"""Print — and if asked, mint — one account's newsletter address.

The app mints the address itself the first time its owner opens the
newsletter screen. This is for the cases where that is not how it happens:
setting up an account for someone else, checking what address a newsletter
was given, or testing delivery before the screen exists.

Runs where the database is reachable — inside the deployment, or from a
laptop with the Railway connection string, the way the backup script is run:

    DATABASE_URL='<Railway public connection string>' \\
        uv run python scripts/newsletter_address.py her@example.com --domain magpieinbox.com

Without `--mint` it only reports. An account with no address yet gets one
only when `--mint` is given, since an address is a standing invitation to
send mail and should not appear as a side effect of looking. `--renew`
replaces an existing address with a fresh one; mail to the old address then
bounces, so every newsletter subscribed with it has to be told the new one.
"""

import argparse
import asyncio
import sys
from dataclasses import dataclass
from urllib.parse import parse_qs, urlsplit, urlunsplit

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

from audioreader.config import settings
from audioreader.models import User, UserIdentity
from audioreader.newsletters.service import new_inbound_token


def engine_for(url: str) -> AsyncEngine:
    """An engine for `url`, whether it points inside the deployment or outside.

    Same handling as refresh_feed_content.py: a public Railway URL carries
    `sslmode`, which asyncpg takes as a connect argument, not a query string.
    """
    parts = urlsplit(url)
    modes = parse_qs(parts.query).get("sslmode")
    if not modes:
        return create_async_engine(url)
    stripped = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    return create_async_engine(stripped, connect_args={"ssl": modes[0] != "disable"})


@dataclass(frozen=True)
class Outcome:
    found: bool
    address: str | None = None
    minted: bool = False


async def address_for(session: AsyncSession, email: str, domain: str, mint: bool, renew: bool = False) -> Outcome:
    """The address on the account signed in with `email`, minting one if asked.

    Matched against the account's own email and its sign-in identities: an
    Apple sign-in that hid the real address leaves a relay address on the
    identity and nothing on the account.
    """
    wanted = email.strip().lower()
    user = await session.scalar(
        select(User)
        .outerjoin(UserIdentity, UserIdentity.user_id == User.id)
        .where(or_(func.lower(User.email) == wanted, func.lower(UserIdentity.email) == wanted))
        .limit(1)
    )
    if user is None:
        return Outcome(found=False)
    if user.inbound_token and not renew:
        return Outcome(found=True, address=f"{user.inbound_token}@{domain}")
    if not mint:
        return Outcome(found=True)
    user.inbound_token = new_inbound_token()
    await session.commit()
    return Outcome(found=True, address=f"{user.inbound_token}@{domain}", minted=True)


async def run(email: str, domain: str, mint: bool, renew: bool) -> int:
    engine = engine_for(settings.database_url)
    try:
        maker = async_sessionmaker(engine, expire_on_commit=False)
        async with maker() as session:
            outcome = await address_for(session, email, domain, mint, renew=renew)
    finally:
        await engine.dispose()

    if not outcome.found:
        print(f"no account is signed in as {email}", file=sys.stderr)
        print("(an Apple sign-in that hid its email has a relay address instead; check the account's identities)")
        return 1
    if outcome.address is None:
        print(f"{email} has no newsletter address yet; rerun with --mint to give it one")
        return 2
    print(f"{email} -> {outcome.address}" + ("  (newly minted)" if outcome.minted else ""))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("email", help="the email the account signed in with")
    parser.add_argument(
        "--domain",
        default=settings.inbound_email_domain,
        help="the inbound domain to print the address under (default: AUDIOREADER_INBOUND_EMAIL_DOMAIN)",
    )
    parser.add_argument("--mint", action="store_true", help="create an address if the account has none")
    parser.add_argument(
        "--renew", action="store_true", help="replace the existing address with a new one (the old one stops working)"
    )
    arguments = parser.parse_args()
    if not arguments.domain:
        parser.error("no inbound domain: pass --domain or set AUDIOREADER_INBOUND_EMAIL_DOMAIN")
    return asyncio.run(run(arguments.email, arguments.domain, arguments.mint or arguments.renew, arguments.renew))


if __name__ == "__main__":
    raise SystemExit(main())
