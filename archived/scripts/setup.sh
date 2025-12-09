#!/bin/bash
# Raspberry Pi setup script for Read-to-Unlock
set -e

echo "=== Read-to-Unlock Pi Setup ==="
echo ""

# Check if running on Raspberry Pi
if [[ ! -f /proc/device-tree/model ]] || ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    echo "Warning: This doesn't appear to be a Raspberry Pi."
    echo "Some commands may not work as expected."
    echo ""
fi

# Update system
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install system dependencies for Playwright/Chromium
echo ""
echo "Installing system dependencies..."
sudo apt install -y \
    python3 python3-pip python3-venv \
    libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libasound2 libpango-1.0-0 \
    libcairo2 libatspi2.0-0 libxshmfence1 \
    fonts-liberation libnss3 libnspr4

# Get the project directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "Project directory: $PROJECT_DIR"
cd "$PROJECT_DIR"

# Create virtual environment
echo ""
echo "Creating Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install project dependencies
echo ""
echo "Installing Python dependencies..."
pip install -e ".[dev]"

# Install Playwright browsers
echo ""
echo "Installing Playwright Chromium browser..."
playwright install chromium
playwright install-deps chromium

# Create data directories
echo ""
echo "Creating data directories..."
mkdir -p data/browser_profile

# Create .env from example if it doesn't exist
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        cp .env.example .env
        echo "Created .env from .env.example"
    fi
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Edit .env with your Amazon credentials"
echo "   nano $PROJECT_DIR/.env"
echo ""
echo "2. Run the login helper (requires display/VNC):"
echo "   BROWSER_HEADLESS=false python scripts/login.py"
echo ""
echo "3. Install systemd service (optional, for auto-start):"
echo "   ./scripts/install_service.sh"
echo ""
echo "4. Or run manually:"
echo "   source venv/bin/activate"
echo "   python -m uvicorn src.main:app --host 0.0.0.0 --port 8080"
