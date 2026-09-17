"""The additive import schema preserves existing subscriptions and deletes private drafts with their owner."""

import importlib.util
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


def test_import_migration_and_account_cascade():
    path = Path(__file__).parents[1] / "alembic/versions/da18420c78b3_add_subscription_imports.py"
    spec = importlib.util.spec_from_file_location("import_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(text("PRAGMA foreign_keys=ON"))
        connection.execute(text("CREATE TABLE users (id CHAR(32) PRIMARY KEY)"))
        connection.execute(text("CREATE TABLE feeds (id INTEGER PRIMARY KEY)"))
        connection.execute(text("CREATE TABLE subscriptions (user_id CHAR(32), feed_id INTEGER)"))
        connection.execute(text("INSERT INTO users VALUES ('owner')"))
        connection.execute(text("INSERT INTO feeds VALUES (42)"))
        connection.execute(text("INSERT INTO subscriptions VALUES ('owner',42)"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(text("SELECT feed_id FROM subscriptions")).scalar_one() == 42
            connection.execute(
                text(
                    "INSERT INTO subscription_imports "
                    "(id,user_id,status,duplicates,folders,created_at,expires_at,updated_at) "
                    "VALUES ('job','owner','draft',0,0,'2026-09-17','2026-09-18','2026-09-17')"
                )
            )
            connection.execute(
                text(
                    "INSERT INTO subscription_import_items "
                    "(job_id,ordinal,title,host,url,status,selected,retryable,attempts,next_attempt_at) "
                    "VALUES ('job',0,'Title','example.org','https://example.org/feed','ready',0,0,0,'2026-09-17')"
                )
            )
            connection.execute(text("DELETE FROM users WHERE id='owner'"))
            assert connection.execute(text("SELECT count(*) FROM subscription_import_items")).scalar_one() == 0
            migration.downgrade()
            assert "subscription_imports" not in inspect(connection).get_table_names()
            assert connection.execute(text("SELECT feed_id FROM subscriptions")).scalar_one() == 42
    engine.dispose()
