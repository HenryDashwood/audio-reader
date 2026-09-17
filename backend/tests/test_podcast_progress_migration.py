"""The progress receipt migration is reversible and does not rewrite library data."""

import importlib.util
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect

from audioreader.models import Base


def test_progress_receipt_migration():
    path = Path(__file__).parents[1] / "alembic/versions/ba739cf18a02_add_podcast_progress_receipts.py"
    spec = importlib.util.spec_from_file_location("progress_migration", path)
    assert spec is not None and spec.loader is not None
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = create_engine("sqlite://")
    with engine.begin() as connection:
        Base.metadata.create_all(
            connection, tables=[t for t in Base.metadata.sorted_tables if t.name != "podcast_progress_receipts"]
        )
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            inspector = inspect(connection)
            assert inspector.get_pk_constraint("podcast_progress_receipts")["constrained_columns"] == [
                "user_id",
                "request_id",
            ]
            assert {c["name"] for c in inspector.get_columns("podcast_progress_receipts")} == {
                "user_id",
                "request_id",
                "fingerprint",
                "accepted_revision",
                "created_at",
            }
            migration.downgrade()
            assert "podcast_progress_receipts" not in inspect(connection).get_table_names()
            assert "playback_positions" in inspect(connection).get_table_names()
    engine.dispose()
