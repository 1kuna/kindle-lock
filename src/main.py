"""FastAPI application for Read-to-Unlock API."""

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .database import init_db, get_today_stats, get_library, get_book, get_setting, set_setting
from .scraper import run_scrape, get_scraper, close_scraper
from .models import (
    HealthResponse,
    TodayResponse,
    LibraryResponse,
    BookResponse,
    RefreshResponse,
    SettingsResponse,
    SettingsUpdate,
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Track last scrape time
last_scrape_time: str | None = None


async def scheduled_scrape() -> None:
    """Background task for periodic scraping."""
    global last_scrape_time
    while True:
        try:
            logger.info("Running scheduled scrape...")
            result = await run_scrape()
            if result["success"]:
                last_scrape_time = result["timestamp"]
                logger.info(f"Scheduled scrape complete: {result['books_scraped']} books")
            else:
                logger.warning(f"Scheduled scrape failed: {result.get('error')}")
        except asyncio.CancelledError:
            logger.info("Scheduled scrape task cancelled")
            raise
        except Exception as e:
            logger.error(f"Scheduled scrape error: {e}", exc_info=True)

        await asyncio.sleep(settings.scrape_interval_minutes * 60)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown lifecycle."""
    # Startup
    init_db()
    logger.info("Database initialized")

    # Start background scraper
    scrape_task = asyncio.create_task(scheduled_scrape())
    logger.info(
        f"Background scraper started (interval: {settings.scrape_interval_minutes} min)"
    )

    yield

    # Shutdown
    scrape_task.cancel()
    try:
        await scrape_task
    except asyncio.CancelledError:
        pass

    await close_scraper()
    logger.info("Shutdown complete")


app = FastAPI(
    title="Read-to-Unlock API",
    description="Kindle reading progress tracker for app unlocking",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS for iOS app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


async def verify_api_key(x_api_key: str | None = Header(None)) -> bool:
    """Simple API key authentication."""
    # If using default key, auth is disabled
    if settings.api_secret_key == "change-me-in-production":
        return True

    if x_api_key != settings.api_secret_key:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return True


# Routes


@app.get("/health", response_model=HealthResponse)
async def health_check() -> HealthResponse:
    """Health check endpoint (no auth required)."""
    return HealthResponse(
        status="healthy",
        timestamp=datetime.now().isoformat(),
        last_scrape=last_scrape_time,
    )


@app.get("/today", response_model=TodayResponse)
async def get_today(authorized: bool = Depends(verify_api_key)) -> TodayResponse:
    """
    Get today's reading progress.
    This is the primary endpoint the iOS app will poll.
    """
    stats = get_today_stats()
    return TodayResponse(**stats)


@app.get("/library", response_model=LibraryResponse)
async def get_user_library(
    authorized: bool = Depends(verify_api_key),
) -> LibraryResponse:
    """Get all books with their reading progress."""
    books = get_library()
    return LibraryResponse(
        books=[BookResponse(**b) for b in books],
        count=len(books),
    )


@app.get("/progress/{asin}", response_model=BookResponse)
async def get_book_progress(
    asin: str,
    authorized: bool = Depends(verify_api_key),
) -> BookResponse:
    """Get progress for a specific book."""
    book = get_book(asin)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    return BookResponse(**book)


@app.post("/refresh", response_model=RefreshResponse)
async def trigger_refresh(
    authorized: bool = Depends(verify_api_key),
) -> RefreshResponse:
    """
    Manually trigger a scrape refresh.
    Use sparingly - scheduled scrapes run every 30 min.
    """
    global last_scrape_time
    result = await run_scrape()
    if result["success"]:
        last_scrape_time = result["timestamp"]
    return RefreshResponse(**result)


@app.get("/settings", response_model=SettingsResponse)
async def get_app_settings(
    authorized: bool = Depends(verify_api_key),
) -> SettingsResponse:
    """Get current settings."""
    return SettingsResponse(
        daily_page_goal=int(
            get_setting("daily_page_goal") or settings.daily_page_goal
        ),
        day_reset_hour=int(get_setting("day_reset_hour") or settings.day_reset_hour),
    )


@app.put("/settings", response_model=SettingsResponse)
async def update_app_settings(
    update: SettingsUpdate,
    authorized: bool = Depends(verify_api_key),
) -> SettingsResponse:
    """Update settings."""
    if update.daily_page_goal is not None:
        if update.daily_page_goal < 1 or update.daily_page_goal > 1000:
            raise HTTPException(400, "daily_page_goal must be between 1 and 1000")
        set_setting("daily_page_goal", str(update.daily_page_goal))

    if update.day_reset_hour is not None:
        if update.day_reset_hour < 0 or update.day_reset_hour > 23:
            raise HTTPException(400, "day_reset_hour must be between 0 and 23")
        set_setting("day_reset_hour", str(update.day_reset_hour))

    return await get_app_settings()


def run() -> None:
    """Entry point for running the server."""
    import uvicorn

    uvicorn.run(
        "src.main:app",
        host=settings.api_host,
        port=settings.api_port,
        reload=False,
    )


if __name__ == "__main__":
    run()
