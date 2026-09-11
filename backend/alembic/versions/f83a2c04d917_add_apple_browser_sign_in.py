"""Add Apple browser handoffs and retain each revocation grant's client ID.

Revision ID: f83a2c04d917
Revises: c726d310e953
"""

import sqlalchemy as sa
from alembic import op

revision = "f83a2c04d917"
down_revision = "c726d310e953"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("user_identities", sa.Column("refresh_token_client_id", sa.String(), nullable=True))
    op.create_table(
        "apple_browser_flows",
        sa.Column("state_hash", sa.String(), primary_key=True),
        sa.Column("challenge", sa.String(), nullable=False),
        sa.Column("nonce", sa.String(), nullable=False),
        sa.Column("return_scheme", sa.String(), nullable=False),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=True),
        sa.Column("session_hash", sa.String(), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("authorization_code", sa.Text(), nullable=True),
        sa.Column("outcome", sa.String(), nullable=True),
    )
    op.create_index("ix_apple_browser_flows_expires_at", "apple_browser_flows", ["expires_at"])


def downgrade() -> None:
    op.drop_table("apple_browser_flows")
    op.drop_column("user_identities", "refresh_token_client_id")
