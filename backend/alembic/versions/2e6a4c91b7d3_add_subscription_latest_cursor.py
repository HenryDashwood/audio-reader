"""add subscription Latest cursor

Revision ID: 2e6a4c91b7d3
Revises: c8f42a1d9e73
Create Date: 2026-08-28
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "2e6a4c91b7d3"
down_revision: str | Sequence[str] | None = "c8f42a1d9e73"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Deliberately nullable: existing subscriptions retain their current
    # Latest list until the listener clears it. New subscriptions always get
    # a cursor from the application.
    op.add_column(
        "subscriptions",
        sa.Column("latest_after_episode_id", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("subscriptions", "latest_after_episode_id")
