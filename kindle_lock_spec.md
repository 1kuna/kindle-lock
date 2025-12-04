# Read-to-Unlock System: Complete Technical Specification

## Project Overview

**Goal**: Build a system that locks social media apps on iOS until the user has read a configurable number of pages on their Kindle each day.

**Components**:
1. **Raspberry Pi 5 Backend**: Scrapes Kindle Cloud Reader for reading progress, exposes REST API
2. **iOS App**: Queries the Pi API, applies/removes app shields based on reading goal completion

**Daily Cycle**: Resets at 4:00 AM local time. User must read X pages (configurable, default 30) to unlock apps.

---

## Part 1: Raspberry Pi Backend

### 1.1 Hardware Requirements

- Raspberry Pi 5 (4GB RAM minimum)
- MicroSD card (32GB+) with Raspberry Pi OS Lite (64-bit, Bookworm)
- Ethernet or WiFi connectivity
- No display required after initial setup

### 1.2 System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Raspberry Pi 5                                             │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  kindle-scraper (Python)                            │   │
│  │  - Playwright browser automation                    │   │
│  │  - Authenticates to read.amazon.com                 │   │
│  │  - Extracts reading progress from IndexedDB         │   │
│  │  - Runs on 30-min schedule + on-demand              │   │
│  └──────────────────────┬──────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  SQLite Database                                    │   │
│  │  - books table (asin, title, authors, total_pages)  │   │
│  │  - progress table (asin, position, percent, ts)     │   │
│  │  - daily_stats table (date, pages_read)             │   │
│  └──────────────────────┬──────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  FastAPI Server (:8080)                             │   │
│  │  - GET /health                                      │   │
│  │  - GET /today                                       │   │
│  │  - GET /library                                     │   │
│  │  - GET /progress/{asin}                             │   │
│  │  - POST /refresh                                    │   │
│  │  - GET /settings                                    │   │
│  │  - PUT /settings                                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Directory Structure

```
/home/pi/read-to-unlock/
├── pyproject.toml
├── requirements.txt
├── .env                      # Amazon credentials (gitignored)
├── .env.example
├── data/
│   ├── reading.db            # SQLite database
│   └── browser_profile/      # Playwright persistent context
├── src/
│   ├── __init__.py
│   ├── main.py               # FastAPI application entry
│   ├── config.py             # Settings and environment
│   ├── database.py           # SQLite models and queries
│   ├── scraper.py            # Kindle Cloud Reader scraper
│   ├── scheduler.py          # Background job scheduling
│   └── models.py             # Pydantic schemas
├── scripts/
│   ├── setup.sh              # Initial Pi setup
│   ├── login.py              # One-time Amazon login helper
│   └── install_service.sh    # systemd service installer
├── systemd/
│   ├── read-to-unlock.service
│   └── read-to-unlock-scraper.timer
└── tests/
    ├── test_scraper.py
    └── test_api.py
```

### 1.4 Configuration

#### .env.example
```bash
# Amazon Credentials (for initial login only - session persists in browser_profile)
AMAZON_EMAIL=your-email@example.com
AMAZON_PASSWORD=your-password

# API Settings
API_HOST=0.0.0.0
API_PORT=8080

# Reading Goal
DAILY_PAGE_GOAL=30
DAY_RESET_HOUR=4  # 4 AM local time

# Scraper Settings  
SCRAPE_INTERVAL_MINUTES=30
BROWSER_HEADLESS=true

# Database
DATABASE_PATH=./data/reading.db

# Security (generate with: openssl rand -hex 32)
API_SECRET_KEY=your-secret-key-here
```

#### src/config.py
```python
from pydantic_settings import BaseSettings
from pathlib import Path

class Settings(BaseSettings):
    amazon_email: str = ""
    amazon_password: str = ""
    
    api_host: str = "0.0.0.0"
    api_port: int = 8080
    api_secret_key: str = "change-me-in-production"
    
    daily_page_goal: int = 30
    day_reset_hour: int = 4
    
    scrape_interval_minutes: int = 30
    browser_headless: bool = True
    
    database_path: Path = Path("./data/reading.db")
    browser_profile_path: Path = Path("./data/browser_profile")
    
    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

settings = Settings()
```

### 1.5 Database Schema

#### src/database.py
```python
import sqlite3
from datetime import datetime, date
from pathlib import Path
from contextlib import contextmanager
from typing import Optional
from .config import settings

def init_db():
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

@contextmanager
def get_db():
    """Database connection context manager."""
    settings.database_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(settings.database_path)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()

def get_today_key() -> str:
    """Get today's date key, accounting for 4 AM reset."""
    now = datetime.now()
    reset_hour = int(get_setting("day_reset_hour") or settings.day_reset_hour)
    
    if now.hour < reset_hour:
        # Before reset hour, still counts as previous day
        effective_date = now.date() - timedelta(days=1)
    else:
        effective_date = now.date()
    
    return effective_date.isoformat()

def get_setting(key: str) -> Optional[str]:
    with get_db() as conn:
        row = conn.execute(
            "SELECT value FROM settings WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None

def set_setting(key: str, value: str):
    with get_db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            (key, value)
        )

def upsert_book(asin: str, title: str, authors: list[str], 
                total_pages: int = None, cover_url: str = None):
    import json
    with get_db() as conn:
        conn.execute("""
            INSERT INTO books (asin, title, authors, total_pages, cover_url, last_updated)
            VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(asin) DO UPDATE SET
                title = excluded.title,
                authors = excluded.authors,
                total_pages = COALESCE(excluded.total_pages, books.total_pages),
                cover_url = COALESCE(excluded.cover_url, books.cover_url),
                last_updated = CURRENT_TIMESTAMP
        """, (asin, title, json.dumps(authors), total_pages, cover_url))

def record_progress(asin: str, position: int, percent: float):
    """Record a reading progress snapshot and update daily stats."""
    with get_db() as conn:
        # Get previous position for this book today
        today = get_today_key()
        
        last_progress = conn.execute("""
            SELECT position FROM reading_progress 
            WHERE asin = ? 
            ORDER BY recorded_at DESC LIMIT 1
        """, (asin,)).fetchone()
        
        last_position = last_progress["position"] if last_progress else 0
        
        # Record new progress
        conn.execute("""
            INSERT INTO reading_progress (asin, position, percent_complete)
            VALUES (?, ?, ?)
        """, (asin, position, percent))
        
        # Calculate pages read (only if position increased)
        if position > last_position:
            pages_delta = position - last_position
            
            # Update daily stats
            conn.execute("""
                INSERT INTO daily_stats (date, pages_read, last_updated)
                VALUES (?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(date) DO UPDATE SET
                    pages_read = daily_stats.pages_read + ?,
                    last_updated = CURRENT_TIMESTAMP
            """, (today, pages_delta, pages_delta))
            
            # Check if goal just met
            goal = int(get_setting("daily_page_goal") or settings.daily_page_goal)
            stats = get_today_stats()
            if stats["pages_read"] >= goal and stats["goal_met_at"] is None:
                conn.execute("""
                    UPDATE daily_stats SET goal_met_at = CURRENT_TIMESTAMP
                    WHERE date = ?
                """, (today,))

def get_today_stats() -> dict:
    """Get today's reading statistics."""
    today = get_today_key()
    goal = int(get_setting("daily_page_goal") or settings.daily_page_goal)
    
    with get_db() as conn:
        row = conn.execute("""
            SELECT pages_read, goal_met_at FROM daily_stats WHERE date = ?
        """, (today,)).fetchone()
        
        if row:
            return {
                "date": today,
                "pages_read": row["pages_read"],
                "page_goal": goal,
                "goal_met": row["pages_read"] >= goal,
                "goal_met_at": row["goal_met_at"],
                "pages_remaining": max(0, goal - row["pages_read"])
            }
        else:
            return {
                "date": today,
                "pages_read": 0,
                "page_goal": goal,
                "goal_met": False,
                "goal_met_at": None,
                "pages_remaining": goal
            }

def get_library() -> list[dict]:
    """Get all books with latest progress."""
    with get_db() as conn:
        rows = conn.execute("""
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
        """).fetchall()
        
        import json
        return [{
            "asin": r["asin"],
            "title": r["title"],
            "authors": json.loads(r["authors"]) if r["authors"] else [],
            "total_pages": r["total_pages"],
            "cover_url": r["cover_url"],
            "current_position": r["position"],
            "percent_complete": r["percent_complete"],
            "last_read": r["last_read"]
        } for r in rows]
```

### 1.6 Kindle Cloud Reader Scraper

#### src/scraper.py
```python
import asyncio
import json
import logging
from datetime import datetime
from playwright.async_api import async_playwright, Page, BrowserContext
from .config import settings
from .database import upsert_book, record_progress

logger = logging.getLogger(__name__)

class KindleScraper:
    """Scrapes reading progress from Kindle Cloud Reader."""
    
    CLOUD_READER_URL = "https://read.amazon.com/"
    
    def __init__(self):
        self.context: BrowserContext = None
        self.page: Page = None
    
    async def init_browser(self):
        """Initialize persistent browser context."""
        playwright = await async_playwright().start()
        
        # Persistent context preserves login session
        self.context = await playwright.chromium.launch_persistent_context(
            user_data_dir=str(settings.browser_profile_path),
            headless=settings.browser_headless,
            viewport={"width": 1280, "height": 720},
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        )
        
        self.page = await self.context.new_page()
    
    async def close(self):
        """Close browser context."""
        if self.context:
            await self.context.close()
    
    async def is_logged_in(self) -> bool:
        """Check if we have a valid Amazon session."""
        await self.page.goto(self.CLOUD_READER_URL, wait_until="networkidle")
        
        # If redirected to signin, we're not logged in
        return "signin" not in self.page.url and "ap/signin" not in self.page.url
    
    async def login(self, email: str, password: str):
        """
        Perform Amazon login.
        NOTE: May require manual 2FA/CAPTCHA completion.
        Run with BROWSER_HEADLESS=false for initial login.
        """
        await self.page.goto(self.CLOUD_READER_URL)
        
        # Wait for and fill email
        await self.page.wait_for_selector('input[type="email"], input[name="email"]')
        await self.page.fill('input[type="email"], input[name="email"]', email)
        
        # Click continue/next if separate email step
        continue_btn = self.page.locator('input#continue, span#continue')
        if await continue_btn.count() > 0:
            await continue_btn.click()
        
        # Fill password
        await self.page.wait_for_selector('input[type="password"]')
        await self.page.fill('input[type="password"]', password)
        
        # Submit
        await self.page.click('input#signInSubmit, input[type="submit"]')
        
        # Wait for redirect to cloud reader or 2FA prompt
        await self.page.wait_for_url(
            lambda url: "read.amazon.com" in url or "ap/mfa" in url or "ap/cvf" in url,
            timeout=60000
        )
        
        if "mfa" in self.page.url or "cvf" in self.page.url:
            logger.warning("2FA/CAPTCHA required - complete manually in browser")
            # Wait up to 5 minutes for manual completion
            await self.page.wait_for_url("**/read.amazon.com/**", timeout=300000)
        
        logger.info("Login successful")
    
    async def get_library_and_progress(self) -> list[dict]:
        """
        Extract library and reading progress from Kindle Cloud Reader.
        
        Returns list of books with:
        - asin, title, authors, cover_url
        - current_position (page/location)
        - percent_complete
        - last_read_timestamp
        """
        await self.page.goto(self.CLOUD_READER_URL, wait_until="networkidle")
        
        # Wait for library to load
        await self.page.wait_for_selector('[id*="library"], .book-list', timeout=30000)
        await asyncio.sleep(2)  # Let dynamic content settle
        
        # Extract data via JavaScript - accesses IndexedDB and DOM
        books_data = await self.page.evaluate("""
            async () => {
                const books = [];
                
                // Method 1: Try to get from K4W IndexedDB (most detailed)
                try {
                    const dbRequest = indexedDB.open('K4W');
                    const db = await new Promise((resolve, reject) => {
                        dbRequest.onsuccess = () => resolve(dbRequest.result);
                        dbRequest.onerror = () => reject(dbRequest.error);
                    });
                    
                    // Get book metadata from object stores
                    const tx = db.transaction(['bookData', 'bookProgress'], 'readonly');
                    const bookStore = tx.objectStore('bookData');
                    const progressStore = tx.objectStore('bookProgress');
                    
                    const getAllBooks = () => new Promise((resolve) => {
                        const req = bookStore.getAll();
                        req.onsuccess = () => resolve(req.result);
                        req.onerror = () => resolve([]);
                    });
                    
                    const bookList = await getAllBooks();
                    
                    for (const book of bookList) {
                        const progressReq = progressStore.get(book.asin);
                        const progress = await new Promise((resolve) => {
                            progressReq.onsuccess = () => resolve(progressReq.result);
                            progressReq.onerror = () => resolve(null);
                        });
                        
                        books.push({
                            asin: book.asin,
                            title: book.title,
                            authors: book.authors || [],
                            coverUrl: book.coverUrl || book.imageUrl,
                            totalPages: book.totalPages || book.estimatedPages,
                            currentPosition: progress?.position || progress?.lastPosition || 0,
                            percentComplete: progress?.percentComplete || progress?.percent || 0,
                            lastReadTimestamp: progress?.lastReadTime || progress?.syncTime
                        });
                    }
                    
                    db.close();
                } catch (e) {
                    console.log('IndexedDB access failed:', e);
                }
                
                // Method 2: Fallback - parse from DOM/network
                if (books.length === 0) {
                    const bookElements = document.querySelectorAll('[data-asin], .book-item');
                    for (const el of bookElements) {
                        const asin = el.getAttribute('data-asin') || el.dataset.asin;
                        const titleEl = el.querySelector('.title, [class*="title"]');
                        const authorEl = el.querySelector('.author, [class*="author"]');
                        const imgEl = el.querySelector('img');
                        const progressEl = el.querySelector('[class*="progress"], .reading-progress');
                        
                        if (asin) {
                            books.push({
                                asin: asin,
                                title: titleEl?.textContent?.trim() || 'Unknown',
                                authors: authorEl ? [authorEl.textContent.trim()] : [],
                                coverUrl: imgEl?.src,
                                totalPages: null,
                                currentPosition: null,
                                percentComplete: progressEl ? 
                                    parseFloat(progressEl.textContent) || 0 : 0,
                                lastReadTimestamp: null
                            });
                        }
                    }
                }
                
                return books;
            }
        """)
        
        return books_data
    
    async def scrape_and_save(self) -> dict:
        """
        Main scrape operation - fetches data and saves to database.
        Returns summary of what was scraped.
        """
        try:
            if not await self.is_logged_in():
                logger.warning("Not logged in - attempting login")
                await self.login(settings.amazon_email, settings.amazon_password)
            
            books = await self.get_library_and_progress()
            
            for book in books:
                # Save book metadata
                upsert_book(
                    asin=book["asin"],
                    title=book["title"],
                    authors=book.get("authors", []),
                    total_pages=book.get("totalPages"),
                    cover_url=book.get("coverUrl")
                )
                
                # Record progress if we have position data
                if book.get("currentPosition") is not None:
                    record_progress(
                        asin=book["asin"],
                        position=book["currentPosition"],
                        percent=book.get("percentComplete", 0)
                    )
            
            logger.info(f"Scraped {len(books)} books")
            
            return {
                "success": True,
                "books_scraped": len(books),
                "timestamp": datetime.now().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Scrape failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


# Singleton scraper instance
_scraper: KindleScraper = None

async def get_scraper() -> KindleScraper:
    """Get or create scraper singleton."""
    global _scraper
    if _scraper is None:
        _scraper = KindleScraper()
        await _scraper.init_browser()
    return _scraper

async def run_scrape() -> dict:
    """Run a scrape operation."""
    scraper = await get_scraper()
    return await scraper.scrape_and_save()
```

### 1.7 FastAPI Application

#### src/models.py
```python
from pydantic import BaseModel
from typing import Optional
from datetime import datetime

class HealthResponse(BaseModel):
    status: str
    timestamp: str
    last_scrape: Optional[str]

class TodayResponse(BaseModel):
    date: str
    pages_read: int
    page_goal: int
    goal_met: bool
    goal_met_at: Optional[str]
    pages_remaining: int

class BookResponse(BaseModel):
    asin: str
    title: str
    authors: list[str]
    total_pages: Optional[int]
    cover_url: Optional[str]
    current_position: Optional[int]
    percent_complete: Optional[float]
    last_read: Optional[str]

class LibraryResponse(BaseModel):
    books: list[BookResponse]
    count: int

class RefreshResponse(BaseModel):
    success: bool
    books_scraped: Optional[int]
    error: Optional[str]
    timestamp: str

class SettingsResponse(BaseModel):
    daily_page_goal: int
    day_reset_hour: int

class SettingsUpdate(BaseModel):
    daily_page_goal: Optional[int] = None
    day_reset_hour: Optional[int] = None
```

#### src/main.py
```python
import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime
from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .database import init_db, get_today_stats, get_library, get_setting, set_setting
from .scraper import run_scrape, get_scraper
from .models import (
    HealthResponse, TodayResponse, LibraryResponse, BookResponse,
    RefreshResponse, SettingsResponse, SettingsUpdate
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Track last scrape time
last_scrape_time: str = None

async def scheduled_scrape():
    """Background task for periodic scraping."""
    global last_scrape_time
    while True:
        try:
            result = await run_scrape()
            if result["success"]:
                last_scrape_time = result["timestamp"]
            logger.info(f"Scheduled scrape: {result}")
        except Exception as e:
            logger.error(f"Scheduled scrape error: {e}")
        
        await asyncio.sleep(settings.scrape_interval_minutes * 60)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown lifecycle."""
    # Startup
    init_db()
    logger.info("Database initialized")
    
    # Start background scraper
    scrape_task = asyncio.create_task(scheduled_scrape())
    logger.info("Background scraper started")
    
    yield
    
    # Shutdown
    scrape_task.cancel()
    scraper = await get_scraper()
    await scraper.close()

app = FastAPI(
    title="Read-to-Unlock API",
    description="Kindle reading progress tracker for app unlocking",
    version="1.0.0",
    lifespan=lifespan
)

# CORS for iOS app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Simple API key auth
async def verify_api_key(x_api_key: str = Header(None)):
    if settings.api_secret_key != "change-me-in-production":
        if x_api_key != settings.api_secret_key:
            raise HTTPException(status_code=401, detail="Invalid API key")
    return True

# Routes

@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    return HealthResponse(
        status="healthy",
        timestamp=datetime.now().isoformat(),
        last_scrape=last_scrape_time
    )

@app.get("/today", response_model=TodayResponse)
async def get_today(authorized: bool = Depends(verify_api_key)):
    """
    Get today's reading progress.
    This is the primary endpoint the iOS app will poll.
    """
    stats = get_today_stats()
    return TodayResponse(**stats)

@app.get("/library", response_model=LibraryResponse)
async def get_user_library(authorized: bool = Depends(verify_api_key)):
    """Get all books with their reading progress."""
    books = get_library()
    return LibraryResponse(
        books=[BookResponse(**b) for b in books],
        count=len(books)
    )

@app.get("/progress/{asin}", response_model=BookResponse)
async def get_book_progress(asin: str, authorized: bool = Depends(verify_api_key)):
    """Get progress for a specific book."""
    books = get_library()
    for book in books:
        if book["asin"] == asin:
            return BookResponse(**book)
    raise HTTPException(status_code=404, detail="Book not found")

@app.post("/refresh", response_model=RefreshResponse)
async def trigger_refresh(authorized: bool = Depends(verify_api_key)):
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
async def get_settings(authorized: bool = Depends(verify_api_key)):
    """Get current settings."""
    return SettingsResponse(
        daily_page_goal=int(get_setting("daily_page_goal") or settings.daily_page_goal),
        day_reset_hour=int(get_setting("day_reset_hour") or settings.day_reset_hour)
    )

@app.put("/settings", response_model=SettingsResponse)
async def update_settings(
    update: SettingsUpdate, 
    authorized: bool = Depends(verify_api_key)
):
    """Update settings."""
    if update.daily_page_goal is not None:
        if update.daily_page_goal < 1 or update.daily_page_goal > 1000:
            raise HTTPException(400, "daily_page_goal must be between 1 and 1000")
        set_setting("daily_page_goal", str(update.daily_page_goal))
    
    if update.day_reset_hour is not None:
        if update.day_reset_hour < 0 or update.day_reset_hour > 23:
            raise HTTPException(400, "day_reset_hour must be between 0 and 23")
        set_setting("day_reset_hour", str(update.day_reset_hour))
    
    return await get_settings()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=settings.api_host, port=settings.api_port)
```

### 1.8 Setup Scripts

#### scripts/setup.sh
```bash
#!/bin/bash
set -e

echo "=== Read-to-Unlock Pi Setup ==="

# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y \
    python3 python3-pip python3-venv \
    libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libasound2 libpango-1.0-0 \
    libcairo2 libatspi2.0-0

# Create project directory
mkdir -p /home/pi/read-to-unlock
cd /home/pi/read-to-unlock

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install --upgrade pip
pip install \
    fastapi \
    uvicorn[standard] \
    playwright \
    pydantic \
    pydantic-settings \
    python-dotenv

# Install Playwright browsers
playwright install chromium
playwright install-deps chromium

# Create data directories
mkdir -p data/browser_profile

# Copy env example
cp .env.example .env

echo ""
echo "=== Setup Complete ==="
echo "1. Edit .env with your Amazon credentials"
echo "2. Run: python scripts/login.py (with display attached)"
echo "3. Run: ./scripts/install_service.sh"
```

#### scripts/login.py
```python
#!/usr/bin/env python3
"""
One-time login script. Run with a display attached.
BROWSER_HEADLESS must be false.
"""
import asyncio
import sys
sys.path.insert(0, '/home/pi/read-to-unlock')

from src.config import settings
from src.scraper import KindleScraper

async def main():
    print("=== Kindle Login Helper ===")
    print("This will open a browser for you to log in to Amazon.")
    print("Complete any 2FA/CAPTCHA prompts manually.")
    print()
    
    # Force headless off for login
    settings.browser_headless = False
    
    scraper = KindleScraper()
    await scraper.init_browser()
    
    try:
        if await scraper.is_logged_in():
            print("✓ Already logged in!")
        else:
            print("Starting login process...")
            await scraper.login(settings.amazon_email, settings.amazon_password)
            print("✓ Login successful! Session saved.")
        
        # Test scrape
        print("\nTesting scrape...")
        result = await scraper.scrape_and_save()
        print(f"✓ Scraped {result.get('books_scraped', 0)} books")
        
    finally:
        await scraper.close()
    
    print("\n=== Done! You can now run headless. ===")

if __name__ == "__main__":
    asyncio.run(main())
```

#### scripts/install_service.sh
```bash
#!/bin/bash
set -e

echo "Installing systemd services..."

# Copy service files
sudo cp systemd/read-to-unlock.service /etc/systemd/system/
sudo cp systemd/read-to-unlock-scraper.timer /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start services
sudo systemctl enable read-to-unlock
sudo systemctl start read-to-unlock

echo "✓ Services installed and started"
echo ""
echo "Check status: sudo systemctl status read-to-unlock"
echo "View logs: sudo journalctl -u read-to-unlock -f"
```

#### systemd/read-to-unlock.service
```ini
[Unit]
Description=Read-to-Unlock API Server
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/read-to-unlock
Environment=PATH=/home/pi/read-to-unlock/venv/bin
ExecStart=/home/pi/read-to-unlock/venv/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### 1.9 Requirements

#### requirements.txt
```
fastapi>=0.109.0
uvicorn[standard]>=0.27.0
playwright>=1.41.0
pydantic>=2.5.0
pydantic-settings>=2.1.0
python-dotenv>=1.0.0
```

---

## Part 2: iOS App

### 2.1 Project Overview

**Name**: ReadToUnlock (or your preferred name)
**Minimum iOS**: 16.0
**Frameworks**: SwiftUI, FamilyControls, ManagedSettings, DeviceActivity

### 2.2 Xcode Project Structure

```
ReadToUnlock/
├── ReadToUnlock.xcodeproj
├── ReadToUnlock/
│   ├── ReadToUnlockApp.swift           # App entry point
│   ├── ContentView.swift                # Main UI
│   ├── Info.plist
│   ├── ReadToUnlock.entitlements
│   │
│   ├── Models/
│   │   ├── ReadingProgress.swift        # API response models
│   │   └── AppState.swift               # App state management
│   │
│   ├── Services/
│   │   ├── APIService.swift             # Pi API client
│   │   ├── ShieldManager.swift          # ManagedSettings wrapper
│   │   └── SettingsStore.swift          # UserDefaults persistence
│   │
│   ├── Views/
│   │   ├── SetupView.swift              # Onboarding/permissions
│   │   ├── DashboardView.swift          # Main reading progress
│   │   ├── AppPickerView.swift          # Select apps to block
│   │   ├── SettingsView.swift           # Configuration
│   │   └── Components/
│   │       ├── ProgressRing.swift
│   │       └── BookCard.swift
│   │
│   └── Extensions/
│       └── Date+Extensions.swift
│
├── ShieldConfiguration/                  # App Extension
│   ├── ShieldConfigurationExtension.swift
│   └── Info.plist
│
├── DeviceActivityMonitor/               # App Extension
│   ├── DeviceActivityMonitorExtension.swift
│   └── Info.plist
│
└── Shared/
    └── SharedConstants.swift            # App group constants
```

### 2.3 Required Entitlements

#### ReadToUnlock.entitlements
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.family-controls</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.yourcompany.readtounlock</string>
    </array>
</dict>
</plist>
```

**IMPORTANT**: You must request the Family Controls entitlement from Apple:
1. Go to https://developer.apple.com/contact/request/family-controls-distribution
2. Fill out the request form explaining your app's purpose
3. Wait 2-6 weeks for approval
4. Once approved, add the entitlement in Signing & Capabilities

### 2.4 Info.plist Additions

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>ReadToUnlock needs to connect to your reading tracker on the local network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_http._tcp</string>
</array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.yourcompany.readtounlock.refresh</string>
</array>
```

### 2.5 Core Implementation Files

#### ReadToUnlockApp.swift
```swift
import SwiftUI
import FamilyControls
import BackgroundTasks

@main
struct ReadToUnlockApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        // Register background task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.yourcompany.readtounlock.refresh",
            using: nil
        ) { task in
            self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .task {
                    await requestAuthorization()
                    await appState.refreshProgress()
                    scheduleBackgroundRefresh()
                }
        }
    }
    
    private func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            print("FamilyControls authorized")
        } catch {
            print("FamilyControls authorization failed: \(error)")
        }
    }
    
    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.yourcompany.readtounlock.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule background refresh: \(error)")
        }
    }
    
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // Schedule next
        
        let refreshTask = Task {
            await appState.refreshProgress()
        }
        
        task.expirationHandler = {
            refreshTask.cancel()
        }
        
        Task {
            await refreshTask.value
            task.setTaskCompleted(success: true)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if appState.isSetupComplete {
                DashboardView()
            } else {
                SetupView()
            }
        }
    }
}
```

#### Models/AppState.swift
```swift
import SwiftUI
import FamilyControls
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var todayProgress: TodayProgress?
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var isSetupComplete: Bool
    @Published var blockedApps = FamilyActivitySelection()
    
    private let apiService: APIService
    private let shieldManager: ShieldManager
    private let settings: SettingsStore
    
    init() {
        self.settings = SettingsStore()
        self.apiService = APIService(settings: settings)
        self.shieldManager = ShieldManager()
        self.isSetupComplete = settings.isSetupComplete
        self.blockedApps = settings.blockedApps
    }
    
    var goalMet: Bool {
        todayProgress?.goalMet ?? false
    }
    
    func refreshProgress() async {
        isLoading = true
        lastError = nil
        
        do {
            todayProgress = try await apiService.getTodayProgress()
            updateShields()
        } catch {
            lastError = error.localizedDescription
            print("Refresh error: \(error)")
        }
        
        isLoading = false
    }
    
    func triggerManualRefresh() async {
        isLoading = true
        
        do {
            _ = try await apiService.triggerRefresh()
            try await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2s for scrape
            await refreshProgress()
        } catch {
            lastError = error.localizedDescription
        }
        
        isLoading = false
    }
    
    func updateBlockedApps(_ selection: FamilyActivitySelection) {
        blockedApps = selection
        settings.blockedApps = selection
        updateShields()
    }
    
    func completeSetup() {
        settings.isSetupComplete = true
        isSetupComplete = true
        updateShields()
    }
    
    private func updateShields() {
        if goalMet {
            shieldManager.removeAllShields()
        } else {
            shieldManager.applyShields(to: blockedApps)
        }
    }
}
```

#### Models/ReadingProgress.swift
```swift
import Foundation

struct TodayProgress: Codable {
    let date: String
    let pagesRead: Int
    let pageGoal: Int
    let goalMet: Bool
    let goalMetAt: String?
    let pagesRemaining: Int
    
    enum CodingKeys: String, CodingKey {
        case date
        case pagesRead = "pages_read"
        case pageGoal = "page_goal"
        case goalMet = "goal_met"
        case goalMetAt = "goal_met_at"
        case pagesRemaining = "pages_remaining"
    }
}

struct Book: Codable, Identifiable {
    let asin: String
    let title: String
    let authors: [String]
    let totalPages: Int?
    let coverUrl: String?
    let currentPosition: Int?
    let percentComplete: Double?
    let lastRead: String?
    
    var id: String { asin }
    
    enum CodingKeys: String, CodingKey {
        case asin, title, authors
        case totalPages = "total_pages"
        case coverUrl = "cover_url"
        case currentPosition = "current_position"
        case percentComplete = "percent_complete"
        case lastRead = "last_read"
    }
}

struct LibraryResponse: Codable {
    let books: [Book]
    let count: Int
}

struct RefreshResponse: Codable {
    let success: Bool
    let booksScraped: Int?
    let error: String?
    let timestamp: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case booksScraped = "books_scraped"
        case error, timestamp
    }
}

struct APISettings: Codable {
    let dailyPageGoal: Int
    let dayResetHour: Int
    
    enum CodingKeys: String, CodingKey {
        case dailyPageGoal = "daily_page_goal"
        case dayResetHour = "day_reset_hour"
    }
}
```

#### Services/APIService.swift
```swift
import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case serverError(Int)
    case decodingError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code):
            return "Server error: \(code)"
        case .decodingError(let error):
            return "Data error: \(error.localizedDescription)"
        }
    }
}

class APIService {
    private let settings: SettingsStore
    private let session: URLSession
    
    init(settings: SettingsStore) {
        self.settings = settings
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    private var baseURL: URL? {
        guard let urlString = settings.serverURL, !urlString.isEmpty else {
            return nil
        }
        return URL(string: urlString)
    }
    
    private func request<T: Decodable>(_ endpoint: String, method: String = "GET") async throws -> T {
        guard let baseURL = baseURL else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = settings.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.serverError(httpResponse.statusCode)
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
    
    func getTodayProgress() async throws -> TodayProgress {
        try await request("/today")
    }
    
    func getLibrary() async throws -> LibraryResponse {
        try await request("/library")
    }
    
    func triggerRefresh() async throws -> RefreshResponse {
        try await request("/refresh", method: "POST")
    }
    
    func getSettings() async throws -> APISettings {
        try await request("/settings")
    }
    
    func testConnection() async throws -> Bool {
        let _: TodayProgress = try await request("/today")
        return true
    }
}
```

#### Services/ShieldManager.swift
```swift
import ManagedSettings
import FamilyControls

class ShieldManager {
    private let store = ManagedSettingsStore()
    
    func applyShields(to selection: FamilyActivitySelection) {
        let applications = selection.applicationTokens
        let categories = selection.categoryTokens
        
        store.shield.applications = applications.isEmpty ? nil : applications
        store.shield.applicationCategories = categories.isEmpty ? nil : 
            ShieldSettings.ActivityCategoryPolicy.specific(categories)
        
        store.shield.webDomains = selection.webDomainTokens
    }
    
    func removeAllShields() {
        store.clearAllSettings()
    }
    
    func shieldAllExcept(_ allowedApps: Set<ApplicationToken>) {
        store.shield.applicationCategories = .all(except: allowedApps)
    }
}
```

#### Services/SettingsStore.swift
```swift
import Foundation
import FamilyControls

class SettingsStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // App Group for sharing with extensions
    private static let appGroup = "group.com.yourcompany.readtounlock"
    
    init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
    }
    
    // MARK: - Server Configuration
    
    var serverURL: String? {
        get { defaults.string(forKey: "serverURL") }
        set { defaults.set(newValue, forKey: "serverURL") }
    }
    
    var apiKey: String? {
        get { defaults.string(forKey: "apiKey") }
        set { defaults.set(newValue, forKey: "apiKey") }
    }
    
    // MARK: - App State
    
    var isSetupComplete: Bool {
        get { defaults.bool(forKey: "isSetupComplete") }
        set { defaults.set(newValue, forKey: "isSetupComplete") }
    }
    
    var dailyPageGoal: Int {
        get { defaults.integer(forKey: "dailyPageGoal").nonZero ?? 30 }
        set { defaults.set(newValue, forKey: "dailyPageGoal") }
    }
    
    // MARK: - Blocked Apps
    
    var blockedApps: FamilyActivitySelection {
        get {
            guard let data = defaults.data(forKey: "blockedApps"),
                  let selection = try? decoder.decode(FamilyActivitySelection.self, from: data)
            else {
                return FamilyActivitySelection()
            }
            return selection
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: "blockedApps")
            }
        }
    }
    
    // MARK: - Cache
    
    var cachedProgress: TodayProgress? {
        get {
            guard let data = defaults.data(forKey: "cachedProgress"),
                  let progress = try? decoder.decode(TodayProgress.self, from: data)
            else { return nil }
            return progress
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: "cachedProgress")
            }
        }
    }
    
    var lastSyncTime: Date? {
        get { defaults.object(forKey: "lastSyncTime") as? Date }
        set { defaults.set(newValue, forKey: "lastSyncTime") }
    }
}

extension Int {
    var nonZero: Int? {
        self == 0 ? nil : self
    }
}
```

#### Views/SetupView.swift
```swift
import SwiftUI
import FamilyControls

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var isTestingConnection = false
    @State private var connectionError: String?
    @State private var currentStep = 0
    
    private let settings = SettingsStore()
    
    var body: some View {
        NavigationStack {
            VStack {
                // Step indicator
                HStack {
                    ForEach(0..<3) { step in
                        Circle()
                            .fill(step <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
                .padding()
                
                TabView(selection: $currentStep) {
                    // Step 1: Server Setup
                    serverSetupView
                        .tag(0)
                    
                    // Step 2: App Selection
                    appSelectionView
                        .tag(1)
                    
                    // Step 3: Confirmation
                    confirmationView
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Setup")
        }
    }
    
    private var serverSetupView: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Connect to Your Pi")
                .font(.title2.bold())
            
            Text("Enter the URL of your Raspberry Pi running the Read-to-Unlock server.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .placeholder(when: serverURL.isEmpty) {
                        Text("http://192.168.1.100:8080")
                    }
                
                TextField("API Key (optional)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
            }
            .padding(.horizontal)
            
            if let error = connectionError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            Button(action: testConnection) {
                if isTestingConnection {
                    ProgressView()
                } else {
                    Text("Test Connection")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverURL.isEmpty || isTestingConnection)
            
            Spacer()
        }
        .padding()
    }
    
    private var appSelectionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Select Apps to Block")
                .font(.title2.bold())
            
            Text("Choose which apps will be blocked until you complete your daily reading goal.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            FamilyActivityPicker(selection: $appState.blockedApps)
                .frame(maxHeight: 400)
            
            Button("Continue") {
                withAnimation {
                    currentStep = 2
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.blockedApps.applicationTokens.isEmpty && 
                      appState.blockedApps.categoryTokens.isEmpty)
            
            Spacer()
        }
        .padding()
    }
    
    private var confirmationView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("You're All Set!")
                .font(.title2.bold())
            
            VStack(alignment: .leading, spacing: 12) {
                Label("Server connected", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                
                Label("\(appState.blockedApps.applicationTokens.count) apps will be blocked", 
                      systemImage: "app.badge.checkmark")
                
                Label("Read \(settings.dailyPageGoal) pages daily to unlock", 
                      systemImage: "book.fill")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            
            Button("Start Using ReadToUnlock") {
                appState.completeSetup()
            }
            .buttonStyle(.borderedProminent)
            
            Spacer()
        }
        .padding()
    }
    
    private func testConnection() {
        isTestingConnection = true
        connectionError = nil
        
        settings.serverURL = serverURL
        settings.apiKey = apiKey.isEmpty ? nil : apiKey
        
        Task {
            do {
                let service = APIService(settings: settings)
                _ = try await service.testConnection()
                
                await MainActor.run {
                    isTestingConnection = false
                    withAnimation {
                        currentStep = 1
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    connectionError = error.localizedDescription
                }
            }
        }
    }
}

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
```

#### Views/DashboardView.swift
```swift
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingSettings = false
    @State private var showingAppPicker = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Progress Ring
                    progressSection
                    
                    // Status Card
                    statusCard
                    
                    // Quick Actions
                    actionButtons
                    
                    // Last Sync
                    if let error = appState.lastError {
                        errorBanner(error)
                    }
                }
                .padding()
            }
            .navigationTitle("ReadToUnlock")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingAppPicker) {
                AppPickerView()
            }
            .refreshable {
                await appState.refreshProgress()
            }
        }
    }
    
    private var progressSection: some View {
        VStack(spacing: 16) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 20)
                
                // Progress ring
                Circle()
                    .trim(from: 0, to: progressPercentage)
                    .stroke(
                        appState.goalMet ? Color.green : Color.blue,
                        style: StrokeStyle(lineWidth: 20, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: progressPercentage)
                
                // Center content
                VStack(spacing: 4) {
                    if appState.isLoading {
                        ProgressView()
                    } else {
                        Text("\(appState.todayProgress?.pagesRead ?? 0)")
                            .font(.system(size: 48, weight: .bold))
                        
                        Text("of \(appState.todayProgress?.pageGoal ?? 30) pages")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 200, height: 200)
            
            if appState.goalMet {
                Label("Goal Complete!", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundColor(.green)
            } else {
                Text("\(appState.todayProgress?.pagesRemaining ?? 30) pages to go")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: appState.goalMet ? "lock.open.fill" : "lock.fill")
                    .foregroundColor(appState.goalMet ? .green : .red)
                
                Text(appState.goalMet ? "Apps Unlocked" : "Apps Blocked")
                    .font(.headline)
                
                Spacer()
            }
            
            Divider()
            
            HStack {
                Text("Blocked apps:")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(appState.blockedApps.applicationTokens.count)")
                    .fontWeight(.semibold)
                
                Button(action: { showingAppPicker = true }) {
                    Image(systemName: "pencil")
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: {
                Task {
                    await appState.triggerManualRefresh()
                }
            }) {
                Label("Sync Now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.isLoading)
            
            Button(action: openKindle) {
                Label("Open Kindle", systemImage: "book.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func errorBanner(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var progressPercentage: CGFloat {
        guard let progress = appState.todayProgress else { return 0 }
        return min(1.0, CGFloat(progress.pagesRead) / CGFloat(progress.pageGoal))
    }
    
    private func openKindle() {
        if let url = URL(string: "kindle://") {
            UIApplication.shared.open(url)
        }
    }
}
```

#### Views/AppPickerView.swift
```swift
import SwiftUI
import FamilyControls

struct AppPickerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selection = FamilyActivitySelection()
    
    var body: some View {
        NavigationStack {
            VStack {
                FamilyActivityPicker(selection: $selection)
            }
            .navigationTitle("Select Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        appState.updateBlockedApps(selection)
                        dismiss()
                    }
                }
            }
            .onAppear {
                selection = appState.blockedApps
            }
        }
    }
}
```

#### Views/SettingsView.swift
```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var dailyGoal: Int = 30
    
    private let settings = SettingsStore()
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    
                    TextField("API Key", text: $apiKey)
                        .autocapitalization(.none)
                }
                
                Section("Reading Goal") {
                    Stepper("Daily goal: \(dailyGoal) pages", value: $dailyGoal, in: 1...500)
                }
                
                Section {
                    Button("Reset Setup", role: .destructive) {
                        settings.isSetupComplete = false
                        appState.isSetupComplete = false
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
            .onAppear {
                serverURL = settings.serverURL ?? ""
                apiKey = settings.apiKey ?? ""
                dailyGoal = settings.dailyPageGoal
            }
        }
    }
    
    private func saveSettings() {
        settings.serverURL = serverURL
        settings.apiKey = apiKey.isEmpty ? nil : apiKey
        settings.dailyPageGoal = dailyGoal
    }
}
```

### 2.6 Shield Configuration Extension

Create a new target: File → New → Target → Shield Configuration Extension

#### ShieldConfiguration/ShieldConfigurationExtension.swift
```swift
import ManagedSettingsUI
import ManagedSettings
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            backgroundColor: UIColor.systemBackground,
            icon: UIImage(systemName: "book.closed.fill"),
            title: ShieldConfiguration.Label(
                text: "Read First! 📚",
                color: UIColor.label
            ),
            subtitle: ShieldConfiguration.Label(
                text: "Complete your daily reading goal to unlock this app.",
                color: UIColor.secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Open Kindle",
                color: UIColor.white
            ),
            primaryButtonBackgroundColor: UIColor.systemGreen,
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Check Progress",
                color: UIColor.systemBlue
            )
        )
    }
    
    override func configuration(shielding application: Application, 
                                in category: ActivityCategory) -> ShieldConfiguration {
        configuration(shielding: application)
    }
    
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            backgroundColor: UIColor.systemBackground,
            title: ShieldConfiguration.Label(
                text: "Read First! 📚",
                color: UIColor.label
            ),
            subtitle: ShieldConfiguration.Label(
                text: "Complete your daily reading goal to access this site.",
                color: UIColor.secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Open Kindle",
                color: UIColor.white
            ),
            primaryButtonBackgroundColor: UIColor.systemGreen
        )
    }
    
    override func configuration(shielding webDomain: WebDomain, 
                                in category: ActivityCategory) -> ShieldConfiguration {
        configuration(shielding: webDomain)
    }
}
```

### 2.7 Shield Action Extension (Optional)

For handling button taps on shields, create another target: File → New → Target → Shield Action Extension

#### ShieldAction/ShieldActionExtension.swift
```swift
import ManagedSettingsUI
import ManagedSettings

class ShieldActionExtension: ShieldActionDelegate {
    
    override func handle(action: ShieldAction, 
                         for application: ApplicationToken, 
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            // Open Kindle
            completionHandler(.defer)
            
        case .secondaryButtonPressed:
            // Open main app to check progress
            completionHandler(.defer)
            
        @unknown default:
            completionHandler(.close)
        }
    }
}
```

---

## Part 3: Deployment & Testing

### 3.1 Pi Deployment Checklist

```bash
# 1. Flash Raspberry Pi OS Lite (64-bit, Bookworm) to SD card

# 2. First boot setup
sudo raspi-config
# - Enable SSH
# - Connect to WiFi
# - Set timezone

# 3. Clone/copy project files to Pi
scp -r read-to-unlock/ pi@<pi-ip>:/home/pi/

# 4. Run setup
cd /home/pi/read-to-unlock
chmod +x scripts/*.sh
./scripts/setup.sh

# 5. Configure environment
nano .env
# Fill in AMAZON_EMAIL, AMAZON_PASSWORD, API_SECRET_KEY

# 6. Initial login (requires display or VNC)
# If headless, temporarily enable VNC:
sudo raspi-config  # Interface Options → VNC → Enable
# Connect via VNC viewer, then:
BROWSER_HEADLESS=false python scripts/login.py

# 7. Install systemd service
./scripts/install_service.sh

# 8. Verify
curl http://localhost:8080/health
curl http://localhost:8080/today
```

### 3.2 iOS Testing Notes

1. **Simulator won't work** - Screen Time APIs require physical device
2. **TestFlight requires entitlement approval** - Use development builds until approved
3. **First launch** requires user to authorize FamilyControls in Settings
4. **Debug shields** by using `.individual` authorization (easier to bypass for testing)

### 3.3 Network Setup Options

**Option A: Local Network Only (Simplest)**
- Pi and iPhone on same WiFi
- Use Pi's local IP: `http://192.168.x.x:8080`
- Works only at home

**Option B: Tailscale (Recommended)**
```bash
# On Pi
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Note the Tailscale IP (e.g., 100.x.x.x)
# Use this IP in iOS app config
```

**Option C: Cloudflare Tunnel (Public Access)**
```bash
# On Pi
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-archive-keyring.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install cloudflared

cloudflared tunnel login
cloudflared tunnel create readtounlock
cloudflared tunnel route dns readtounlock reading.yourdomain.com
```

---

## Part 4: Known Limitations & Gotchas

### 4.1 Kindle Scraping Limitations

- **IndexedDB access may fail** - Fall back to DOM scraping
- **Amazon may require re-login** - Check session validity periodically
- **2FA/CAPTCHA** - Requires manual intervention; keep browser profile persistent
- **Rate limiting** - Don't scrape more than every 15-30 minutes
- **Page count estimation** - Kindle uses "locations" not pages; conversion is approximate

### 4.2 iOS Screen Time Limitations

- **Not a hard lock** - User can revoke FamilyControls permission in Settings
- **Extension memory limit** - Shield extensions have 6MB RAM limit
- **No programmatic unlock** - Can only remove shields, can't prevent Settings bypass
- **Background refresh unreliable** - iOS may delay or skip background tasks

### 4.3 Critical Implementation Notes

1. **Pi 5 with default kernel breaks Box86** - Only relevant if using Wine approach; Playwright doesn't need this

2. **Entitlement approval takes weeks** - Apply immediately at start of project

3. **Persist FamilyActivitySelection carefully** - Tokens are opaque and can change

4. **Handle offline gracefully** - Cache last known progress, use optimistic UI

5. **Day reset logic** - Both Pi and iOS must agree on 4 AM boundary calculation

---

## Part 5: Future Enhancements

- [ ] Widget showing today's progress
- [ ] Apple Watch companion app
- [ ] Push notifications when goal is met
- [ ] Multiple reading sources (Audible, Apple Books, physical via manual entry)
- [ ] Reading streaks and statistics
- [ ] Social features / accountability partners
- [ ] Shortcut actions for Siri integration
