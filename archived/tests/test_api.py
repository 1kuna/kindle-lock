"""Tests for API endpoints."""

import pytest
from httpx import AsyncClient

from src import database


@pytest.mark.asyncio
class TestHealthEndpoint:
    """Tests for /health endpoint."""

    async def test_health_returns_healthy(self, async_client: AsyncClient):
        """GET /health should return healthy status."""
        response = await async_client.get("/health")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "healthy"
        assert "timestamp" in data

    async def test_health_no_auth_required(self, async_client: AsyncClient):
        """GET /health should not require authentication."""
        response = await async_client.get("/health")
        assert response.status_code == 200


@pytest.mark.asyncio
class TestTodayEndpoint:
    """Tests for /today endpoint."""

    async def test_today_returns_stats(self, async_client: AsyncClient, api_headers):
        """GET /today should return today's reading stats."""
        response = await async_client.get("/today", headers=api_headers)

        assert response.status_code == 200
        data = response.json()
        assert "date" in data
        assert "pages_read" in data
        assert "page_goal" in data
        assert "goal_met" in data
        assert "pages_remaining" in data

    async def test_today_requires_auth(self, async_client: AsyncClient):
        """GET /today should require authentication when API key is set."""
        # Without headers, should fail when key is configured
        response = await async_client.get(
            "/today", headers={"X-API-Key": "wrong-key"}
        )
        assert response.status_code == 401


@pytest.mark.asyncio
class TestLibraryEndpoint:
    """Tests for /library endpoint."""

    async def test_library_returns_books(
        self, async_client: AsyncClient, api_headers, sample_books
    ):
        """GET /library should return all books."""
        # Add some books
        for book in sample_books:
            database.upsert_book(
                asin=book["asin"],
                title=book["title"],
                authors=book["authors"],
            )

        response = await async_client.get("/library", headers=api_headers)

        assert response.status_code == 200
        data = response.json()
        assert "books" in data
        assert "count" in data
        assert data["count"] == 2

    async def test_library_empty_initially(
        self, async_client: AsyncClient, api_headers
    ):
        """GET /library should return empty list when no books."""
        response = await async_client.get("/library", headers=api_headers)

        assert response.status_code == 200
        data = response.json()
        assert data["books"] == []
        assert data["count"] == 0


@pytest.mark.asyncio
class TestProgressEndpoint:
    """Tests for /progress/{asin} endpoint."""

    async def test_progress_returns_book(
        self, async_client: AsyncClient, api_headers, sample_books
    ):
        """GET /progress/{asin} should return specific book."""
        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        response = await async_client.get(
            f"/progress/{book['asin']}", headers=api_headers
        )

        assert response.status_code == 200
        data = response.json()
        assert data["asin"] == book["asin"]
        assert data["title"] == book["title"]

    async def test_progress_404_for_missing(
        self, async_client: AsyncClient, api_headers
    ):
        """GET /progress/{asin} should return 404 for missing book."""
        response = await async_client.get(
            "/progress/NONEXISTENT", headers=api_headers
        )

        assert response.status_code == 404


@pytest.mark.asyncio
class TestSettingsEndpoint:
    """Tests for /settings endpoint."""

    async def test_get_settings(self, async_client: AsyncClient, api_headers):
        """GET /settings should return current settings."""
        response = await async_client.get("/settings", headers=api_headers)

        assert response.status_code == 200
        data = response.json()
        assert "daily_page_goal" in data
        assert "day_reset_hour" in data

    async def test_update_settings(self, async_client: AsyncClient, api_headers):
        """PUT /settings should update settings."""
        response = await async_client.put(
            "/settings",
            headers=api_headers,
            json={"daily_page_goal": 50},
        )

        assert response.status_code == 200
        data = response.json()
        assert data["daily_page_goal"] == 50

    async def test_update_settings_validation(
        self, async_client: AsyncClient, api_headers
    ):
        """PUT /settings should validate input."""
        # Goal too low
        response = await async_client.put(
            "/settings",
            headers=api_headers,
            json={"daily_page_goal": 0},
        )
        assert response.status_code == 400

        # Goal too high
        response = await async_client.put(
            "/settings",
            headers=api_headers,
            json={"daily_page_goal": 10000},
        )
        assert response.status_code == 400

        # Invalid reset hour
        response = await async_client.put(
            "/settings",
            headers=api_headers,
            json={"day_reset_hour": 25},
        )
        assert response.status_code == 400


@pytest.mark.asyncio
class TestRefreshEndpoint:
    """Tests for /refresh endpoint."""

    async def test_refresh_returns_result(
        self, async_client: AsyncClient, api_headers
    ):
        """POST /refresh should return scrape result."""
        # Note: This test will fail if no browser is available,
        # but it tests the endpoint structure
        response = await async_client.post("/refresh", headers=api_headers)

        # May succeed or fail depending on browser availability
        assert response.status_code == 200
        data = response.json()
        assert "success" in data
        assert "timestamp" in data
