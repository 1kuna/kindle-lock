# kindle-lock

Lock your social media apps until you've read today. A self-hosted system that tracks your Kindle reading progress and unlocks iOS apps only after you hit your daily page goal.

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Kindle Cloud   │────▶│  kindle-lock     │────▶│  iOS App        │
│  Reader         │     │  (Raspberry Pi)  │     │  (your phone)   │
│                 │     │                  │     │                 │
│  You read here  │     │  Scrapes progress│     │  Locks apps     │
│                 │     │  every 30 min    │     │  until goal met │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

1. **You read** on any Kindle device or app (syncs to cloud)
2. **Server scrapes** Kindle Cloud Reader for your reading progress
3. **iOS app checks** if you've hit your daily goal (default: 30 pages)
4. **Apps unlock** when goal is met, lock again at reset time (default: 4 AM)

## Quick Start (Docker on Raspberry Pi)

### Prerequisites

- Raspberry Pi 4/5 with 4GB+ RAM
- 64-bit Raspberry Pi OS
- Docker and Docker Compose installed
- Amazon account with Kindle books

```bash
# Install Docker (if not already installed)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in
```

### 1. Clone and Configure

```bash
git clone https://github.com/yourusername/kindle-lock.git
cd kindle-lock

# Copy config template
cp .env.docker.example .env

# Edit with your settings
nano .env
```

**Required settings:**
```bash
AMAZON_EMAIL=your-email@example.com
AMAZON_PASSWORD=your-password
API_SECRET_KEY=generate-with-openssl-rand-hex-32
```

### 2. Build

```bash
make docker-build
# Or: docker compose build
```

First build takes 10-15 minutes (downloads Chromium browser).

### 3. Complete Amazon Login

Amazon requires 2FA verification, so you need to log in once via browser:

```bash
make docker-setup
# Or: KINDLE_SETUP_MODE=true docker compose --profile setup up
```

Then:
1. Open `http://<raspberry-pi-ip>:6080` in your browser
2. Click "Connect" in noVNC
3. Complete Amazon login in the browser window (enter 2FA if prompted)
4. Wait for "Login successful!" in terminal
5. Press `Ctrl+C`

### 4. Choose Remote Access Method

Pick one:

#### Option A: Cloudflare Tunnel (Recommended)

Free, works behind NAT, automatic HTTPS.

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. Create tunnel: **Access → Tunnels → Create**
3. Copy the tunnel token
4. Add public hostname pointing to `http://kindle-lock:8080`
5. Add to `.env`:
   ```bash
   CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiYWJjMTIz...
   ```
6. Start:
   ```bash
   make docker-up
   # Or: docker compose --profile cloudflare up -d
   ```

#### Option B: Tailscale

Mesh VPN - access from any device on your Tailscale network.

1. Go to [Tailscale Admin](https://login.tailscale.com/admin/settings/keys)
2. Create an auth key (enable "Reusable")
3. Add to `.env`:
   ```bash
   TAILSCALE_AUTHKEY=tskey-auth-xxxxx
   ```
4. Start:
   ```bash
   make docker-up-tailscale
   # Or: docker compose --profile tailscale up -d
   ```
5. Access at `https://kindle-lock.<your-tailnet>.ts.net`

#### Option C: Direct Port (BYO Proxy)

Use with your own reverse proxy (nginx, Caddy, Traefik).

```bash
make docker-up-expose
# Or: docker compose --profile expose up -d
```

Exposes port 8080. Configure your proxy to forward to `http://<pi-ip>:8080`.

### 5. Configure iOS App

1. Install the kindle-lock iOS app
2. Open Settings in the app
3. Set **Server URL** to your tunnel URL (e.g., `https://kindle.yourdomain.com`)
4. Set **API Key** to match `API_SECRET_KEY` from your `.env`
5. Grant Screen Time permissions when prompted

## Configuration

All settings are in `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `AMAZON_EMAIL` | - | Amazon login email |
| `AMAZON_PASSWORD` | - | Amazon password |
| `API_SECRET_KEY` | - | API key for iOS app authentication |
| `DAILY_PAGE_GOAL` | `30` | Pages to read before apps unlock |
| `DAY_RESET_HOUR` | `4` | Hour (0-23) when daily counter resets |
| `SCRAPE_INTERVAL_MINUTES` | `30` | How often to check reading progress |

## Operations

```bash
# View logs
make docker-logs

# Stop everything
make docker-down

# Re-authenticate Amazon (if session expires)
make docker-setup
# Complete login, then restart normally

# Update to new version
git pull
make docker-build
make docker-up  # or your chosen profile

# Backup data
docker run --rm -v kindle-lock-data:/data -v $(pwd):/backup \
  alpine tar czf /backup/kindle-backup.tar.gz /data
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (no auth required) |
| `/today` | GET | Today's reading progress and goal status |
| `/library` | GET | All books with reading progress |
| `/progress/{asin}` | GET | Detailed progress for a specific book |
| `/refresh` | POST | Trigger immediate progress scrape |
| `/settings` | GET/POST | View/update reading goal settings |

All endpoints except `/health` require `X-API-Key` header.

## Architecture

```
kindle-lock/
├── src/
│   ├── main.py          # FastAPI server
│   ├── scraper.py       # Playwright-based Kindle scraper
│   ├── database.py      # SQLite operations
│   ├── config.py        # Settings management
│   └── models.py        # Pydantic schemas
├── docker/
│   ├── Dockerfile       # Main container
│   ├── Dockerfile.novnc # VNC web client
│   └── start.sh         # Container entrypoint
├── KindleLock/          # iOS app (Xcode project)
└── docker-compose.yml   # Container orchestration
```

**Data persistence** (Docker volume `kindle-lock-data`):
- `reading.db` - SQLite database with books and progress
- `browser_profile/` - Chromium profile with Amazon session

## Local Development

For contributing or running without Docker:

```bash
# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
make install-dev

# Install Playwright browser
make setup

# Configure
cp .env.example .env
nano .env

# Login to Amazon (opens browser)
make login

# Run development server
make dev
```

## Troubleshooting

### Container won't start
```bash
docker compose logs kindle-lock
```
- **Out of memory**: Chromium needs ~500MB. Ensure 4GB+ RAM.
- **Permission denied**: Check Docker is installed and user is in `docker` group.

### VNC not connecting
- Check port 6080 isn't blocked: `curl http://localhost:6080`
- Try direct URL: `http://<ip>:6080/vnc.html`

### Amazon login fails
- If passkey prompt appears, click "Try another way" → "Password"
- Script waits up to 5 minutes for 2FA completion
- Check credentials in `.env` are correct

### Reading progress not updating
- Check scraper logs: `make docker-logs`
- Manually trigger scrape: `curl -X POST https://your-url/refresh -H "X-API-Key: your-key"`
- Verify books appear in Kindle Cloud Reader (read.amazon.com)

### iOS app can't connect
- Verify server URL includes `https://`
- Check API key matches exactly
- Test health endpoint: `curl https://your-url/health`

## Security

- **API Key**: Always use a strong, random key in production
- **HTTPS**: Provided automatically by Cloudflare/Tailscale tunnels
- **No exposed ports**: Tunnel sidecars handle all external routing
- **Container isolation**: App runs as non-root with minimal privileges
- **Credentials**: Amazon password only used for initial login, then session is persisted

## License

MIT
