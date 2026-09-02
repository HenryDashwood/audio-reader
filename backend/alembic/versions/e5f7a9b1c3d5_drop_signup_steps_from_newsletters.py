"""drop sign-up steps filed as newsletter issues

Revision ID: e5f7a9b1c3d5
Revises: d4e6f8a0b2c4
Create Date: 2026-09-02

A verification code or sign-in email used to be filed as an issue of the
newsletter it came from. It is not one, and is no longer filed; the ones
already filed go. Postgres only — the pattern is the backend's own, and
the test database never held any.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e5f7a9b1c3d5"
down_revision: str | Sequence[str] | None = "d4e6f8a0b2c4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# The backend's _TRANSACTIONAL pattern in Postgres ARE spelling: no (?:...)
# groups, and "sign in to" only as the subject's opening.
_STEP = (
    "verification code|verify your email|confirm your (email|address|subscription)"
    "|^\\s*(please )?(sign|log)[- ]in to( |$)|(sign|log)[- ]in link|login link|magic link|one[- ]time code"
)


def upgrade() -> None:
    if op.get_bind().dialect.name != "postgresql":
        return
    op.execute(
        sa.text(
            "UPDATE inbound_messages SET episode_id = NULL WHERE episode_id IN ("
            "SELECT episodes.id FROM episodes JOIN feeds ON feeds.id = episodes.feed_id "
            "WHERE feeds.source = 'email' AND episodes.title ~* :step)"
        ).bindparams(step=_STEP)
    )
    op.execute(
        sa.text(
            "DELETE FROM episodes USING feeds WHERE feeds.id = episodes.feed_id "
            "AND feeds.source = 'email' AND episodes.title ~* :step"
        ).bindparams(step=_STEP)
    )


def downgrade() -> None:
    # The rows were never issues; there is nothing to put back.
    pass
