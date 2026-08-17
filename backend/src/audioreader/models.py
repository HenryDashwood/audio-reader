import uuid
from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, MetaData, Text, UniqueConstraint, Uuid, event, false, func, or_
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

from audioreader.text import search_key

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
    # Only bumped by a successful poll, so it doubles as "how stale is this".
    last_polled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # A feed that has moved or died otherwise fails silently forever: the poll
    # pass logs a line nobody reads and the show simply stops getting episodes.
    # Counting failures makes that visible in the API, and to the listener.
    consecutive_failures: Mapped[int] = mapped_column(default=0, server_default="0")
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    episodes: Mapped[list["Episode"]] = relationship(back_populates="feed", cascade="all, delete-orphan")


class Episode(Base):
    __tablename__ = "episodes"
    __table_args__ = (UniqueConstraint("feed_id", "guid"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    feed_id: Mapped[int] = mapped_column(ForeignKey("feeds.id", ondelete="CASCADE"))
    guid: Mapped[str]
    title: Mapped[str]
    description: Mapped[str | None] = mapped_column(Text)
    content_html: Mapped[str | None] = mapped_column(Text)
    # Speech-ready text for an article, extracted lazily on first read and
    # cached here so replaying does not refetch the page.
    article_text: Mapped[str | None] = mapped_column(Text)
    # The same article as sanitised HTML, for reading on screen: headings,
    # emphasis, links and images, none of which survive the trip to speech.
    # Extracted alongside article_text, from the same fetch.
    article_html: Mapped[str | None] = mapped_column(Text)
    # Title and description folded down to plain lower-case words, so a spoken
    # phrase can be matched against a back catalogue that a recency window
    # never reaches. Written once at ingest: SQL has no portable way to strip
    # accents, and this runs on every spoken command. See text.search_key.
    search_text: Mapped[str | None] = mapped_column(Text)
    audio_url: Mapped[str | None]
    duration_seconds: Mapped[int | None]
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    link: Mapped[str | None]
    image_url: Mapped[str | None]
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

    identities: Mapped[list["UserIdentity"]] = relationship(back_populates="user", cascade="all, delete-orphan")


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
    # Kept solely so the grant can be revoked with the provider when she
    # deletes her account. Encrypted at rest (see secrets_store); null when the
    # deployment has no Apple key configured, or the exchange failed.
    refresh_token: Mapped[str | None] = mapped_column(Text)
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
    #
    # Despite the name, this is everything the listener has done with an
    # episode, not only where she got to: whether she considers it heard, and
    # whether she has asked not to be offered it again.
    __tablename__ = "playback_positions"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    episode_id: Mapped[int] = mapped_column(ForeignKey("episodes.id", ondelete="CASCADE"), primary_key=True)
    position_seconds: Mapped[float]
    completed: Mapped[bool] = mapped_column(default=False)
    #: She has asked for this one to go, without having heard it. Kept apart
    #: from `completed` deliberately: both take an episode out of the feed, but
    #: only one of them is a claim about what she has listened to, and a list
    #: that says she played something she never played is a list she cannot
    #: trust. Nothing else can tell them apart afterwards — an episode skipped
    #: and an episode finished look identical from a position alone.
    dismissed: Mapped[bool] = mapped_column(default=False, server_default=false())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


def utcnow() -> datetime:
    return datetime.now(UTC)


#: What the app can play: episode audio, or article text it reads aloud.
#: Mirrors the has_text fallback chain in feeds/articles.py.
PLAYABLE_EPISODE = or_(
    Episode.audio_url.is_not(None),
    Episode.article_text.is_not(None),
    Episode.content_html.is_not(None),
    Episode.link.is_not(None),
    Episode.description.is_not(None),
)


@event.listens_for(Episode, "before_insert")
@event.listens_for(Episode, "before_update")
def _fill_search_text(_mapper, _connection, episode: Episode) -> None:
    """Keep the folded search column in step with the title and description.

    Done here rather than at each call site so that no code path — poller,
    first ingest, a fixture, a backfill script — can insert an episode that
    the spoken search cannot see. An episode missing from that index is an
    episode she can never ask for by name.
    """
    episode.search_text = search_key(episode.title, episode.description)
