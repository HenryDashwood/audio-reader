"""The migration grants nobody access and cascades account/flag deletion."""

import importlib.util
from pathlib import Path

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_feature_flag_migration_and_downgrade():
    path = Path(__file__).parents[1] / "alembic/versions/d8a31e6c92f4_add_feature_flags.py"
    spec = importlib.util.spec_from_file_location("feature_flag_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(sa.text("PRAGMA foreign_keys=ON"))
        connection.execute(sa.text("CREATE TABLE users (id UUID PRIMARY KEY)"))
        connection.execute(sa.text("INSERT INTO users VALUES ('existing')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            assert connection.execute(sa.text("SELECT COUNT(*) FROM users")).scalar() == 1
            assert connection.execute(sa.text("SELECT default_enabled FROM feature_flags")).scalar() == 0
            assert connection.execute(sa.text("SELECT COUNT(*) FROM user_feature_flags")).scalar() == 0
            for owner in ("flag", "user"):
                connection.execute(sa.text("INSERT INTO user_feature_flags VALUES ('existing', 'pdf_unlimited', 1)"))
                if owner == "flag":
                    connection.execute(sa.text("DELETE FROM feature_flags WHERE key = 'pdf_unlimited'"))
                    connection.execute(
                        sa.text("INSERT INTO feature_flags VALUES ('pdf_unlimited', 'Unlimited PDFs', 0)")
                    )
                else:
                    connection.execute(sa.text("DELETE FROM users WHERE id = 'existing'"))
                assert connection.execute(sa.text("SELECT COUNT(*) FROM user_feature_flags")).scalar() == 0
            migration.downgrade()
            assert "feature_flags" not in sa.inspect(connection).get_table_names()
            assert "user_feature_flags" not in sa.inspect(connection).get_table_names()
