"""Exercise the new migration without replaying PostgreSQL-only historical SQL."""

import importlib.util
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect

from audioreader.models import Base


def test_voice_migration_upgrades_and_downgrades_without_touching_library():
    path = Path(__file__).parents[1] / "alembic/versions/a904b718cf32_add_voice_command_receipts.py"
    spec = importlib.util.spec_from_file_location("voice_migration", path)
    assert spec is not None and spec.loader is not None
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = create_engine("sqlite://")
    added = {"voice_command_receipts", "voice_undo"}
    with engine.begin() as connection:
        Base.metadata.create_all(
            connection, tables=[table for table in Base.metadata.sorted_tables if table.name not in added]
        )
        context = MigrationContext.configure(connection, opts={"target_metadata": Base.metadata})
        with Operations.context(context):
            migration.upgrade()
            inspector = inspect(connection)
            assert added <= set(inspector.get_table_names())
            assert inspector.get_pk_constraint("voice_command_receipts")["constrained_columns"] == [
                "user_id",
                "request_id",
            ]
            assert {item["name"] for item in inspector.get_columns("voice_command_receipts")} == {
                "user_id",
                "request_id",
                "fingerprint",
                "cancel_requested",
                "created_at",
                "result_json",
            }
            migration.downgrade()
            assert not added & set(inspect(connection).get_table_names())
            assert "episodes" in inspect(connection).get_table_names()
    engine.dispose()
