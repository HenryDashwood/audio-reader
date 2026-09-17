"""Existing seconds and filing survive both directions of the additive migration."""

import importlib.util
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


def test_article_bookmark_migration_preserves_existing_positions():
    path = Path(__file__).parents[1] / "alembic/versions/c725fe930a16_add_article_bookmarks.py"
    spec = importlib.util.spec_from_file_location("article_progress_migration", path)
    assert spec is not None and spec.loader is not None
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    assert migration.down_revision == "ba739cf18a02"
    engine = create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(text("CREATE TABLE users (id CHAR(32) PRIMARY KEY)"))
        connection.execute(text("CREATE TABLE episodes (id INTEGER PRIMARY KEY)"))
        connection.execute(
            text(
                "CREATE TABLE playback_positions (user_id CHAR(32), episode_id INTEGER, "
                "position_seconds FLOAT, completed BOOLEAN, dismissed BOOLEAN, content_id INTEGER, "
                "updated_at DATETIME, PRIMARY KEY (user_id, episode_id))"
            )
        )
        connection.execute(text("INSERT INTO playback_positions VALUES ('owner', 7, 42.5, 1, 1, 9, '2026-09-17')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            row = connection.execute(text("SELECT * FROM playback_positions")).mappings().one()
            assert row["position_seconds"] == 42.5 and row["completed"] == 1 and row["dismissed"] == 1
            assert row["content_id"] == 9 and row["updated_at"] == "2026-09-17"
            assert row["article_text_version"] is None and row["article_offset_utf16"] is None
            assert inspect(connection).get_pk_constraint("article_progress_receipts")["constrained_columns"] == [
                "user_id",
                "request_id",
            ]
            migration.downgrade()
            assert "article_progress_receipts" not in inspect(connection).get_table_names()
            assert "article_text_version" not in {
                column["name"] for column in inspect(connection).get_columns("playback_positions")
            }
            assert connection.execute(text("SELECT position_seconds FROM playback_positions")).scalar_one() == 42.5
    engine.dispose()
