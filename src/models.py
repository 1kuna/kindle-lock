"""Pydantic models for API request/response schemas."""

from typing import Optional
from pydantic import BaseModel


class HealthResponse(BaseModel):
    """Health check response."""

    status: str
    timestamp: str
    last_scrape: Optional[str] = None


class TodayResponse(BaseModel):
    """Today's reading progress response."""

    date: str
    pages_read: int
    page_goal: int
    goal_met: bool
    goal_met_at: Optional[str] = None
    pages_remaining: int


class BookResponse(BaseModel):
    """Book with reading progress."""

    asin: str
    title: str
    authors: list[str]
    total_pages: Optional[int] = None
    cover_url: Optional[str] = None
    current_position: Optional[int] = None
    percent_complete: Optional[float] = None
    last_read: Optional[str] = None


class LibraryResponse(BaseModel):
    """Library listing response."""

    books: list[BookResponse]
    count: int


class RefreshResponse(BaseModel):
    """Scrape refresh response."""

    success: bool
    books_scraped: Optional[int] = None
    error: Optional[str] = None
    timestamp: str


class SettingsResponse(BaseModel):
    """Current settings response."""

    daily_page_goal: int
    day_reset_hour: int


class SettingsUpdate(BaseModel):
    """Settings update request."""

    daily_page_goal: Optional[int] = None
    day_reset_hour: Optional[int] = None


# =============================================================================
# SSE Streaming Events for /refresh/stream endpoint
# =============================================================================


class ScrapeStartedEvent(BaseModel):
    """Emitted when scrape begins."""

    event: str = "started"
    total_books: int
    timestamp: str


class BookProgressEvent(BaseModel):
    """Emitted before processing each book."""

    event: str = "book_progress"
    current: int
    total: int
    book_title: str
    book_asin: str


class BookCompleteEvent(BaseModel):
    """Emitted after processing each book."""

    event: str = "book_complete"
    current: int
    total: int
    book_title: str
    book_asin: str
    percent_complete: Optional[float] = None
    success: bool = True
    error: Optional[str] = None


class ScrapeErrorEvent(BaseModel):
    """Emitted when a fatal error occurs."""

    event: str = "error"
    message: str
    recoverable: bool = False


class ScrapeCompletedEvent(BaseModel):
    """Emitted when scrape completes successfully."""

    event: str = "completed"
    success: bool
    books_scraped: int
    books_with_progress: int
    duration_seconds: float
    timestamp: str
    license_limit_books: Optional[list[str]] = None
