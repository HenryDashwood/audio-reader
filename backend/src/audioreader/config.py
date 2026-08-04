from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="AUDIOREADER_")

    database_url: str = "postgresql+asyncpg://audioreader:audioreader@localhost:5432/audioreader"


settings = Settings()
