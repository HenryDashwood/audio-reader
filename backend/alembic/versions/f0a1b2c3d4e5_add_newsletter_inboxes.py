"""add newsletter inboxes

Revision ID: f0a1b2c3d4e5
Revises: 2e6a4c91b7d3
Create Date: 2026-09-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f0a1b2c3d4e5"
down_revision: str | Sequence[str] | None = "2e6a4c91b7d3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # The local part of her inbound address. Minted on first request rather
    # than here, so nobody gets an address they never asked for.
    op.add_column("users", sa.Column("inbound_token", sa.String(), nullable=True))
    op.create_unique_constraint(op.f("uq_users_inbound_token"), "users", ["inbound_token"])

    # Every existing feed is fetched from its URL; only newsletter feeds,
    # which arrive by email, are anything else.
    op.add_column("feeds", sa.Column("source", sa.String(), nullable=False, server_default="rss"))
    op.add_column("feeds", sa.Column("owner_user_id", sa.Uuid(), nullable=True))
    op.add_column("feeds", sa.Column("approval", sa.String(), nullable=True))
    op.create_foreign_key(
        op.f("fk_feeds_owner_user_id_users"),
        "feeds",
        "users",
        ["owner_user_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_index(op.f("ix_feeds_owner_user_id"), "feeds", ["owner_user_id"])

    op.create_table(
        "inbound_messages",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("feed_id", sa.Integer(), nullable=True),
        sa.Column("episode_id", sa.Integer(), nullable=True),
        sa.Column("message_id", sa.String(), nullable=False),
        sa.Column("raw", sa.LargeBinary(), nullable=True),
        sa.Column("raw_size", sa.Integer(), nullable=False),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_inbound_messages_user_id_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["feed_id"], ["feeds.id"], name=op.f("fk_inbound_messages_feed_id_feeds"), ondelete="SET NULL"
        ),
        sa.ForeignKeyConstraint(
            ["episode_id"],
            ["episodes.id"],
            name=op.f("fk_inbound_messages_episode_id_episodes"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_inbound_messages")),
    )
    op.create_index(op.f("ix_inbound_messages_received_at"), "inbound_messages", ["received_at"])


def downgrade() -> None:
    op.drop_index(op.f("ix_inbound_messages_received_at"), table_name="inbound_messages")
    op.drop_table("inbound_messages")
    op.drop_index(op.f("ix_feeds_owner_user_id"), table_name="feeds")
    op.drop_constraint(op.f("fk_feeds_owner_user_id_users"), "feeds", type_="foreignkey")
    op.drop_column("feeds", "approval")
    op.drop_column("feeds", "owner_user_id")
    op.drop_column("feeds", "source")
    op.drop_constraint(op.f("uq_users_inbound_token"), "users", type_="unique")
    op.drop_column("users", "inbound_token")
