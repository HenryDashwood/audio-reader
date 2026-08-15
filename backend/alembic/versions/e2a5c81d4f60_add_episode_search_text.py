"""add episode search_text

Revision ID: e2a5c81d4f60
Revises: d3b81f60c592
Create Date: 2026-08-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

from audioreader.text import search_key

# revision identifiers, used by Alembic.
revision: str = "e2a5c81d4f60"
down_revision: str | Sequence[str] | None = "d3b81f60c592"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

#: Small enough that a long-neglected database is a series of short
#: transactions rather than one that holds the table for a minute.
BATCH = 500


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("episodes", sa.Column("search_text", sa.Text(), nullable=True))

    # Backfilled in Python rather than SQL: folding accents and ligatures
    # ("Æthelstan" -> "aethelstan") is what makes the column worth having, and
    # neither Postgres nor SQLite can do it portably. Rows left NULL by an
    # interrupted backfill are still findable by title — they just cannot be
    # reached by the spoken spelling until this is rerun.
    connection = op.get_bind()
    episodes = sa.table(
        "episodes",
        sa.column("id", sa.Integer),
        sa.column("title", sa.String),
        sa.column("description", sa.Text),
        sa.column("search_text", sa.Text),
    )
    last_id = 0
    while True:
        rows = connection.execute(
            sa.select(episodes.c.id, episodes.c.title, episodes.c.description)
            .where(episodes.c.id > last_id)
            .order_by(episodes.c.id)
            .limit(BATCH)
        ).all()
        if not rows:
            break
        for row in rows:
            connection.execute(
                episodes.update()
                .where(episodes.c.id == row.id)
                .values(search_text=search_key(row.title, row.description))
            )
        last_id = rows[-1].id


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("episodes", "search_text")
