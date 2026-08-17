"""add episode article_html

Revision ID: f5a91c3e0d72
Revises: b6d40f27ca19
Create Date: 2026-08-17

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "f5a91c3e0d72"
down_revision: str | Sequence[str] | None = "b6d40f27ca19"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # Filled lazily the first time an article is opened, like article_text
    # beside it; NULL means "not extracted yet", so nothing needs backfilling.
    # Rows that already have article_text get their HTML on the next read.
    op.add_column("episodes", sa.Column("article_html", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("episodes", "article_html")
