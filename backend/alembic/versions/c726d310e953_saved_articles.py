"""Saved articles with private immutable content and versioned progress."""

import sqlalchemy as sa
from alembic import op

revision = "c726d310e953"
down_revision = "b615c209d842"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("episodes") as batch:
        batch.alter_column("feed_id", existing_type=sa.Integer(), nullable=True)
        batch.drop_constraint("fk_episodes_feed_id_feeds", type_="foreignkey")
        batch.create_foreign_key("fk_episodes_feed_id_feeds", "feeds", ["feed_id"], ["id"], ondelete="SET NULL")
        batch.add_column(sa.Column("canonical_url", sa.Text(), nullable=True))
        batch.create_unique_constraint("uq_episodes_canonical_url", ["canonical_url"])
    op.create_table(
        "article_contents",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("episode_id", sa.Integer(), sa.ForeignKey("episodes.id", ondelete="CASCADE"), nullable=False),
        sa.Column("owner_user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE")),
        sa.Column("title", sa.String(), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.Column("html", sa.Text(), nullable=False),
        sa.Column("digest", sa.String(), nullable=False),
        sa.Column("source", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_article_contents_episode_id", "article_contents", ["episode_id"])
    op.create_index("ix_article_contents_owner_user_id", "article_contents", ["owner_user_id"])
    op.create_table(
        "saved_articles",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("episode_id", sa.Integer(), sa.ForeignKey("episodes.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("content_id", sa.Integer(), sa.ForeignKey("article_contents.id", ondelete="SET NULL")),
        sa.Column("saved_at", sa.DateTime(timezone=True)),
        sa.Column("capture_error", sa.String()),
    )
    with op.batch_alter_table("playback_positions") as batch:
        batch.add_column(sa.Column("content_id", sa.Integer(), nullable=True))
        batch.create_foreign_key(
            "fk_playback_positions_content_id_article_contents",
            "article_contents",
            ["content_id"],
            ["id"],
            ondelete="SET NULL",
        )


def downgrade():
    # Cannot represent standalone articles in the old schema without data loss.
    if op.get_bind().scalar(sa.text("SELECT COUNT(*) FROM episodes WHERE feed_id IS NULL")):
        raise RuntimeError("Export or reconcile standalone articles before downgrading")
    with op.batch_alter_table("playback_positions") as batch:
        batch.drop_constraint("fk_playback_positions_content_id_article_contents", type_="foreignkey")
        batch.drop_column("content_id")
    op.drop_table("saved_articles")
    op.drop_table("article_contents")
    with op.batch_alter_table("episodes") as batch:
        batch.drop_constraint("uq_episodes_canonical_url", type_="unique")
        batch.drop_column("canonical_url")
        batch.drop_constraint("fk_episodes_feed_id_feeds", type_="foreignkey")
        batch.create_foreign_key("fk_episodes_feed_id_feeds", "feeds", ["feed_id"], ["id"], ondelete="CASCADE")
        batch.alter_column("feed_id", existing_type=sa.Integer(), nullable=False)
