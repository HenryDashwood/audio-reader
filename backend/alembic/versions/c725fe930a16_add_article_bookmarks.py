"""Store exact text bookmarks and their retry acknowledgements."""

import sqlalchemy as sa
from alembic import op

revision = "c725fe930a16"
down_revision = "ba739cf18a02"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("playback_positions", sa.Column("article_text_version", sa.String(), nullable=True))
    op.add_column("playback_positions", sa.Column("article_offset_utf16", sa.Integer(), nullable=True))
    op.create_table(
        "article_progress_receipts",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("request_id", sa.String(), primary_key=True),
        sa.Column("fingerprint", sa.String(), nullable=False),
        sa.Column("accepted_revision", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("article_progress_receipts")
    op.drop_column("playback_positions", "article_offset_utf16")
    op.drop_column("playback_positions", "article_text_version")
