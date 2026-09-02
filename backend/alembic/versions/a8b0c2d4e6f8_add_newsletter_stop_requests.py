"""add newsletter stop requests

Revision ID: a8b0c2d4e6f8
Revises: f6a8b0c2d4e6
Create Date: 2026-09-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a8b0c2d4e6f8"
down_revision: str | Sequence[str] | None = "f6a8b0c2d4e6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("feeds", sa.Column("stop_tried_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("feeds", sa.Column("stop_told_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("feeds", "stop_told_at")
    op.drop_column("feeds", "stop_tried_at")
