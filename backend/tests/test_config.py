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
