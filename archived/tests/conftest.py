"""Pytest configuration and shared fixtures."""

import os
import tempfile
from pathlib import Path

import pytest
from httpx import AsyncClient, ASGITransport

# Set test environment variables before importing app modules
os.environ["DATABASE_PATH"] = ":memory:"
os.environ["BROWSER_HEADLESS"] = "true"
os.environ["API_SECRET_KEY"] = "test-secret-key"


@pytest.fixture(scope="session")
def temp_data_dir():
    """Create a temporary data directory for tests."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture(scope="function")
def test_db(temp_data_dir, monkeypatch):
    """Create a fresh test database for each test."""
    db_path = temp_data_dir / f"test_{os.getpid()}.db"
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    # Re-import to pick up new path
    from src.config import Settings
    from src import database

    # Create new settings instance with test path
    test_settings = Settings(database_path=db_path)
    monkeypatch.setattr(database, "settings", test_settings)

    # Initialize the database
    database.init_db()

    yield db_path

    # Cleanup
    if db_path.exists():
        db_path.unlink()


@pytest.fixture
def sample_books():
    """Sample book data for testing."""
    return [
        {
            "asin": "B00TEST001",
            "title": "The Great Book",
            "authors": ["John Author"],
            "total_pages": 300,
            "cover_url": "https://example.com/cover1.jpg",
        },
        {
            "asin": "B00TEST002",
            "title": "Another Book",
            "authors": ["Jane Writer", "Co Author"],
            "total_pages": 250,
            "cover_url": "https://example.com/cover2.jpg",
        },
    ]


@pytest.fixture
async def async_client(test_db):
    """Create an async HTTP client for API testing."""
    from src.main import app
    from src.database import init_db

    # Ensure database is initialized
    init_db()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


@pytest.fixture
def api_headers():
    """Headers with API key for authenticated requests."""
    return {"X-API-Key": "test-secret-key"}
