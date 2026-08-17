"""add episode author

Revision ID: a1c73e9b40d5
Revises: f5a91c3e0d72
Create Date: 2026-08-17

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a1c73e9b40d5"
down_revision: str | Sequence[str] | None = "f5a91c3e0d72"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # NULL for every episode already stored: the byline is read off the feed
    # at ingest, so existing rows keep it only as new items arrive. Nothing to
    # backfill — an article with no author shows its date alone, which is
    # exactly what every article showed before this column existed.
    op.add_column("episodes", sa.Column("author", sa.String(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("episodes", "author")
