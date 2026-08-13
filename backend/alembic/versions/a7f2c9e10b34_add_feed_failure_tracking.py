"""add feed failure tracking

Revision ID: a7f2c9e10b34
Revises: c4d91a72b3ef
Create Date: 2026-08-13

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a7f2c9e10b34"
down_revision: str | Sequence[str] | None = "c4d91a72b3ef"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # server_default so existing rows land on 0 rather than NULL; the column
    # stays NOT NULL, which is what the model expects.
    op.add_column(
        "feeds",
        sa.Column("consecutive_failures", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column("feeds", sa.Column("last_error", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("feeds", "last_error")
    op.drop_column("feeds", "consecutive_failures")
