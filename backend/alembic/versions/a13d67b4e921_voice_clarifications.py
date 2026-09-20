"""Add durable, expiring voice clarification choices."""

import sqlalchemy as sa
from alembic import op

revision = "a13d67b4e921"
down_revision = "e91bc428a713"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "voice_clarifications",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload", sa.Text(), nullable=False),
        sa.Column("consumed", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_index("ix_voice_clarifications_user_id", "voice_clarifications", ["user_id"])


def downgrade():
    op.drop_table("voice_clarifications")
