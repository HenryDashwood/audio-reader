"""The additive browser migration preserves released clients' Apple identities."""

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_browser_migration_preserves_existing_apple_identity():
    path = Path(__file__).parents[1] / "alembic/versions/f83a2c04d917_add_apple_browser_sign_in.py"
    spec = importlib.util.spec_from_file_location("apple_browser_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(sa.text("CREATE TABLE users (id UUID PRIMARY KEY)"))
        connection.execute(sa.text("CREATE TABLE user_identities (id INTEGER PRIMARY KEY, refresh_token TEXT)"))
        connection.execute(sa.text("INSERT INTO user_identities VALUES (1, 'existing-token')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(
                sa.text("SELECT refresh_token, refresh_token_client_id FROM user_identities")
            ).one() == ("existing-token", None)
            assert "apple_browser_flows" in sa.inspect(connection).get_table_names()
            migration.downgrade()
            assert (
                connection.execute(sa.text("SELECT refresh_token FROM user_identities")).scalar() == "existing-token"
            )
            assert "apple_browser_flows" not in sa.inspect(connection).get_table_names()
