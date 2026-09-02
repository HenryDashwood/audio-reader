"""add newsletter forwarded flag

Revision ID: b9c1d3e5f7a9
Revises: a8b0c2d4e6f8
Create Date: 2026-09-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b9c1d3e5f7a9"
down_revision: str | Sequence[str] | None = "a8b0c2d4e6f8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("feeds", sa.Column("forwarded", sa.Boolean(), nullable=False, server_default=sa.false()))


def downgrade() -> None:
    op.drop_column("feeds", "forwarded")
