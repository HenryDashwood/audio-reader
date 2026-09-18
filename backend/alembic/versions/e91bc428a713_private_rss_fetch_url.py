"""Keep personal RSS addresses separate from shared feed identities."""

import sqlalchemy as sa
from alembic import op

revision = "e91bc428a713"
down_revision = "da18420c78b3"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("feeds", sa.Column("private_fetch_url", sa.Text(), nullable=True))


def downgrade():
    op.drop_column("feeds", "private_fetch_url")
