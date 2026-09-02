"""Users and opaque bearer sessions.

Tokens are random strings handed to the client exactly once; the database
only ever holds their SHA-256 hash, so a leaked database cannot be replayed
against the API.
"""

import hashlib
import secrets
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import secrets_store
from audioreader.auth.apple import AppleIdentity
from audioreader.config import settings
from audioreader.models import (
    AuthSession,
    PlaybackPosition,
    Subscription,
    User,
    UserIdentity,
    utcnow,
)
from audioreader.newsletters import service as newsletters

# The pre-auth deployment had exactly one implicit user; the migration created
# this user (same literal) and attached the then-existing feeds to it. Nothing
# hands it out any more — every sign-in gets a fresh user of its own — so it is
# kept only to name that row, and as the guard the tests assert against.
LEGACY_USER_ID = uuid.UUID("e1423896-70e0-4270-b809-982fc7730e21")

# Stable so the simulator sees the same library and listening positions across
# backend restarts. It is never reachable unless development authentication is
# explicitly enabled in the backend settings.
DEVELOPMENT_USER_ID = uuid.UUID("8e1e2490-364b-4c34-9d02-8f04a3d84fd1")


async def user_for_email(session: AsyncSession, email: str) -> User | None:
    """The account signed in with `email`, for operator tools.

    Matched against the account's own email and its sign-in identities: an
    Apple sign-in that hid the real address leaves a relay address on the
    identity and nothing on the account.
    """
    wanted = email.strip().lower()
    return await session.scalar(
        select(User)
        .outerjoin(UserIdentity, UserIdentity.user_id == User.id)
        .where(or_(func.lower(User.email) == wanted, func.lower(UserIdentity.email) == wanted))
        .limit(1)
    )


async def development_user(session: AsyncSession) -> User:
    """Return the local simulator account, creating it on first use."""
    user = await session.get(User, DEVELOPMENT_USER_ID)
    if user is None:
        user = User(id=DEVELOPMENT_USER_ID, display_name="Simulator Tester")
        session.add(user)
        await session.commit()
    return user


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def login(
    session: AsyncSession,
    identity: AppleIdentity,
    provider: str = "apple",
    refresh_token: str | None = None,
) -> tuple[User, str]:
    """Find or create the user for a verified identity; mint a session token.

    `refresh_token` is the provider's, kept only so the grant can be revoked
    when she deletes her account. It is stored encrypted, and a sign-in that
    did not produce one leaves whatever was there — an older token still
    revokes fine, and losing it in exchange for nothing would be worse.
    """
    existing = await session.scalar(
        select(UserIdentity).where(
            UserIdentity.provider == provider,
            UserIdentity.provider_subject == identity.subject,
        )
    )
    if existing is not None:
        user = await session.get_one(User, existing.user_id)
        if refresh_token:
            existing.refresh_token = secrets_store.encrypt(refresh_token)
    else:
        user = User()
        session.add(user)
        session.add(
            UserIdentity(
                user=user,
                provider=provider,
                provider_subject=identity.subject,
                email=identity.email,
                refresh_token=secrets_store.encrypt(refresh_token) if refresh_token else None,
            )
        )
        if user.email is None:
            user.email = identity.email

    raw_token = new_token()
    # Via the relationship, not user_id: a brand-new user has no id until flush.
    session.add(AuthSession(token_hash=hash_token(raw_token), user=user))
    await session.commit()
    return user, raw_token


def _as_aware(value: datetime) -> datetime:
    """Treat a naive timestamp as UTC.

    Rows written by `server_default=func.now()` come back naive from SQLite,
    and comparing those against an aware `utcnow()` raises rather than
    returning a wrong answer — which is the good news, but only if it never
    reaches production.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def is_expired(auth_session: AuthSession, now: datetime | None = None) -> bool:
    """Has this session gone unused for longer than the idle timeout?

    Measured from last use, falling back to creation for a token that was
    minted and never used again.
    """
    if settings.session_idle_timeout_days <= 0:
        return False
    now = now or utcnow()
    last_active = _as_aware(auth_session.last_used_at or auth_session.created_at)
    return now - last_active > timedelta(days=settings.session_idle_timeout_days)


async def user_for_token(session: AsyncSession, token: str) -> User | None:
    auth_session = await session.get(AuthSession, hash_token(token))
    if auth_session is None or auth_session.revoked_at is not None:
        return None
    if is_expired(auth_session):
        # Recorded, not just refused: a token that has aged out should stop
        # being a live row, so a stolen database is not a pile of keys waiting
        # for their owner to sign in again.
        auth_session.revoked_at = utcnow()
        await session.commit()
        return None
    auth_session.last_used_at = utcnow()
    await session.commit()
    return await session.get_one(User, auth_session.user_id)


async def revoke(session: AsyncSession, token: str) -> None:
    auth_session = await session.get(AuthSession, hash_token(token))
    if auth_session is not None and auth_session.revoked_at is None:
        auth_session.revoked_at = utcnow()
        await session.commit()


async def provider_refresh_tokens(session: AsyncSession, user: User) -> list[str]:
    """Her provider refresh tokens, decrypted, for revoking on the way out.

    Read before anything is deleted, since the rows holding them are about to
    go. Tokens that cannot be decrypted are simply absent from the result.
    """
    stored = await session.scalars(
        select(UserIdentity.refresh_token).where(
            UserIdentity.user_id == user.id, UserIdentity.refresh_token.is_not(None)
        )
    )
    return [token for token in (secrets_store.decrypt(value) for value in stored) if token]


async def delete_user(session: AsyncSession, user: User) -> None:
    """Erase an account and everything belonging to it.

    Rows are deleted explicitly rather than left to ON DELETE CASCADE: the
    cascades exist, but SQLite does not enforce foreign keys unless asked to,
    so relying on them would mean the tests prove less than they appear to.

    What deliberately survives is the shared catalog — feeds and episodes are
    not hers, other subscribers still need them. Everything that identifies
    her, or records what she listened to, goes.
    """
    for table in (PlaybackPosition, Subscription, AuthSession, UserIdentity):
        await session.execute(delete(table).where(table.user_id == user.id))
    # Her newsletter feeds and every issue in them are hers alone, unlike the
    # shared catalog, and go with her.
    await newsletters.delete_all_for_user(session, user)
    await session.execute(delete(User).where(User.id == user.id))
    await session.commit()
