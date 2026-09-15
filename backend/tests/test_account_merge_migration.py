"""An additive migration leaves existing newsletter addresses usable."""

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_inbox_alias_migration_preserves_existing_addresses():
    path = Path(__file__).parents[1] / "alembic/versions/e94d82c617ab_add_newsletter_inbox_aliases.py"
    spec = importlib.util.spec_from_file_location("inbox_alias_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(sa.text("PRAGMA foreign_keys=ON"))
        connection.execute(sa.text("CREATE TABLE users (id UUID PRIMARY KEY, inbound_token TEXT UNIQUE)"))
        connection.execute(sa.text("INSERT INTO users VALUES ('original', 'old-address')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(sa.text("SELECT inbound_token FROM users")).scalar() == "old-address"
            connection.execute(
                sa.text("INSERT INTO newsletter_inbox_aliases VALUES ('other-address', 'original', 'previous')")
            )
            connection.execute(sa.text("DELETE FROM users WHERE id = 'original'"))
            assert connection.execute(sa.text("SELECT COUNT(*) FROM newsletter_inbox_aliases")).scalar() == 0
            migration.downgrade()
            assert "newsletter_inbox_aliases" not in sa.inspect(connection).get_table_names()
