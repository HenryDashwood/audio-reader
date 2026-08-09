"""add episode image_url

Revision ID: 8f3c1b20a4d7
Revises: 71e045f6e48e
Create Date: 2026-08-09

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "8f3c1b20a4d7"
down_revision: str | Sequence[str] | None = "71e045f6e48e"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # Existing rows stay NULL; the API falls back to the show's artwork, and
    # per-episode art arrives naturally as new episodes are ingested.
    op.add_column("episodes", sa.Column("image_url", sa.String(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("episodes", "image_url")
