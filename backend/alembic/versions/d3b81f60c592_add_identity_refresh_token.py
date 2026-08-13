"""add identity refresh token

Revision ID: d3b81f60c592
Revises: a7f2c9e10b34
Create Date: 2026-08-13

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d3b81f60c592"
down_revision: str | Sequence[str] | None = "a7f2c9e10b34"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    # Nullable with no backfill: existing users signed in before the app began
    # sending an authorization code, so there is no token to be had for them.
    # They simply cannot be revoked with Apple until they next sign in.
    op.add_column("user_identities", sa.Column("refresh_token", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("user_identities", "refresh_token")
