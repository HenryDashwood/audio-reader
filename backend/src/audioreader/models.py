import uuid
from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, MetaData, Text, UniqueConstraint, Uuid, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

# Deterministic constraint names so Alembic autogenerate produces stable,
# reviewable diffs instead of Postgres-invented names.
NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)


class Feed(Base):
    __tablename__ = "feeds"

    id: Mapped[int] = mapped_column(primary_key=True)
    url: Mapped[str] = mapped_column(unique=True)
    title: Mapped[str]
    description: Mapped[str | None] = mapped_column(Text)
    image_url: Mapped[str | None]
    site_url: Mapped[str | None]
    last_polled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    episodes: Mapped[list["Episode"]] = relationship(
        back_populates="feed", cascade="all, delete-orphan"
    )


class Episode(Base):
    __tablename__ = "episodes"
    __table_args__ = (UniqueConstraint("feed_id", "guid"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    feed_id: Mapped[int] = mapped_column(ForeignKey("feeds.id", ondelete="CASCADE"))
    guid: Mapped[str]
    title: Mapped[str]
    description: Mapped[str | None] = mapped_column(Text)
    content_html: Mapped[str | None] = mapped_column(Text)
    audio_url: Mapped[str | None]
    duration_seconds: Mapped[int | None]
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    link: Mapped[str | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    feed: Mapped[Feed] = relationship(back_populates="episodes")


class User(Base):
    __tablename__ = "users"

    # sqlalchemy.Uuid works on both Postgres (native uuid) and the SQLite test
    # database (stored as text), unlike the postgresql dialect's UUID type.
    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    display_name: Mapped[str | None]
    email: Mapped[str | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    identities: Mapped[list["UserIdentity"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class UserIdentity(Base):
    """A sign-in provider's stable subject for a user.

    Separate from users so one account can later hold both an Apple and a
    Google identity when the Android app arrives.
    """

    __tablename__ = "user_identities"
    __table_args__ = (UniqueConstraint("provider", "provider_subject"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[str]  # "apple" today; "google" later
    provider_subject: Mapped[str]
    email: Mapped[str | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    user: Mapped[User] = relationship(back_populates="identities")


class AuthSession(Base):
    """An opaque bearer token, stored only as its SHA-256 hash."""

    __tablename__ = "sessions"

    token_hash: Mapped[str] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user: Mapped[User] = relationship()


class Subscription(Base):
    __tablename__ = "subscriptions"
    __table_args__ = (UniqueConstraint("user_id", "feed_id"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    feed_id: Mapped[int] = mapped_column(ForeignKey("feeds.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    feed: Mapped[Feed] = relationship()


class PlaybackPosition(Base):
    # Composite primary key: the natural key is (user, episode), and having no
    # surrogate id makes upsert a plain session.get-then-set.
    __tablename__ = "playback_positions"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    episode_id: Mapped[int] = mapped_column(
        ForeignKey("episodes.id", ondelete="CASCADE"), primary_key=True
    )
    position_seconds: Mapped[float]
    completed: Mapped[bool] = mapped_column(default=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


def utcnow() -> datetime:
    return datetime.now(UTC)
