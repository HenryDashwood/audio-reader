"""add episode article_text

Revision ID: c4d91a72b3ef
Revises: 8f3c1b20a4d7
Create Date: 2026-08-09

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c4d91a72b3ef"
down_revision: str | Sequence[str] | None = "8f3c1b20a4d7"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # Filled lazily the first time an article is read aloud; NULL means
    # "not extracted yet", so existing rows need no backfill.
    op.add_column("episodes", sa.Column("article_text", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("episodes", "article_text")
