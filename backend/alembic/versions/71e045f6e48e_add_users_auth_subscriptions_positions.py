"""add users, auth sessions, subscriptions and playback positions

Revision ID: 71e045f6e48e
Revises: 75d7069c6758
Create Date: 2026-08-08

"""

import uuid
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "71e045f6e48e"
down_revision: str | Sequence[str] | None = "75d7069c6758"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# The one implicit user of the pre-auth deployment. Must match
# audioreader.auth.service.LEGACY_USER_ID; the first Apple sign-in claims it.
LEGACY_USER_ID = "e1423896-70e0-4270-b809-982fc7730e21"


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("display_name", sa.String(), nullable=True),
        sa.Column("email", sa.String(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
    )
    op.create_table(
        "user_identities",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("provider", sa.String(), nullable=False),
        sa.Column("provider_subject", sa.String(), nullable=False),
        sa.Column("email", sa.String(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_user_identities_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_user_identities")),
        sa.UniqueConstraint(
            "provider",
            "provider_subject",
            name=op.f("uq_user_identities_provider_provider_subject"),
        ),
    )
    op.create_table(
        "sessions",
        sa.Column("token_hash", sa.String(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_sessions_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("token_hash", name=op.f("pk_sessions")),
    )
    op.create_table(
        "subscriptions",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("feed_id", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["feed_id"],
            ["feeds.id"],
            name=op.f("fk_subscriptions_feed_id_feeds"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_subscriptions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_subscriptions")),
        sa.UniqueConstraint("user_id", "feed_id", name=op.f("uq_subscriptions_user_id_feed_id")),
    )
    op.create_table(
        "playback_positions",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("episode_id", sa.Integer(), nullable=False),
        sa.Column("position_seconds", sa.Float(), nullable=False),
        sa.Column("completed", sa.Boolean(), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["episode_id"],
            ["episodes.id"],
            name=op.f("fk_playback_positions_episode_id_episodes"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_playback_positions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", "episode_id", name=op.f("pk_playback_positions")),
    )

    # Backfill: everything that exists today belongs to the one pre-auth user.
    # Typed bindparam so the driver gets a real uuid, not a bare string.
    legacy_id = sa.bindparam("id", value=uuid.UUID(LEGACY_USER_ID), type_=sa.Uuid())
    op.execute(
        sa.text("INSERT INTO users (id, display_name) VALUES (:id, 'Library owner')").bindparams(
            legacy_id
        )
    )
    op.execute(
        sa.text(
            "INSERT INTO subscriptions (user_id, feed_id) SELECT :id, id FROM feeds"
        ).bindparams(legacy_id)
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("playback_positions")
    op.drop_table("subscriptions")
    op.drop_table("sessions")
    op.drop_table("user_identities")
    op.drop_table("users")
