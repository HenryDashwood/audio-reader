"""add feed cache validators

Revision ID: 9b8e4d2f6a10
Revises: 4c2f7d8190aa
Create Date: 2026-08-20

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "9b8e4d2f6a10"
down_revision: str | Sequence[str] | None = "4c2f7d8190aa"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("feeds", sa.Column("etag", sa.Text(), nullable=True))
    op.add_column("feeds", sa.Column("last_modified", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("feeds", "last_modified")
    op.drop_column("feeds", "etag")
