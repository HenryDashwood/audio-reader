"""Billing migration is additive and account deletion cascades the allowance ledger."""

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_billing_migration_preserves_users_and_cascades_delete():
    path = Path(__file__).parents[1] / "alembic/versions/c53fa801d206_magpie_plus.py"
    spec = importlib.util.spec_from_file_location("billing_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(sa.text("PRAGMA foreign_keys=ON"))
        connection.execute(sa.text("CREATE TABLE users (id UUID PRIMARY KEY, display_name TEXT)"))
        connection.execute(sa.text("INSERT INTO users VALUES ('original', 'Original account')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(sa.text("SELECT display_name FROM users")).scalar() == "Original account"
            connection.execute(
                sa.text(
                    "INSERT INTO billing_customers (id,user_id,created_at) "
                    "VALUES ('rc-owner','original',CURRENT_TIMESTAMP)"
                )
            )
            connection.execute(
                sa.text(
                    "INSERT INTO pdf_page_usage "
                    "VALUES ('doc','original',50,'used',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)"
                )
            )
            connection.execute(sa.text("DELETE FROM users WHERE id = 'original'"))
            assert connection.execute(sa.text("SELECT COUNT(*) FROM billing_customers")).scalar() == 0
            assert connection.execute(sa.text("SELECT COUNT(*) FROM pdf_page_usage")).scalar() == 0
            migration.downgrade()
            assert "pdf_page_usage" not in sa.inspect(connection).get_table_names()
