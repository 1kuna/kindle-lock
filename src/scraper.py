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

        # Extract books from DOM - ASINs are in element IDs like "library-item-option-B0192CTMYG"
        books_data = await self.page.evaluate("""
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
                    const progressEl = item.querySelector('[class*="progress"], [class*="Progress"]');
                    if (progressEl) {
                        const progressText = progressEl.textContent;
                        const match = progressText.match(/(\\d+)%/);
                        if (match) {
                            percentComplete = parseFloat(match[1]);
                        }
                    }

                    books.push({
                        asin: asin,
                        title: title,
                        authors: authors,
                        coverUrl: coverUrl,
                        totalPages: null,
                        currentPosition: null,
                        percentComplete: percentComplete,
                        lastReadTimestamp: null
                    });
                }

                return books;
            }
        """)

        logger.info(f"Found {len(books_data)} library items with ID pattern")

        logger.info(f"Extracted {len(books_data)} books from Kindle Cloud Reader")
        return books_data

    async def scrape_and_save(self) -> dict:
        """
        Main scrape operation - fetches data and saves to database.
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

            books = await self.get_library_and_progress()

            for book in books:
                # Save book metadata
                upsert_book(
                    asin=book["asin"],
                    title=book["title"],
                    authors=book.get("authors", []),
                    total_pages=book.get("totalPages"),
                    cover_url=book.get("coverUrl"),
                )

                # Record progress if we have position data
                if book.get("currentPosition") is not None:
                    record_progress(
                        asin=book["asin"],
                        position=book["currentPosition"],
                        percent=book.get("percentComplete", 0),
                    )

            logger.info(f"Successfully scraped and saved {len(books)} books")

            return {
                "success": True,
                "books_scraped": len(books),
                "timestamp": datetime.now().isoformat(),
            }

        except Exception as e:
            logger.error(f"Scrape failed: {e}", exc_info=True)
            return {
                "success": False,
                "error": str(e),
                "timestamp": datetime.now().isoformat(),
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
