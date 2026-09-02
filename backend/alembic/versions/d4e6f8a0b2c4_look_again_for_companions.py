"""look again for newsletter companions

Revision ID: d4e6f8a0b2c4
Revises: c3d5e7f9a1b2
Create Date: 2026-09-02

The first sweep read only a sender's address out of a newsletter's key, and
most senders set a List-ID instead, so it found nothing to try and dated
every newsletter as checked. Those dates were blind looks; clearing them
lets the next sweep try again with the List-ID host.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d4e6f8a0b2c4"
down_revision: str | Sequence[str] | None = "c3d5e7f9a1b2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        sa.text("UPDATE feeds SET companion_checked_at = NULL WHERE source = 'email' AND companion_feed_id IS NULL")
    )


def downgrade() -> None:
    # The cleared dates were only ever "looked and found nothing"; there is
    # nothing to restore.
    pass
