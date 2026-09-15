"""Keep captured article artwork with the private content snapshot."""

import sqlalchemy as sa
from alembic import op

revision = "a19d6e7f2c84"
down_revision = "e94d82c617ab"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("article_contents", sa.Column("image_url", sa.String(), nullable=True))


def downgrade():
    with op.batch_alter_table("article_contents") as batch:
        batch.drop_column("image_url")
