"""Feature defaults and per-account overrides, without account identifiers."""

import sqlalchemy as sa
from alembic import op

revision = "d8a31e6c92f4"
down_revision = "c53fa801d206"
branch_labels = None
depends_on = None


def upgrade():
    flags = op.create_table(
        "feature_flags",
        sa.Column("key", sa.String(), primary_key=True),
        sa.Column("description", sa.String(), nullable=False),
        sa.Column("default_enabled", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.create_table(
        "user_feature_flags",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("flag_key", sa.String(), sa.ForeignKey("feature_flags.key", ondelete="CASCADE"), primary_key=True),
        sa.Column("enabled", sa.Boolean(), nullable=False),
    )
    op.bulk_insert(
        flags,
        [
            {
                "key": "pdf_unlimited",
                "description": "Import PDFs without a paid subscription or monthly page allowance",
                "default_enabled": False,
            }
        ],
    )


def downgrade():
    op.drop_table("user_feature_flags")
    op.drop_table("feature_flags")
