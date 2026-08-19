"""add AI-sharing consent and a severable telemetry id

Revision ID: 4c2f7d8190aa
Revises: a1c73e9b40d5
Create Date: 2026-08-19
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "4c2f7d8190aa"
down_revision: str | Sequence[str] | None = "a1c73e9b40d5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("telemetry_id", sa.Uuid(), nullable=True))
    # PostgreSQL 17 provides gen_random_uuid() without an extension. The
    # application default covers every row created after this migration.
    op.execute("UPDATE users SET telemetry_id = gen_random_uuid() WHERE telemetry_id IS NULL")
    op.alter_column("users", "telemetry_id", nullable=False)
    op.create_unique_constraint("uq_users_telemetry_id", "users", ["telemetry_id"])
    op.add_column("users", sa.Column("ai_consent_version", sa.Integer(), nullable=True))
    op.add_column(
        "users",
        sa.Column("ai_data_sharing_consented_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "users",
        sa.Column("ai_data_sharing_withdrawn_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("users", "ai_data_sharing_withdrawn_at")
    op.drop_column("users", "ai_data_sharing_consented_at")
    op.drop_column("users", "ai_consent_version")
    op.drop_constraint("uq_users_telemetry_id", "users", type_="unique")
    op.drop_column("users", "telemetry_id")
