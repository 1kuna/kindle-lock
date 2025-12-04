"""Application configuration using Pydantic settings."""

from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Amazon credentials (for initial login only)
    amazon_email: str = ""
    amazon_password: str = ""

    # API settings
    api_host: str = "0.0.0.0"
    api_port: int = 8080
    api_secret_key: str = "change-me-in-production"

    # Reading goal settings
    daily_page_goal: int = 30
    day_reset_hour: int = 4  # 4 AM

    # Scraper settings
    scrape_interval_minutes: int = 30
    browser_headless: bool = True

    # Paths (relative to project root)
    database_path: Path = Path("./data/reading.db")
    browser_profile_path: Path = Path("./data/browser_profile")

    def get_absolute_database_path(self) -> Path:
        """Get absolute path to database, creating parent dirs if needed."""
        path = self.database_path
        if not path.is_absolute():
            path = Path.cwd() / path
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def get_absolute_browser_profile_path(self) -> Path:
        """Get absolute path to browser profile, creating dir if needed."""
        path = self.browser_profile_path
        if not path.is_absolute():
            path = Path.cwd() / path
        path.mkdir(parents=True, exist_ok=True)
        return path


# Global settings instance
settings = Settings()
