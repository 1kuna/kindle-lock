"""SQLite database operations for reading progress tracking."""

import json
import logging
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta
from typing import Optional

from .config import settings

logger = logging.getLogger(__name__)


def init_db() -> None:
    """Initialize database with schema."""
    with get_db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS books (
                asin TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                authors TEXT,  -- JSON array
                total_pages INTEGER,
                cover_url TEXT,
                last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS reading_progress (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asin TEXT NOT NULL,
                position INTEGER,  -- Current page/location
                percent_complete REAL,
                recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (asin) REFERENCES books(asin)
            );

            CREATE INDEX IF NOT EXISTS idx_progress_asin_time
                ON reading_progress(asin, recorded_at DESC);

            CREATE TABLE IF NOT EXISTS daily_stats (
                date TEXT PRIMARY KEY,  -- YYYY-MM-DD
                pages_read INTEGER DEFAULT 0,
                goal_met_at TIMESTAMP,
                last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            -- Insert default settings if not exist
            INSERT OR IGNORE INTO settings (key, value) VALUES
                ('daily_page_goal', '30'),
                ('day_reset_hour', '4');
        """)
    logger.info("Database initialized")


@contextmanager
def get_db():
    """Database connection context manager."""
    db_path = settings.get_absolute_database_path()
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def get_today_key() -> str:
    """Get today's date key, accounting for day reset hour.

    If it's before the reset hour (default 4 AM), we're still on "yesterday"
    for reading goal purposes.
    """
    now = datetime.now()
    reset_hour = int(get_setting("day_reset_hour") or settings.day_reset_hour)

    if now.hour < reset_hour:
        # Before reset hour, still counts as previous day
        effective_date = now.date() - timedelta(days=1)
    else:
        effective_date = now.date()

    return effective_date.isoformat()


def get_setting(key: str) -> Optional[str]:
    """Get a setting value by key."""
    with get_db() as conn:
        row = conn.execute(
            "SELECT value FROM settings WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None


def set_setting(key: str, value: str) -> None:
    """Set a setting value."""
    with get_db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            (key, value)
        )


def upsert_book(
    asin: str,
    title: str,
    authors: list[str],
    total_pages: Optional[int] = None,
    cover_url: Optional[str] = None,
) -> None:
    """Insert or update a book record."""
    with get_db() as conn:
        conn.execute(
            """
            INSERT INTO books (asin, title, authors, total_pages, cover_url, last_updated)
            VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(asin) DO UPDATE SET
                title = excluded.title,
                authors = excluded.authors,
                total_pages = COALESCE(excluded.total_pages, books.total_pages),
                cover_url = COALESCE(excluded.cover_url, books.cover_url),
                last_updated = CURRENT_TIMESTAMP
            """,
            (asin, title, json.dumps(authors), total_pages, cover_url),
        )


def record_progress(asin: str, position: int, percent: float) -> None:
    """Record a reading progress snapshot and update daily stats.

    Only counts pages toward daily goal if this is NOT the first time seeing
    this book. This prevents adding all historical progress as "read today"
    when a book is first scraped.
    """
    with get_db() as conn:
        today = get_today_key()

        # Get previous position for this book
        last_progress = conn.execute(
            """
            SELECT position FROM reading_progress
            WHERE asin = ?
            ORDER BY recorded_at DESC LIMIT 1
            """,
            (asin,),
        ).fetchone()

        # Record new progress (always)
        conn.execute(
            """
            INSERT INTO reading_progress (asin, position, percent_complete)
            VALUES (?, ?, ?)
            """,
            (asin, position, percent),
        )

        # Only count pages toward daily goal if we have a PREVIOUS record
        # This prevents counting all historical progress as "read today"
        # when a book is first added to the database
        if last_progress is None:
            logger.info(f"First time seeing book {asin} at position {position} - not counting toward daily goal")
            return

        last_position = last_progress["position"]

        # Calculate pages read (only if position increased)
        if position > last_position:
            pages_delta = position - last_position
            logger.info(f"Book {asin}: read {pages_delta} pages ({last_position} -> {position})")

            # Update daily stats
            conn.execute(
                """
                INSERT INTO daily_stats (date, pages_read, last_updated)
                VALUES (?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(date) DO UPDATE SET
                    pages_read = daily_stats.pages_read + ?,
                    last_updated = CURRENT_TIMESTAMP
                """,
                (today, pages_delta, pages_delta),
            )

            # Check if goal just met
            goal = int(get_setting("daily_page_goal") or settings.daily_page_goal)
            stats = get_today_stats()
            if stats["pages_read"] >= goal and stats["goal_met_at"] is None:
                conn.execute(
                    """
                    UPDATE daily_stats SET goal_met_at = CURRENT_TIMESTAMP
                    WHERE date = ?
                    """,
                    (today,),
                )
                logger.info(f"Daily reading goal met! {stats['pages_read']} pages read.")


def get_today_stats() -> dict:
    """Get today's reading statistics."""
    today = get_today_key()
    goal = int(get_setting("daily_page_goal") or settings.daily_page_goal)

    with get_db() as conn:
        row = conn.execute(
            "SELECT pages_read, goal_met_at FROM daily_stats WHERE date = ?",
            (today,),
        ).fetchone()

        if row:
            return {
                "date": today,
                "pages_read": row["pages_read"],
                "page_goal": goal,
                "goal_met": row["pages_read"] >= goal,
                "goal_met_at": row["goal_met_at"],
                "pages_remaining": max(0, goal - row["pages_read"]),
            }
        else:
            return {
                "date": today,
                "pages_read": 0,
                "page_goal": goal,
                "goal_met": False,
                "goal_met_at": None,
                "pages_remaining": goal,
            }


def get_library() -> list[dict]:
    """Get all books with latest progress."""
    with get_db() as conn:
        rows = conn.execute(
            """
            SELECT
                b.asin,
                b.title,
                b.authors,
                b.total_pages,
                b.cover_url,
                p.position,
                p.percent_complete,
                p.recorded_at as last_read
            FROM books b
            LEFT JOIN (
                SELECT asin, position, percent_complete, recorded_at,
                       ROW_NUMBER() OVER (PARTITION BY asin ORDER BY recorded_at DESC) as rn
                FROM reading_progress
            ) p ON b.asin = p.asin AND p.rn = 1
            ORDER BY p.recorded_at DESC NULLS LAST
            """
        ).fetchall()

        return [
            {
                "asin": r["asin"],
                "title": r["title"],
                "authors": json.loads(r["authors"]) if r["authors"] else [],
                "total_pages": r["total_pages"],
                "cover_url": r["cover_url"],
                "current_position": r["position"],
                "percent_complete": r["percent_complete"],
                "last_read": r["last_read"],
            }
            for r in rows
        ]


def get_book(asin: str) -> Optional[dict]:
    """Get a single book with its progress."""
    books = get_library()
    for book in books:
        if book["asin"] == asin:
            return book
    return None


def reset_daily_stats() -> None:
    """Reset all daily stats. Use after fixing the first-time counting bug."""
    with get_db() as conn:
        conn.execute("DELETE FROM daily_stats")
    logger.info("Daily stats reset")


def reset_all_progress() -> None:
    """Reset all reading progress. Use to re-establish baseline."""
    with get_db() as conn:
        conn.execute("DELETE FROM reading_progress")
        conn.execute("DELETE FROM daily_stats")
    logger.info("All reading progress and daily stats reset")
