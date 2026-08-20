"""add feed URL aliases

Revision ID: 6f7d2b1a9c40
Revises: 9b8e4d2f6a10
Create Date: 2026-08-20

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "6f7d2b1a9c40"
down_revision: str | Sequence[str] | None = "9b8e4d2f6a10"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "feed_aliases",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("url", sa.String(), nullable=False),
        sa.Column("feed_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(
            ["feed_id"],
            ["feeds.id"],
            name=op.f("fk_feed_aliases_feed_id_feeds"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_feed_aliases")),
        sa.UniqueConstraint("url", name=op.f("uq_feed_aliases_url")),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("feed_aliases")
