"""RevenueCat identities and persistent monthly PDF allowance accounting."""

import sqlalchemy as sa
from alembic import op

revision = "c53fa801d206"
down_revision = "b42e87f60d19"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "billing_customers",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", sa.String()),
        sa.Column("store", sa.String()),
        sa.Column("period_start", sa.DateTime(timezone=True)),
        sa.Column("period_end", sa.DateTime(timezone=True)),
        sa.Column("access_until", sa.DateTime(timezone=True)),
        sa.Column("checked_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_billing_customers_user_id", "billing_customers", ["user_id"])
    op.create_table(
        "pdf_page_usage",
        sa.Column("document_id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pages", sa.Integer(), nullable=False),
        sa.Column("state", sa.String(), nullable=False),
        sa.Column("period_start", sa.DateTime(timezone=True), nullable=False),
        sa.Column("period_end", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_pdf_page_usage_user_id", "pdf_page_usage", ["user_id"])


def downgrade():
    op.drop_table("pdf_page_usage")
    op.drop_table("billing_customers")
