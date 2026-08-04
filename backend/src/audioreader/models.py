from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, MetaData, Text, UniqueConstraint, func
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


def utcnow() -> datetime:
    return datetime.now(UTC)
