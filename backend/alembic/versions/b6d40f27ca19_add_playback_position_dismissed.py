"""add playback_positions.dismissed

Revision ID: b6d40f27ca19
Revises: e2a5c81d4f60
Create Date: 2026-08-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b6d40f27ca19"
down_revision: str | Sequence[str] | None = "e2a5c81d4f60"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # Existing rows are positions from listening, so none of them is dismissed;
    # the server default fills them in without a backfill pass.
    op.add_column(
        "playback_positions",
        sa.Column("dismissed", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("playback_positions", "dismissed")
