"""Store voice command outcomes for safe recovery after a disconnect."""

import sqlalchemy as sa
from alembic import op

revision = "a904b718cf32"
down_revision = "d1e3f5a7b9c1"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "voice_command_receipts",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("request_id", sa.String(), primary_key=True),
        sa.Column("fingerprint", sa.String(), nullable=False),
        sa.Column("cancel_requested", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("result_json", sa.Text(), nullable=True),
    )

    op.create_table(
        "voice_undo",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("payload", sa.Text(), nullable=False),
    )


def downgrade():
    op.drop_table("voice_undo")
    op.drop_table("voice_command_receipts")
