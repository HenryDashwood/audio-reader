"""add newsletter unsubscribe headers

Revision ID: f6a8b0c2d4e6
Revises: e5f7a9b1c3d5
Create Date: 2026-09-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f6a8b0c2d4e6"
down_revision: str | Sequence[str] | None = "e5f7a9b1c3d5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("feeds", sa.Column("unsubscribe_url", sa.Text(), nullable=True))
    op.add_column("feeds", sa.Column("unsubscribe_post", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("feeds", "unsubscribe_post")
    op.drop_column("feeds", "unsubscribe_url")
