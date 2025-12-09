"""Kindle Cloud Reader scraper using Playwright."""

import asyncio
import logging
from datetime import datetime
from typing import Optional

from playwright.async_api import async_playwright, Page, BrowserContext

from .config import settings
from .database import upsert_book, record_progress

logger = logging.getLogger(__name__)


class KindleScraper:
    """Scrapes reading progress from Kindle Cloud Reader."""

    CLOUD_READER_URL = "https://read.amazon.com/"
    LIBRARY_URL = "https://read.amazon.com/kindle-library"

    def __init__(self):
        self._playwright = None
        self.context: Optional[BrowserContext] = None
        self.page: Optional[Page] = None

    async def init_browser(self) -> None:
        """Initialize persistent browser context."""
        self._playwright = await async_playwright().start()

        browser_profile = settings.get_absolute_browser_profile_path()
        logger.info(f"Using browser profile at: {browser_profile}")

        # Persistent context preserves login session
        self.context = await self._playwright.chromium.launch_persistent_context(
            user_data_dir=str(browser_profile),
            headless=settings.browser_headless,
            viewport={"width": 1280, "height": 720},
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/121.0.0.0 Safari/537.36"
            ),
            # Disable WebAuthn/passkey to prevent system prompts during login
            args=["--disable-features=WebAuthentication,WebAuthenticationConditionalUI"],
        )

        self.page = await self.context.new_page()

        # Disable WebAuthn/passkey by overriding the credentials API
        # This prevents macOS from showing the passkey dialog
        await self.page.add_init_script("""
            // Disable WebAuthn to prevent passkey prompts
            if (navigator.credentials) {
                navigator.credentials.get = async () => { throw new Error('WebAuthn disabled'); };
                navigator.credentials.create = async () => { throw new Error('WebAuthn disabled'); };
            }
            // Also disable PublicKeyCredential if it exists
            if (window.PublicKeyCredential) {
                window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = async () => false;
                window.PublicKeyCredential.isConditionalMediationAvailable = async () => false;
            }
        """)

        logger.info("Browser initialized")

    async def close(self) -> None:
        """Close browser context."""
        if self.context:
            await self.context.close()
            self.context = None
            self.page = None
        if self._playwright:
            await self._playwright.stop()
            self._playwright = None
        logger.info("Browser closed")

    async def is_logged_in(self) -> bool | str:
        """
        Check if we have a valid Amazon session by navigating to library.

        Returns:
            True: Successfully logged in and on library page
            False: Not logged in, can attempt login
            "2fa": Credentials were submitted but 2FA/verification is required
        """
        if not self.page:
            return False

        # Auth pages that require user interaction
        auth_pages = [
            "signin",
            "ap/signin",
            "ap/mfa",      # Multi-factor auth
            "ap/cvf",      # Customer verification
            "ap/dcq",      # Device challenge questions
            "primememberpromo",
            "verification",
            "challenge",
        ]

        # Navigate to library URL first
        try:
            await self.page.goto(self.LIBRARY_URL, wait_until="networkidle")
            await asyncio.sleep(2)
        except Exception as e:
            logger.warning(f"Initial navigation failed: {e}")

        # Navigate through the login flow (browser has saved credentials from previous login)
        # Flow: landing → sign in → (maybe back to landing) → sign in → auth page → submit → library
        for attempt in range(5):
            current_url = self.page.url.lower()
            logger.info(f"Login check attempt {attempt + 1} - URL: {current_url}")

            # Success - we're on the library page (check for actual library URL, not just query param)
            if "read.amazon.com/kindle-library" in current_url:
                logger.info("Successfully reached library page")
                return True

            # On landing page - click "Sign in with your account"
            if "landing" in current_url:
                logger.info("On landing page, clicking sign in...")
                try:
                    await self.page.click('text="Sign in with your account"', timeout=5000)
                    await asyncio.sleep(2)
                except Exception as e:
                    logger.debug(f"Sign in click failed: {e}")
                continue

            # On auth page - fill credentials if needed, then submit
            if any(page in current_url for page in auth_pages):
                # Skip 2FA/verification pages - can't auto-fill those
                if any(x in current_url for x in ["ap/mfa", "ap/cvf", "ap/dcq", "challenge", "verification"]):
                    logger.warning(f"2FA/verification page detected, manual intervention required: {current_url}")
                    return "2fa"

                logger.info("On auth page, checking for login fields...")
                try:
                    # Check for email field and fill if empty
                    email_field = self.page.locator('input[type="email"], input[name="email"]')
                    if await email_field.count() > 0:
                        current_value = await email_field.first.input_value()
                        if not current_value:
                            if settings.amazon_email:
                                logger.info("Filling email...")
                                await email_field.first.fill(settings.amazon_email)
                                # Click continue if present (two-step login flow)
                                continue_btn = self.page.locator('input#continue, span#continue')
                                if await continue_btn.count() > 0:
                                    await continue_btn.first.click()
                                    await asyncio.sleep(2)
                            else:
                                logger.warning("Empty email field but no credentials configured")
                                return False

                    # Check for password field - may need to click password sign-in option first
                    password_field = self.page.locator('input[type="password"]')
                    if await password_field.count() == 0:
                        # Password field not visible - Amazon may show passkey vs password choice
                        # Look for "Sign in" button that is NOT the passkey option
                        # The passkey button typically contains "passkey" text
                        all_signin_btns = self.page.locator('button, input[type="submit"], a').filter(has_text="Sign in")
                        for i in range(await all_signin_btns.count()):
                            btn = all_signin_btns.nth(i)
                            btn_text = (await btn.text_content() or "").lower()
                            # Skip if it's the passkey button
                            if "passkey" in btn_text:
                                continue
                            # This should be the password sign-in button
                            logger.info(f"Clicking password sign-in button: '{btn_text.strip()}'")
                            await btn.click()
                            await asyncio.sleep(2)
                            break
                        # Re-check for password field
                        password_field = self.page.locator('input[type="password"]')

                    if await password_field.count() > 0:
                        current_value = await password_field.first.input_value()
                        if not current_value:
                            if settings.amazon_password:
                                logger.info("Filling password...")
                                await password_field.first.fill(settings.amazon_password)
                            else:
                                logger.warning("Empty password field but no credentials configured")
                                return False

                    # Now click submit
                    submit_btn = self.page.locator('input#signInSubmit, input[type="submit"], button[type="submit"]')
                    if await submit_btn.count() > 0:
                        logger.info("Clicking submit...")
                        await submit_btn.first.click()
                        await asyncio.sleep(3)
                    else:
                        logger.warning("No submit button found on auth page")
                except Exception as e:
                    logger.debug(f"Auth page handling failed: {e}")
                continue

            # Unknown page - try navigating to library
            logger.warning(f"On unexpected page: {current_url}")
            try:
                await self.page.goto(self.LIBRARY_URL, wait_until="networkidle")
                await asyncio.sleep(2)
            except Exception as e:
                logger.warning(f"Navigation failed: {e}")

        logger.warning("Failed to reach library page after 5 attempts")
        return False

    async def login(self, email: str, password: str) -> None:
        """
        Perform Amazon login.
        NOTE: May require manual 2FA/CAPTCHA completion.
        Run with BROWSER_HEADLESS=false for initial login.
        """
        if not self.page:
            raise RuntimeError("Browser not initialized")

        logger.info("Starting login process...")
        await self.page.goto(self.CLOUD_READER_URL)

        # Wait for and fill email
        await self.page.wait_for_selector(
            'input[type="email"], input[name="email"]',
            timeout=30000,
        )
        await self.page.fill('input[type="email"], input[name="email"]', email)

        # Click continue/next if separate email step
        continue_btn = self.page.locator('input#continue, span#continue')
        if await continue_btn.count() > 0:
            await continue_btn.first.click()

        # Fill password
        await self.page.wait_for_selector('input[type="password"]', timeout=30000)
        await self.page.fill('input[type="password"]', password)

        # Submit
        await self.page.click('input#signInSubmit, input[type="submit"]')

        # Wait for redirect to cloud reader or 2FA prompt
        await self.page.wait_for_url(
            lambda url: (
                "read.amazon.com" in url
                or "ap/mfa" in url
                or "ap/cvf" in url
            ),
            timeout=60000,
        )

        if "mfa" in self.page.url or "cvf" in self.page.url:
            logger.warning("2FA/CAPTCHA required - complete manually in browser")
            # Wait up to 5 minutes for manual completion
            await self.page.wait_for_url("**/read.amazon.com/**", timeout=300000)

        logger.info("Login successful")

    async def get_book_progress_from_reader(self, asin: str) -> dict:
        """
        Open a book and extract its current page/location and total pages.
        Returns dict with 'current', 'total', 'percent'.
        """
        try:
            # Click on the book to open it
            book_el = self.page.locator(f'#library-item-option-{asin}')
            if await book_el.count() == 0:
                logger.warning(f"Book {asin} not found in library")
                return {}

            await book_el.click()

            # Wait for reader to load - look for reader-specific elements
            try:
                await self.page.wait_for_selector(
                    '#kindle-reader, [class*="reader"], [class*="Reader"], iframe[id*="reader"]',
                    timeout=10000,
                )
            except Exception:
                logger.debug(f"Reader container not found for {asin}, checking page anyway")

            await asyncio.sleep(3)  # Let content settle

            # Check for "License Limit Reached" dialog
            license_dialog = await self.page.evaluate(r"""
                () => {
                    const bodyText = document.body.innerText || '';
                    if (bodyText.includes('License Limit Reached') ||
                        bodyText.includes('exceeded the limit on the number of devices')) {
                        return true;
                    }
                    return false;
                }
            """)
            if license_dialog:
                logger.warning(f"Book {asin}: License limit reached - too many devices. Deregister a device to read this book.")
                # Try to close dialog and return to library
                try:
                    ok_btn = self.page.locator('button:has-text("Ok"), button:has-text("OK")')
                    if await ok_btn.count() > 0:
                        await ok_btn.first.click()
                        await asyncio.sleep(1)
                except Exception:
                    pass
                await self.page.goto(self.LIBRARY_URL, wait_until="networkidle")
                await asyncio.sleep(2)
                return {"error": "license_limit"}

            # Tap/click center of page to reveal UI elements (progress bar, page numbers)
            # Kindle Cloud Reader hides UI until you tap
            try:
                viewport = self.page.viewport_size
                if viewport:
                    await self.page.mouse.click(viewport["width"] // 2, viewport["height"] // 2)
                    await asyncio.sleep(1)
            except Exception as e:
                logger.debug(f"Center click failed: {e}")

            # Look for page/location info in the reader
            progress_info = await self.page.evaluate(r"""
                () => {
                    const result = {current: null, total: null, percent: null, debug: []};

                    // Helper to search for patterns in text
                    const findPattern = (text) => {
                        // "Page X of Y" pattern
                        let match = text.match(/Page\s+(\d+)\s+of\s+(\d+)/i);
                        if (match) {
                            return {current: parseInt(match[1]), total: parseInt(match[2]), type: 'page'};
                        }

                        // "Loc X of Y" or "Location X of Y" pattern
                        match = text.match(/Loc(?:ation)?\s+(\d+)\s+of\s+(\d+)/i);
                        if (match) {
                            return {current: parseInt(match[1]), total: parseInt(match[2]), type: 'location'};
                        }

                        // "X of Y" pattern (standalone)
                        match = text.match(/^(\d+)\s+of\s+(\d+)$/i);
                        if (match) {
                            return {current: parseInt(match[1]), total: parseInt(match[2]), type: 'generic'};
                        }

                        // Percentage pattern
                        match = text.match(/(\d+)%/);
                        if (match) {
                            return {percent: parseInt(match[1]), type: 'percent'};
                        }

                        return null;
                    };

                    // Search specific elements that might contain progress
                    const progressSelectors = [
                        '[class*="location"]',
                        '[class*="Location"]',
                        '[class*="page"]',
                        '[class*="Page"]',
                        '[class*="progress"]',
                        '[class*="Progress"]',
                        '[class*="position"]',
                        '[class*="Position"]',
                        '[id*="location"]',
                        '[id*="page"]',
                        '[id*="progress"]',
                        '[data-page]',
                        '[data-location]',
                        // Kindle Cloud Reader specific
                        '#kindleReader_footer',
                        '.kindleReader_pageTurnAreaRight',
                        '.kindleReader_footer',
                        '[class*="footer"]',
                        '[class*="Footer"]',
                    ];

                    for (const selector of progressSelectors) {
                        const elements = document.querySelectorAll(selector);
                        for (const el of elements) {
                            const text = (el.textContent || el.innerText || '').trim();
                            if (text.length > 0 && text.length < 50) {
                                result.debug.push({selector, text: text.substring(0, 50)});
                                const found = findPattern(text);
                                if (found) {
                                    if (found.current !== undefined) {
                                        result.current = found.current;
                                        result.total = found.total;
                                        result.percent = Math.round((found.current / found.total) * 100);
                                    } else if (found.percent !== undefined) {
                                        result.percent = found.percent;
                                        result.current = found.percent;
                                        result.total = 100;
                                    }
                                    return result;
                                }
                            }
                        }
                    }

                    // Fallback: search entire page body
                    const bodyText = document.body.innerText || '';
                    const found = findPattern(bodyText);
                    if (found) {
                        if (found.current !== undefined) {
                            result.current = found.current;
                            result.total = found.total;
                            result.percent = Math.round((found.current / found.total) * 100);
                        } else if (found.percent !== undefined) {
                            result.percent = found.percent;
                            result.current = found.percent;
                            result.total = 100;
                        }
                    }

                    return result;
                }
            """)

            if progress_info.get("debug"):
                logger.debug(f"Book {asin} found elements: {progress_info['debug'][:3]}")

            # Go back to library
            await self.page.goto(self.LIBRARY_URL, wait_until="networkidle")
            await asyncio.sleep(2)

            return progress_info

        except Exception as e:
            logger.warning(f"Failed to get progress for {asin}: {e}")
            # Try to get back to library
            try:
                await self.page.goto(self.LIBRARY_URL, wait_until="networkidle")
            except:
                pass
            return {}

    async def get_library_and_progress(self) -> list[dict]:
        """
        Extract library and reading progress from Kindle Cloud Reader.

        Returns list of books with:
        - asin, title, authors, cover_url
        - current_position (page/location)
        - percent_complete
        - last_read_timestamp
        """
        if not self.page:
            raise RuntimeError("Browser not initialized")

        # Navigate to library if not already there
        current_url = self.page.url.lower()
        if "read.amazon.com/kindle-library" not in current_url:
            await self.page.goto(self.LIBRARY_URL, wait_until="networkidle")

        # Wait for library to load - try multiple selectors
        try:
            await self.page.wait_for_selector(
                '[id*="library"], .book-list, [class*="library"], [class*="book"], [data-asin]',
                timeout=30000,
            )
        except Exception as e:
            logger.warning(f"Library selector not found, checking page content: {e}")
            # Log current URL and page title for debugging
            logger.info(f"Current URL: {self.page.url}")
            logger.info(f"Page title: {await self.page.title()}")

        await asyncio.sleep(2)  # Let dynamic content settle

        # Try to get progress data from the page's JavaScript context
        # Kindle Cloud Reader stores book data in window/React state
        progress_data = await self.page.evaluate("""
            () => {
                // Try to find progress data in various places
                const progressMap = {};

                // Method 1: Look for React fiber data
                try {
                    const libraryEl = document.querySelector('[class*="library"]');
                    if (libraryEl && libraryEl._reactRootContainer) {
                        // React 16/17
                        console.log('Found React root container');
                    }
                } catch (e) {}

                // Method 2: Look for data in window object
                try {
                    if (window.KindleLibraryStore) {
                        console.log('Found KindleLibraryStore');
                    }
                    if (window.__PRELOADED_STATE__) {
                        console.log('Found preloaded state');
                    }
                } catch (e) {}

                // Method 3: Look for localStorage data
                try {
                    for (let i = 0; i < localStorage.length; i++) {
                        const key = localStorage.key(i);
                        if (key.includes('progress') || key.includes('percent') || key.includes('reading')) {
                            console.log('localStorage key:', key);
                        }
                    }
                } catch (e) {}

                return progressMap;
            }
        """)
        logger.info(f"Progress data lookup result: {progress_data}")

        # Extract books from DOM - ASINs are in element IDs like "library-item-option-B0192CTMYG"
        books_data = await self.page.evaluate(r"""
            () => {
                const books = [];

                // Find all library item elements by ID pattern
                const libraryItems = document.querySelectorAll('[id^="library-item-option-"]');

                for (const item of libraryItems) {
                    const id = item.id;

                    // Skip sample books (IDs contain "sample")
                    if (id.includes('sample')) continue;

                    // Extract ASIN from ID: "library-item-option-B0192CTMYG" -> "B0192CTMYG"
                    const asin = id.replace('library-item-option-', '');
                    if (!asin) continue;

                    // Try to find title - look for text content in the element or nearby
                    // The title might be in an aria-label, a child element, or the text content
                    let title = 'Unknown';
                    const ariaLabel = item.getAttribute('aria-label');
                    if (ariaLabel) {
                        title = ariaLabel;
                    } else {
                        // Look for any text content that might be a title
                        const textNodes = item.querySelectorAll('span, div, p');
                        for (const node of textNodes) {
                            const text = node.textContent?.trim();
                            if (text && text.length > 3 && text.length < 200) {
                                title = text;
                                break;
                            }
                        }
                    }

                    // Try to find cover image
                    let coverUrl = null;
                    const img = item.querySelector('img');
                    if (img) {
                        coverUrl = img.src;
                    }

                    // Try to find author
                    let authors = [];
                    const authorEl = item.querySelector('[class*="author"], [class*="Author"]');
                    if (authorEl) {
                        authors = [authorEl.textContent.trim()];
                    }

                    // Try to find progress percentage
                    let percentComplete = 0;

                    // Method 1: Look for percentage-read element by ID (found in aria-labelledby)
                    const percentReadEl = document.getElementById('percentage-read-' + asin);
                    if (percentReadEl) {
                        const percentText = percentReadEl.textContent || percentReadEl.innerText || '';
                        const match = percentText.match(/(\d+)/);
                        if (match) {
                            percentComplete = parseFloat(match[1]);
                        }
                    }

                    // Method 2: Look for element with progress in class name
                    if (percentComplete === 0) {
                        const progressEl = item.querySelector('[class*="progress"], [class*="Progress"], [id*="percent"]');
                        if (progressEl) {
                            const progressText = progressEl.textContent;
                            const match = progressText.match(/(\d+)/);
                            if (match) {
                                percentComplete = parseFloat(match[1]);
                            }
                        }
                    }

                    // Method 3: Search entire item for percentage pattern
                    if (percentComplete === 0) {
                        const allText = item.innerText || item.textContent || '';
                        const percentMatch = allText.match(/(\d+)%/);
                        if (percentMatch) {
                            percentComplete = parseFloat(percentMatch[1]);
                        }
                    }

                    // Debug: check percentage element for first book
                    let debugPercentEl = null;
                    if (books.length === 0) {
                        const pEl = document.getElementById('percentage-read-' + asin);
                        debugPercentEl = pEl ? pEl.outerHTML : 'NOT FOUND';
                    }

                    books.push({
                        // Include debug info for first book
                        _debug_html: books.length === 0 ? item.outerHTML.substring(0, 500) : null,
                        _debug_text: books.length === 0 ? item.innerText : null,
                        _debug_percent_el: debugPercentEl,
                        asin: asin,
                        title: title,
                        authors: authors,
                        coverUrl: coverUrl,
                        totalPages: 100,  // Treat as 100 "units" for page tracking
                        currentPosition: percentComplete,  // Use percent as position (1% = 1 page)
                        percentComplete: percentComplete,
                        lastReadTimestamp: null
                    });
                }

                return books;
            }
        """)

        logger.info(f"Found {len(books_data)} library items with ID pattern")

        # Debug: log a sample of extracted data
        if books_data:
            first = books_data[0]
            logger.info(f"First book debug - Percent element: {first.get('_debug_percent_el', 'N/A')}")
        for book in books_data[:3]:
            logger.info(f"Sample book: {book['asin']} - {book['title'][:30]}... - {book['percentComplete']}%")

        logger.info(f"Extracted {len(books_data)} books from Kindle Cloud Reader")
        return books_data

    async def scrape_and_save(self) -> dict:
        """
        Main scrape operation - fetches data and saves to database.
        Opens each book to get actual page numbers since library doesn't show them.
        Returns summary of what was scraped.
        """
        try:
            login_status = await self.is_logged_in()
            if login_status == "2fa":
                return {
                    "success": False,
                    "error": "2FA/verification required. Run 'make login' with BROWSER_HEADLESS=false to complete manually.",
                    "timestamp": datetime.now().isoformat(),
                }
            elif not login_status:
                logger.warning("Not logged in - attempting login")
                if settings.amazon_email and settings.amazon_password:
                    await self.login(settings.amazon_email, settings.amazon_password)
                else:
                    return {
                        "success": False,
                        "error": "Not logged in and no credentials configured",
                        "timestamp": datetime.now().isoformat(),
                    }

            # Get library list (basic metadata)
            books = await self.get_library_and_progress()
            books_with_progress = 0
            books_with_license_limit = []

            # Open each book to get actual page numbers
            # Library page doesn't show page numbers - only visible when book is opened
            for book in books:
                asin = book["asin"]
                title = book["title"][:40]

                # Save book metadata first
                upsert_book(
                    asin=asin,
                    title=book["title"],
                    authors=book.get("authors", []),
                    total_pages=book.get("totalPages"),
                    cover_url=book.get("coverUrl"),
                )

                # Open book to get actual page progress
                logger.info(f"Opening book to get progress: {title}...")
                progress = await self.get_book_progress_from_reader(asin)

                # Check for license limit error
                if progress and progress.get("error") == "license_limit":
                    books_with_license_limit.append(title)
                    logger.info(f"  -> License limit (too many devices)")
                    continue

                if progress and progress.get("current") is not None:
                    current_page = progress["current"]
                    total_pages = progress.get("total", 100)
                    percent = progress.get("percent", 0)

                    # Update book with actual total pages if we got it
                    if total_pages and total_pages != 100:
                        upsert_book(
                            asin=asin,
                            title=book["title"],
                            authors=book.get("authors", []),
                            total_pages=total_pages,
                            cover_url=book.get("coverUrl"),
                        )

                    # Record progress
                    record_progress(
                        asin=asin,
                        position=current_page,
                        percent=percent,
                    )
                    books_with_progress += 1
                    logger.info(f"  -> Page {current_page} of {total_pages} ({percent}%)")
                else:
                    logger.info(f"  -> No progress data found")

            logger.info(f"Successfully scraped {len(books)} books, {books_with_progress} with progress")
            if books_with_license_limit:
                logger.warning(f"Books with license limit issues: {', '.join(books_with_license_limit)}")

            result = {
                "success": True,
                "books_scraped": len(books),
                "books_with_progress": books_with_progress,
                "timestamp": datetime.now().isoformat(),
            }
            if books_with_license_limit:
                result["license_limit_books"] = books_with_license_limit
            return result

        except Exception as e:
            logger.error(f"Scrape failed: {e}", exc_info=True)
            return {
                "success": False,
                "error": str(e),
                "timestamp": datetime.now().isoformat(),
            }

    async def scrape_and_save_streaming(self):
        """
        Streaming scrape operation - yields SSE events as each book is processed.

        Yields dicts with 'event' key:
        - started: total_books, timestamp
        - book_progress: current, total, book_title, book_asin
        - book_complete: current, total, book_title, book_asin, percent_complete, success, error
        - error: message, recoverable
        - completed: success, books_scraped, books_with_progress, duration_seconds, timestamp
        """
        import time
        start_time = time.time()

        try:
            login_status = await self.is_logged_in()
            if login_status == "2fa":
                yield {
                    "event": "error",
                    "message": "2FA/verification required. Run 'make login' with BROWSER_HEADLESS=false to complete manually.",
                    "recoverable": False,
                }
                return
            elif not login_status:
                logger.warning("Not logged in - attempting login")
                if settings.amazon_email and settings.amazon_password:
                    await self.login(settings.amazon_email, settings.amazon_password)
                else:
                    yield {
                        "event": "error",
                        "message": "Not logged in and no credentials configured",
                        "recoverable": False,
                    }
                    return

            # Get library list (basic metadata)
            books = await self.get_library_and_progress()

            # Emit started event
            yield {
                "event": "started",
                "total_books": len(books),
                "timestamp": datetime.now().isoformat(),
            }

            books_with_progress = 0
            books_with_license_limit = []

            # Open each book to get actual page numbers
            for idx, book in enumerate(books):
                asin = book["asin"]
                title = book["title"][:40]

                # Emit progress event BEFORE processing
                yield {
                    "event": "book_progress",
                    "current": idx + 1,
                    "total": len(books),
                    "book_title": title,
                    "book_asin": asin,
                }

                # Save book metadata first
                upsert_book(
                    asin=asin,
                    title=book["title"],
                    authors=book.get("authors", []),
                    total_pages=book.get("totalPages"),
                    cover_url=book.get("coverUrl"),
                )

                # Open book to get actual page progress
                logger.info(f"Opening book to get progress: {title}...")
                progress = await self.get_book_progress_from_reader(asin)

                # Determine result
                success = True
                error = None
                percent_complete = None

                # Check for license limit error
                if progress and progress.get("error") == "license_limit":
                    books_with_license_limit.append(title)
                    logger.info(f"  -> License limit (too many devices)")
                    success = False
                    error = "license_limit"
                elif progress and progress.get("current") is not None:
                    current_page = progress["current"]
                    total_pages = progress.get("total", 100)
                    percent = progress.get("percent", 0)
                    percent_complete = percent

                    # Update book with actual total pages if we got it
                    if total_pages and total_pages != 100:
                        upsert_book(
                            asin=asin,
                            title=book["title"],
                            authors=book.get("authors", []),
                            total_pages=total_pages,
                            cover_url=book.get("coverUrl"),
                        )

                    # Record progress
                    record_progress(
                        asin=asin,
                        position=current_page,
                        percent=percent,
                    )
                    books_with_progress += 1
                    logger.info(f"  -> Page {current_page} of {total_pages} ({percent}%)")
                else:
                    logger.info(f"  -> No progress data found")

                # Emit book complete event
                yield {
                    "event": "book_complete",
                    "current": idx + 1,
                    "total": len(books),
                    "book_title": title,
                    "book_asin": asin,
                    "percent_complete": percent_complete,
                    "success": success,
                    "error": error,
                }

            duration = time.time() - start_time
            logger.info(f"Successfully scraped {len(books)} books, {books_with_progress} with progress")
            if books_with_license_limit:
                logger.warning(f"Books with license limit issues: {', '.join(books_with_license_limit)}")

            # Emit completed event
            yield {
                "event": "completed",
                "success": True,
                "books_scraped": len(books),
                "books_with_progress": books_with_progress,
                "duration_seconds": round(duration, 1),
                "timestamp": datetime.now().isoformat(),
                "license_limit_books": books_with_license_limit if books_with_license_limit else None,
            }

        except Exception as e:
            logger.error(f"Scrape failed: {e}", exc_info=True)
            yield {
                "event": "error",
                "message": str(e),
                "recoverable": False,
            }


# Singleton scraper instance
_scraper: Optional[KindleScraper] = None
_scraper_lock = asyncio.Lock()


async def get_scraper() -> KindleScraper:
    """Get or create scraper singleton."""
    global _scraper
    async with _scraper_lock:
        if _scraper is None:
            _scraper = KindleScraper()
            await _scraper.init_browser()
        return _scraper


async def close_scraper() -> None:
    """Close the singleton scraper."""
    global _scraper
    async with _scraper_lock:
        if _scraper is not None:
            await _scraper.close()
            _scraper = None


async def run_scrape() -> dict:
    """Run a scrape operation."""
    scraper = await get_scraper()
    return await scraper.scrape_and_save()


async def run_scrape_streaming():
    """Run a streaming scrape operation, yielding SSE events."""
    scraper = await get_scraper()
    async for event in scraper.scrape_and_save_streaming():
        yield event
