"""Let a listener combine several sources into one publication."""

import sqlalchemy as sa
from alembic import op

revision = "b615c209d842"
down_revision = "a904b718cf32"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("subscriptions") as batch:
        batch.add_column(sa.Column("group_feed_id", sa.Integer(), nullable=True))
        batch.create_foreign_key(
            "fk_subscriptions_group_feed_id_feeds", "feeds", ["group_feed_id"], ["id"], ondelete="SET NULL"
        )
        batch.create_index("ix_subscriptions_group_feed_id", ["group_feed_id"])


def downgrade():
    with op.batch_alter_table("subscriptions") as batch:
        batch.drop_index("ix_subscriptions_group_feed_id")
        batch.drop_constraint("fk_subscriptions_group_feed_id_feeds", type_="foreignkey")
        batch.drop_column("group_feed_id")
