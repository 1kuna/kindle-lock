#!/usr/bin/env python3
"""
One-time login script for Kindle Cloud Reader.

Run this with a display attached (or via VNC) to authenticate with Amazon.
The browser session will be persisted for future headless use.

Usage:
    BROWSER_HEADLESS=false python scripts/login.py
"""

import asyncio
import os
import sys

# Add parent directory to path for imports
script_dir = os.path.dirname(os.path.abspath(__file__))
project_dir = os.path.dirname(script_dir)
sys.path.insert(0, project_dir)

from src.config import settings
from src.scraper import KindleScraper
from src.database import init_db


async def main():
    print("=== Kindle Login Helper ===")
    print()
    print("This will open a browser for you to log in to Amazon.")
    print("Complete any 2FA/CAPTCHA prompts manually.")
    print()

    # Force headless off for login if not set
    if os.environ.get("BROWSER_HEADLESS", "").lower() not in ("false", "0", "no"):
        print("TIP: Run with BROWSER_HEADLESS=false to see the browser window")
        print()

    # Initialize database
    init_db()

    # Create scraper instance
    scraper = KindleScraper()

    try:
        print("Initializing browser...")
        await scraper.init_browser()

        if await scraper.is_logged_in():
            print()
            print("Already logged in to Amazon!")
        else:
            print()
            print("Not logged in. Starting login process...")
            print()

            if settings.amazon_email and settings.amazon_password:
                print(f"Using credentials from .env for: {settings.amazon_email}")
                print()
                print("NOTE: If 2FA/phone verification appears, complete it in the browser.")
                print("      The script will wait for you to finish.")
                print()
                await scraper.login(settings.amazon_email, settings.amazon_password)
            else:
                print("No credentials in .env - please log in manually in the browser window.")
                print("Navigate to https://read.amazon.com and sign in.")
                print()

            # Wait for user to complete any verification steps
            while not await scraper.is_logged_in():
                print()
                print("Waiting for login/2FA completion...")
                print("Complete the verification in the browser window.")
                print()
                input("Press Enter after completing login (or Ctrl+C to cancel)...")

        # Verify login worked
        if await scraper.is_logged_in():
            print()
            print("Login successful! Session has been saved.")
            print()

            # Test scrape
            print("Testing scrape...")
            result = await scraper.scrape_and_save()

            if result["success"]:
                print(f"Scraped {result.get('books_scraped', 0)} books")
            else:
                print(f"Scrape test failed: {result.get('error')}")
        else:
            print()
            print("Login verification failed. Please try again.")
            sys.exit(1)

    except KeyboardInterrupt:
        print()
        print("Cancelled by user")
        sys.exit(1)
    except Exception as e:
        print()
        print(f"Error: {e}")
        sys.exit(1)
    finally:
        await scraper.close()

    print()
    print("=== Done! ===")
    print()
    print("You can now run the server in headless mode:")
    print("  make dev")
    print("  # or")
    print("  python -m uvicorn src.main:app --host 0.0.0.0 --port 8080")


if __name__ == "__main__":
    asyncio.run(main())
