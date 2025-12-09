#!/bin/bash
set -e

# kindle-lock container entrypoint
# Supports two modes:
#   - SETUP mode: Runs VNC server for interactive Amazon login
#   - HEADLESS mode (default): Runs the API server

cd /app

if [ "$KINDLE_SETUP_MODE" = "true" ]; then
    echo "=============================================="
    echo "  kindle-lock SETUP MODE"
    echo "=============================================="
    echo ""
    echo "Starting VNC server for Amazon login..."

    # Force browser to be visible
    export BROWSER_HEADLESS=false
    export DISPLAY=:1

    # Create VNC password file (empty for no password - internal use only)
    mkdir -p ~/.vnc
    echo "" | vncpasswd -f > ~/.vnc/passwd
    chmod 600 ~/.vnc/passwd

    # Start VNC server on display :1 (port 5901)
    vncserver :1 -geometry 1280x720 -depth 24 -SecurityTypes None -localhost no 2>&1 &

    # Wait for VNC to start
    sleep 3

    # Start fluxbox window manager
    DISPLAY=:1 fluxbox &
    sleep 1

    echo ""
    echo "=============================================="
    echo "  VNC server ready on port 5901"
    echo "  Connect via noVNC at http://<host>:6080"
    echo "=============================================="
    echo ""
    echo "Opening Kindle Cloud Reader for login..."
    echo "Complete the Amazon login process in the browser."
    echo ""

    # Run the login script which opens the browser
    # This will wait for user to complete login
    python -c "
import asyncio
from src.scraper import KindleScraper

async def setup_login():
    scraper = KindleScraper()
    await scraper.init_browser()

    if await scraper.is_logged_in():
        print('')
        print('============================================')
        print('  Already logged in! Session is valid.')
        print('============================================')
    else:
        print('Waiting for you to complete login...')
        print('(The browser window should be visible in VNC)')

        # Navigate to login page and wait for user
        success = await scraper.login()

        if success:
            print('')
            print('============================================')
            print('  Login successful!')
            print('  Session saved to browser profile.')
            print('============================================')
        else:
            print('')
            print('============================================')
            print('  Login failed or timed out.')
            print('  Please try again.')
            print('============================================')

    await scraper.close()

asyncio.run(setup_login())
"

    echo ""
    echo "You can now stop this container (Ctrl+C) and"
    echo "restart without KINDLE_SETUP_MODE to run normally."
    echo ""

    # Keep container running so user can verify
    tail -f /dev/null

else
    echo "=============================================="
    echo "  kindle-lock HEADLESS MODE"
    echo "=============================================="
    echo ""
    echo "Starting API server on ${API_HOST}:${API_PORT}..."

    # Run the FastAPI server
    exec python -m uvicorn src.main:app --host "$API_HOST" --port "$API_PORT"
fi
