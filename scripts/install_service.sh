#!/bin/bash
# Install systemd services for Read-to-Unlock
set -e

echo "=== Installing Read-to-Unlock Services ==="
echo ""

# Get the project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Check if systemd directory exists
if [[ ! -d "$PROJECT_DIR/systemd" ]]; then
    echo "Error: systemd directory not found at $PROJECT_DIR/systemd"
    exit 1
fi

# Get the current user
SERVICE_USER="${SUDO_USER:-$USER}"
if [[ "$SERVICE_USER" == "root" ]]; then
    SERVICE_USER="pi"
fi

echo "Project directory: $PROJECT_DIR"
echo "Service user: $SERVICE_USER"
echo ""

# Create temporary service files with correct paths
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Process each service file, replacing placeholders
for file in "$PROJECT_DIR/systemd"/*.{service,timer} 2>/dev/null; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file")
        sed -e "s|%PROJECT_DIR%|$PROJECT_DIR|g" \
            -e "s|%USER%|$SERVICE_USER|g" \
            "$file" > "$TEMP_DIR/$filename"
        echo "Prepared: $filename"
    fi
done

# Copy to systemd directory
echo ""
echo "Installing service files..."
sudo cp "$TEMP_DIR"/*.service "$TEMP_DIR"/*.timer /etc/systemd/system/ 2>/dev/null || true

# Reload systemd
echo "Reloading systemd..."
sudo systemctl daemon-reload

# Enable and start main service
echo ""
echo "Enabling and starting read-to-unlock service..."
sudo systemctl enable read-to-unlock
sudo systemctl start read-to-unlock

# Enable and start timer (for redundant scraping)
echo "Enabling and starting scraper timer..."
sudo systemctl enable read-to-unlock-scraper.timer
sudo systemctl start read-to-unlock-scraper.timer

echo ""
echo "=== Services Installed ==="
echo ""
echo "Main API service:"
echo "  Status:  sudo systemctl status read-to-unlock"
echo "  Logs:    sudo journalctl -u read-to-unlock -f"
echo "  Restart: sudo systemctl restart read-to-unlock"
echo ""
echo "Scraper timer:"
echo "  Status:  sudo systemctl status read-to-unlock-scraper.timer"
echo "  List:    sudo systemctl list-timers read-to-unlock-*"
echo ""
echo "The API should now be available at http://localhost:8080"
echo "Test it with: curl http://localhost:8080/health"
