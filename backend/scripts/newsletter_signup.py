"""Sign one account's newsletter address up to a publication, from a laptop.

The app does this itself through `POST /newsletters/signups`. This is the
operator's route: setting up an account for someone else, or trying a
publication before the screen that offers it is on a phone. It does exactly
what the endpoint does, against whichever database it is pointed at:

    DATABASE_URL='<Railway public connection string>' \\
        uv run python scripts/newsletter_signup.py her@example.com https://example.substack.com \\
        --domain magpieinbox.com

The deployed backend then handles what the newsletter sends back — the
confirmation link, and the first issue — so the deployment must already be
running code that knows about signups.
"""

import argparse
import asyncio
import sys
from urllib.parse import parse_qs, urlsplit, urlunsplit

from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine

from audioreader.auth.service import user_for_email
from audioreader.config import settings
from audioreader.newsletters import service


def engine_for(url: str) -> AsyncEngine:
    """As in newsletter_address.py: a public Railway URL carries `sslmode`,
    which asyncpg takes as a connect argument rather than a query string."""
    parts = urlsplit(url)
    modes = parse_qs(parts.query).get("sslmode")
    if not modes:
        return create_async_engine(url)
    stripped = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    return create_async_engine(stripped, connect_args={"ssl": modes[0] != "disable"})


async def run(email: str, url: str, domain: str) -> int:
    engine = engine_for(settings.database_url)
    try:
        maker = async_sessionmaker(engine, expire_on_commit=False)
        async with maker() as session:
            user = await user_for_email(session, email)
            if user is None:
                print(f"no account is signed in as {email}", file=sys.stderr)
                return 1
            outcome = await service.sign_up(session, user, url)
    finally:
        await engine.dispose()

    print(f"{outcome.status}: {outcome.spoken_response}")
    if outcome.platform:
        print(f"platform: {outcome.platform}; publication: {outcome.publication}")
    return 0 if outcome.status == service.SIGNUP_SUBMITTED else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("email", help="the email the account signed in with")
    parser.add_argument("url", help="the publication's web page")
    parser.add_argument(
        "--domain",
        default=settings.inbound_email_domain,
        help="the inbound domain (default: AUDIOREADER_INBOUND_EMAIL_DOMAIN)",
    )
    arguments = parser.parse_args()
    if not arguments.domain:
        parser.error("no inbound domain: pass --domain or set AUDIOREADER_INBOUND_EMAIL_DOMAIN")
    # The service checks the same switch the endpoint does; from a laptop the
    # secret is irrelevant, so any value turns it on for this process.
    settings.inbound_email_domain = arguments.domain
    settings.inbound_email_secret = settings.inbound_email_secret or "operator"
    return asyncio.run(run(arguments.email, arguments.url, arguments.domain))


if __name__ == "__main__":
    raise SystemExit(main())
