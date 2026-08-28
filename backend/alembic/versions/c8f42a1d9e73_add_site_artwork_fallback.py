"""add site artwork fallback

Revision ID: c8f42a1d9e73
Revises: 6f7d2b1a9c40
Create Date: 2026-08-28

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c8f42a1d9e73"
down_revision: str | Sequence[str] | None = "6f7d2b1a9c40"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("feeds", sa.Column("site_image_url", sa.String(), nullable=True))
    op.add_column("feeds", sa.Column("site_artwork_checked_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("feeds", "site_artwork_checked_at")
    op.drop_column("feeds", "site_image_url")
