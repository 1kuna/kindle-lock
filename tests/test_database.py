"""Tests for database operations."""

import pytest
from datetime import datetime, timedelta

from src import database


class TestDatabaseInit:
    """Tests for database initialization."""

    def test_init_db_creates_tables(self, test_db):
        """init_db should create all required tables."""
        with database.get_db() as conn:
            # Check tables exist
            tables = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
            table_names = {t["name"] for t in tables}

            assert "books" in table_names
            assert "reading_progress" in table_names
            assert "daily_stats" in table_names
            assert "settings" in table_names

    def test_init_db_creates_default_settings(self, test_db):
        """init_db should create default settings."""
        goal = database.get_setting("daily_page_goal")
        reset_hour = database.get_setting("day_reset_hour")

        assert goal == "30"
        assert reset_hour == "4"


class TestSettings:
    """Tests for settings operations."""

    def test_get_setting_returns_none_for_missing(self, test_db):
        """get_setting should return None for non-existent keys."""
        result = database.get_setting("nonexistent_key")
        assert result is None

    def test_set_and_get_setting(self, test_db):
        """set_setting should store values retrievable by get_setting."""
        database.set_setting("test_key", "test_value")
        result = database.get_setting("test_key")
        assert result == "test_value"

    def test_set_setting_overwrites(self, test_db):
        """set_setting should overwrite existing values."""
        database.set_setting("test_key", "value1")
        database.set_setting("test_key", "value2")
        result = database.get_setting("test_key")
        assert result == "value2"


class TestBooks:
    """Tests for book operations."""

    def test_upsert_book_creates_new(self, test_db, sample_books):
        """upsert_book should create a new book record."""
        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
            total_pages=book["total_pages"],
            cover_url=book["cover_url"],
        )

        books = database.get_library()
        assert len(books) == 1
        assert books[0]["asin"] == book["asin"]
        assert books[0]["title"] == book["title"]

    def test_upsert_book_updates_existing(self, test_db, sample_books):
        """upsert_book should update an existing book."""
        book = sample_books[0]

        # Insert first
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        # Update with new title
        database.upsert_book(
            asin=book["asin"],
            title="Updated Title",
            authors=book["authors"],
        )

        books = database.get_library()
        assert len(books) == 1
        assert books[0]["title"] == "Updated Title"

    def test_get_library_returns_all_books(self, test_db, sample_books):
        """get_library should return all books."""
        for book in sample_books:
            database.upsert_book(
                asin=book["asin"],
                title=book["title"],
                authors=book["authors"],
            )

        books = database.get_library()
        assert len(books) == 2

    def test_get_book_returns_single(self, test_db, sample_books):
        """get_book should return a single book by ASIN."""
        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        result = database.get_book(book["asin"])
        assert result is not None
        assert result["asin"] == book["asin"]

    def test_get_book_returns_none_for_missing(self, test_db):
        """get_book should return None for non-existent ASIN."""
        result = database.get_book("NONEXISTENT")
        assert result is None


class TestProgress:
    """Tests for reading progress operations."""

    def test_record_progress_creates_entry(self, test_db, sample_books):
        """record_progress should create a progress entry."""
        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        database.record_progress(book["asin"], position=50, percent=16.67)

        books = database.get_library()
        assert books[0]["current_position"] == 50
        assert books[0]["percent_complete"] == 16.67

    def test_record_progress_updates_daily_stats(self, test_db, sample_books):
        """record_progress should update daily stats when position increases."""
        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        # Record initial position
        database.record_progress(book["asin"], position=10, percent=3.0)

        # Record increased position
        database.record_progress(book["asin"], position=25, percent=8.0)

        stats = database.get_today_stats()
        # Should have 25 pages (10 initial + 15 delta)
        assert stats["pages_read"] == 25

    def test_record_progress_ignores_decrease(self, test_db, sample_books):
        """record_progress should not count decreased positions."""
        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        database.record_progress(book["asin"], position=50, percent=16.0)
        database.record_progress(book["asin"], position=30, percent=10.0)  # Went back

        stats = database.get_today_stats()
        assert stats["pages_read"] == 50  # Should not decrease


class TestDailyStats:
    """Tests for daily statistics."""

    def test_get_today_stats_returns_defaults(self, test_db):
        """get_today_stats should return default values for new day."""
        stats = database.get_today_stats()

        assert stats["pages_read"] == 0
        assert stats["page_goal"] == 30
        assert stats["goal_met"] is False
        assert stats["goal_met_at"] is None
        assert stats["pages_remaining"] == 30

    def test_goal_met_updates_when_reached(self, test_db, sample_books):
        """goal_met_at should be set when goal is reached."""
        # Set a low goal for testing
        database.set_setting("daily_page_goal", "10")

        book = sample_books[0]
        database.upsert_book(
            asin=book["asin"],
            title=book["title"],
            authors=book["authors"],
        )

        # Read 15 pages (above goal)
        database.record_progress(book["asin"], position=15, percent=5.0)

        stats = database.get_today_stats()
        assert stats["goal_met"] is True
        assert stats["goal_met_at"] is not None

    def test_get_today_key_before_reset(self, test_db, monkeypatch):
        """get_today_key should return yesterday before reset hour."""
        # Mock datetime to 3 AM (before 4 AM reset)
        from unittest.mock import patch
        from datetime import datetime as real_datetime

        class MockDatetime:
            @classmethod
            def now(cls):
                return real_datetime(2024, 1, 15, 3, 0, 0)  # 3 AM

        with patch.object(database, "datetime", MockDatetime):
            key = database.get_today_key()
            assert key == "2024-01-14"  # Should be yesterday

    def test_get_today_key_after_reset(self, test_db, monkeypatch):
        """get_today_key should return today after reset hour."""
        from unittest.mock import patch
        from datetime import datetime as real_datetime

        class MockDatetime:
            @classmethod
            def now(cls):
                return real_datetime(2024, 1, 15, 5, 0, 0)  # 5 AM

        with patch.object(database, "datetime", MockDatetime):
            key = database.get_today_key()
            assert key == "2024-01-15"  # Should be today
