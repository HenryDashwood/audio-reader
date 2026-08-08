from audioreader.config import normalise_database_url


class TestNormaliseDatabaseURL:
    def test_adds_the_async_driver(self):
        # Railway (and most hosts) hand out a plain postgresql:// URL, which
        # SQLAlchemy's async engine cannot use.
        assert normalise_database_url("postgresql://u:p@host:5432/db") == (
            "postgresql+asyncpg://u:p@host:5432/db"
        )

    def test_upgrades_the_legacy_postgres_scheme(self):
        assert normalise_database_url("postgres://u:p@host/db") == (
            "postgresql+asyncpg://u:p@host/db"
        )

    def test_leaves_an_explicit_driver_alone(self):
        url = "postgresql+asyncpg://u:p@host/db"
        assert normalise_database_url(url) == url

    def test_leaves_other_databases_alone(self):
        assert normalise_database_url("sqlite+aiosqlite://") == "sqlite+aiosqlite://"

    def test_preserves_query_parameters(self):
        assert normalise_database_url("postgresql://u:p@host/db?sslmode=require") == (
            "postgresql+asyncpg://u:p@host/db?sslmode=require"
        )


class TestRedactedDatabaseURL:
    def test_hides_the_password(self):
        from audioreader.config import redacted_database_url

        out = redacted_database_url("postgresql+asyncpg://user:sekrit@db.internal:5432/app")
        assert "sekrit" not in out
        assert "db.internal:5432" in out

    def test_keeps_enough_to_diagnose(self):
        from audioreader.config import redacted_database_url

        # The host is the whole point: it tells you instantly whether the
        # deployment picked up the platform's database or fell back to local.
        assert "localhost" in redacted_database_url(
            "postgresql+asyncpg://a:b@localhost:5432/audioreader"
        )

    def test_survives_a_url_with_no_credentials(self):
        from audioreader.config import redacted_database_url

        assert redacted_database_url("sqlite+aiosqlite://") == "sqlite+aiosqlite://"
