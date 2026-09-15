"""Preserve newsletter addresses when authenticated accounts are combined.

Revision ID: e94d82c617ab
Revises: f83a2c04d917
"""

import sqlalchemy as sa
from alembic import op

revision = "e94d82c617ab"
down_revision = "f83a2c04d917"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "newsletter_inbox_aliases",
        sa.Column("token", sa.String(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("namespace_user_id", sa.Uuid(), nullable=False),
    )
    op.create_index("ix_newsletter_inbox_aliases_user_id", "newsletter_inbox_aliases", ["user_id"])


def downgrade() -> None:
    op.drop_table("newsletter_inbox_aliases")
