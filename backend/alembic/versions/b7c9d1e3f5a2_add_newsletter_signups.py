"""add newsletter signups

Revision ID: b7c9d1e3f5a2
Revises: f0a1b2c3d4e5
Create Date: 2026-09-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b7c9d1e3f5a2"
down_revision: str | Sequence[str] | None = "f0a1b2c3d4e5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "newsletter_signups",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("site_url", sa.String(), nullable=False),
        sa.Column("publication", sa.String(), nullable=False),
        sa.Column("platform", sa.String(), nullable=False),
        sa.Column("expected_senders", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("feed_id", sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_newsletter_signups_user_id_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["feed_id"], ["feeds.id"], name=op.f("fk_newsletter_signups_feed_id_feeds"), ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_newsletter_signups")),
    )
    op.create_index(op.f("ix_newsletter_signups_user_id"), "newsletter_signups", ["user_id"])


def downgrade() -> None:
    op.drop_index(op.f("ix_newsletter_signups_user_id"), table_name="newsletter_signups")
    op.drop_table("newsletter_signups")
