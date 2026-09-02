"""add newsletter companion feeds

Revision ID: c3d5e7f9a1b2
Revises: b7c9d1e3f5a2
Create Date: 2026-09-02
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c3d5e7f9a1b2"
down_revision: str | Sequence[str] | None = "b7c9d1e3f5a2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("feeds", sa.Column("companion_feed_id", sa.Integer(), nullable=True))
    op.add_column("feeds", sa.Column("companion_checked_at", sa.DateTime(timezone=True), nullable=True))
    op.create_foreign_key(
        op.f("fk_feeds_companion_feed_id_feeds"), "feeds", "feeds", ["companion_feed_id"], ["id"], ondelete="SET NULL"
    )


def downgrade() -> None:
    op.drop_constraint(op.f("fk_feeds_companion_feed_id_feeds"), "feeds", type_="foreignkey")
    op.drop_column("feeds", "companion_checked_at")
    op.drop_column("feeds", "companion_feed_id")
