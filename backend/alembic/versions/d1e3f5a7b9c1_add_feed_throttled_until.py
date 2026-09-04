"""add feed throttled_until

Revision ID: d1e3f5a7b9c1
Revises: c0d2e4f6a8b0
Create Date: 2026-09-04
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d1e3f5a7b9c1"
down_revision: str | Sequence[str] | None = "c0d2e4f6a8b0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("feeds", sa.Column("throttled_until", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("feeds", "throttled_until")
