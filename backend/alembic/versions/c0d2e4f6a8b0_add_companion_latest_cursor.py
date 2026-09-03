"""add newsletter companion latest cursor

Revision ID: c0d2e4f6a8b0
Revises: b9c1d3e5f7a9
Create Date: 2026-09-03
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c0d2e4f6a8b0"
down_revision: str | Sequence[str] | None = "b9c1d3e5f7a9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("feeds", sa.Column("companion_latest_after_episode_id", sa.Integer(), nullable=True))
    # Newsletters already linked: their companion's archive is the archive.
    op.execute(
        sa.text(
            "UPDATE feeds SET companion_latest_after_episode_id = "
            "(SELECT MAX(episodes.id) FROM episodes WHERE episodes.feed_id = feeds.companion_feed_id) "
            "WHERE feeds.companion_feed_id IS NOT NULL"
        )
    )


def downgrade() -> None:
    op.drop_column("feeds", "companion_latest_after_episode_id")
