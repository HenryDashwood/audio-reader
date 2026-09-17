"""Remember accepted podcast progress requests for safe offline retry."""

import sqlalchemy as sa
from alembic import op

revision = "ba739cf18a02"
down_revision = "a19d6e7f2c84"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "podcast_progress_receipts",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("request_id", sa.String(), primary_key=True),
        sa.Column("fingerprint", sa.String(), nullable=False),
        sa.Column("accepted_revision", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("podcast_progress_receipts")
