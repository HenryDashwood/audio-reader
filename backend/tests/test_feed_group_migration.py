"""Existing subscriptions survive the nullable grouping migration."""

import importlib.util
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import Column, ForeignKey, Integer, MetaData, Table, UniqueConstraint, create_engine, inspect, text


def test_group_migration_preserves_existing_subscriptions():
    path = Path(__file__).parents[1] / "alembic/versions/b615c209d842_add_subscription_groups.py"
    spec = importlib.util.spec_from_file_location("group_migration", path)
    assert spec is not None and spec.loader is not None
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    metadata = MetaData()
    Table("feeds", metadata, Column("id", Integer, primary_key=True))
    Table(
        "subscriptions",
        metadata,
        Column("id", Integer, primary_key=True),
        Column("feed_id", Integer, ForeignKey("feeds.id")),
        Column("user_id", Integer),
        Column("latest_after_episode_id", Integer),
        UniqueConstraint("user_id", "feed_id"),
    )
    engine = create_engine("sqlite://")
    with engine.begin() as connection:
        metadata.create_all(connection)
        connection.execute(text("INSERT INTO feeds VALUES (1)"))
        connection.execute(text("INSERT INTO subscriptions VALUES (1, 1, 10, 123)"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(
                text("SELECT group_feed_id, latest_after_episode_id FROM subscriptions")
            ).one() == (None, 123)
            assert "ix_subscriptions_group_feed_id" in {
                i["name"] for i in inspect(connection).get_indexes("subscriptions")
            }
            migration.downgrade()
            assert connection.execute(text("SELECT * FROM subscriptions")).one() == (1, 1, 10, 123)
    engine.dispose()
