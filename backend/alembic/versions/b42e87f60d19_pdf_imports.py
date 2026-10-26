"""Private PDF import receipts and consent."""

import sqlalchemy as sa
from alembic import op

revision = "b42e87f60d19"
down_revision = "a13d67b4e921"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("users", sa.Column("pdf_consent_version", sa.Integer(), nullable=True))
    op.create_table(
        "pdf_documents",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column(
            "episode_id", sa.Integer(), sa.ForeignKey("episodes.id", ondelete="CASCADE"), nullable=False, unique=True
        ),
        sa.Column("identity", sa.String(), nullable=False),
        sa.Column("source_url", sa.Text()),
        sa.Column("filename", sa.String(), nullable=False),
        sa.Column("original", sa.LargeBinary()),
        sa.Column("byte_count", sa.Integer(), nullable=False),
        sa.Column("page_count", sa.Integer()),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("request_id", sa.String()),
        sa.Column("lease_token", sa.String()),
        sa.Column("lease_until", sa.DateTime(timezone=True)),
        sa.Column("next_poll_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("error", sa.String()),
        sa.Column("raw_result", sa.LargeBinary()),
        sa.UniqueConstraint("user_id", "identity"),
    )
    op.create_index("ix_pdf_documents_user_id", "pdf_documents", ["user_id"])
    op.create_index("ix_pdf_documents_status", "pdf_documents", ["status"])
    op.create_table(
        "pdf_usage",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pages", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_pdf_usage_user_id", "pdf_usage", ["user_id"])
    op.create_table(
        "pdf_result_deletions",
        sa.Column("request_id", sa.String(), primary_key=True),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("pdf_result_deletions")
    op.drop_table("pdf_usage")
    op.drop_table("pdf_documents")
    op.drop_column("users", "pdf_consent_version")
