"""The PDF migration preserves existing accounts and supports rollback."""

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_pdf_migration_preserves_existing_data():
    path = Path(__file__).parents[1] / "alembic/versions/b42e87f60d19_pdf_imports.py"
    spec = importlib.util.spec_from_file_location("pdf_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(sa.text("PRAGMA foreign_keys=ON"))
        connection.execute(sa.text("CREATE TABLE users (id UUID PRIMARY KEY, display_name TEXT)"))
        connection.execute(sa.text("CREATE TABLE episodes (id INTEGER PRIMARY KEY, title TEXT)"))
        connection.execute(sa.text("INSERT INTO users VALUES ('original', 'Original account')"))
        connection.execute(sa.text("INSERT INTO episodes VALUES (1, 'Existing article')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(sa.text("SELECT pdf_consent_version FROM users")).scalar() is None
            assert connection.execute(sa.text("SELECT title FROM episodes")).scalar() == "Existing article"
            connection.execute(sa.text("INSERT INTO pdf_usage VALUES (1, 'original', 12, CURRENT_TIMESTAMP)"))
            connection.execute(sa.text("DELETE FROM users WHERE id = 'original'"))
            assert connection.execute(sa.text("SELECT COUNT(*) FROM pdf_usage")).scalar() == 0
            migration.downgrade()
            assert "pdf_documents" not in sa.inspect(connection).get_table_names()
            assert connection.execute(sa.text("SELECT title FROM episodes")).scalar() == "Existing article"
