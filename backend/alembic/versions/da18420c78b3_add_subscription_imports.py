"""Durable OPML reviews, item receipts, and a deployment-wide import lease."""

import sqlalchemy as sa
from alembic import op

revision = "da18420c78b3"
down_revision = "c725fe930a16"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "subscription_imports",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("active_user", sa.String(), unique=True),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("request_id", sa.String()),
        sa.Column("fingerprint", sa.String()),
        sa.Column("retry_of", sa.String()),
        sa.Column("duplicates", sa.Integer(), nullable=False),
        sa.Column("folders", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "request_id"),
    )
    op.create_index("ix_subscription_imports_user_id", "subscription_imports", ["user_id"])
    op.create_index("ix_subscription_imports_expires_at", "subscription_imports", ["expires_at"])
    op.create_table(
        "subscription_import_items",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("job_id", sa.String(), sa.ForeignKey("subscription_imports.id", ondelete="CASCADE"), nullable=False),
        sa.Column("ordinal", sa.Integer(), nullable=False),
        sa.Column("title", sa.String(), nullable=False),
        sa.Column("host", sa.String(), nullable=False),
        sa.Column("url", sa.Text()),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("message", sa.String()),
        sa.Column("selected", sa.Boolean(), nullable=False),
        sa.Column("retryable", sa.Boolean(), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("feed_id", sa.Integer(), sa.ForeignKey("feeds.id", ondelete="SET NULL")),
    )
    op.create_index("ix_subscription_import_items_job_id", "subscription_import_items", ["job_id"])
    op.create_table(
        "subscription_import_lease",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("token", sa.String(), nullable=False),
        sa.Column("until", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("subscription_import_lease")
    op.drop_table("subscription_import_items")
    op.drop_table("subscription_imports")
