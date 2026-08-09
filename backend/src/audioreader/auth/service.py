"""Users and opaque bearer sessions.

Tokens are random strings handed to the client exactly once; the database
only ever holds their SHA-256 hash, so a leaked database cannot be replayed
against the API.
"""

import hashlib
import secrets
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth.apple import AppleIdentity
from audioreader.models import AuthSession, User, UserIdentity, utcnow

# The pre-auth deployment had exactly one implicit user; the migration created
# this user (same literal) and attached the then-existing feeds to it. It only
# serves the require_auth=false fallback now — real sign-ins always get a
# fresh user of their own.
LEGACY_USER_ID = uuid.UUID("e1423896-70e0-4270-b809-982fc7730e21")


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def login(
    session: AsyncSession, identity: AppleIdentity, provider: str = "apple"
) -> tuple[User, str]:
    """Find or create the user for a verified identity; mint a session token."""
    existing = await session.scalar(
        select(UserIdentity).where(
            UserIdentity.provider == provider,
            UserIdentity.provider_subject == identity.subject,
        )
    )
    if existing is not None:
        user = await session.get_one(User, existing.user_id)
    else:
        user = User()
        session.add(user)
        session.add(
            UserIdentity(
                user=user,
                provider=provider,
                provider_subject=identity.subject,
                email=identity.email,
            )
        )
        if user.email is None:
            user.email = identity.email

    raw_token = new_token()
    # Via the relationship, not user_id: a brand-new user has no id until flush.
    session.add(AuthSession(token_hash=hash_token(raw_token), user=user))
    await session.commit()
    return user, raw_token


async def user_for_token(session: AsyncSession, token: str) -> User | None:
    auth_session = await session.get(AuthSession, hash_token(token))
    if auth_session is None or auth_session.revoked_at is not None:
        return None
    auth_session.last_used_at = utcnow()
    await session.commit()
    return await session.get_one(User, auth_session.user_id)


async def revoke(session: AsyncSession, token: str) -> None:
    auth_session = await session.get(AuthSession, hash_token(token))
    if auth_session is not None and auth_session.revoked_at is None:
        auth_session.revoked_at = utcnow()
        await session.commit()
