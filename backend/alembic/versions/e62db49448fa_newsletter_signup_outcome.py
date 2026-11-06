"""Remember newsletter submissions awaiting a publisher response."""

import sqlalchemy as sa
from alembic import op

revision = "e62db49448fa"
down_revision = "d8a31e6c92f4"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "newsletter_signups", sa.Column("awaiting_response", sa.Boolean(), nullable=False, server_default=sa.false())
    )


def downgrade():
    op.drop_column("newsletter_signups", "awaiting_response")
