# Docker Deployment Guide

Deploy kindle-lock on a Raspberry Pi (or any Docker host) with remote access for your iOS app.

## Prerequisites

- **Raspberry Pi 4 or 5** with 4GB+ RAM (or any ARM64/x86_64 Linux host)
- **64-bit Raspberry Pi OS** (Lite or Desktop)
- **Docker** and **Docker Compose** installed
- **Amazon account** with Kindle books

### Install Docker on Raspberry Pi

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh

# Add your user to docker group
sudo usermod -aG docker $USER

# Log out and back in, then verify
docker --version
docker compose version
```

## Quick Start

### 1. Clone and Configure

```bash
# Clone the repository
git clone https://github.com/yourusername/kindle-lock.git
cd kindle-lock

# Copy the example config
cp .env.docker.example .env

# Edit with your settings
nano .env
```

**Required settings in `.env`:**
- `AMAZON_EMAIL` - Your Amazon login email
- `AMAZON_PASSWORD` - Your Amazon password
- `API_SECRET_KEY` - Generate with `openssl rand -hex 32`
- One of: `CLOUDFLARE_TUNNEL_TOKEN` or `TAILSCALE_AUTHKEY` (see Remote Access below)

### 2. Build the Container

```bash
docker compose build
```

First build takes 10-15 minutes on Raspberry Pi (downloading Chromium).

### 3. Complete Amazon Login

Amazon requires 2FA/passkey verification, so you need to log in interactively once:

```bash
# Start in setup mode with VNC
KINDLE_SETUP_MODE=true docker compose --profile setup up
```

Then:
1. Open your browser to `http://<pi-ip>:6080`
2. Click "Connect" in noVNC
3. You'll see a browser window with Kindle Cloud Reader
4. Complete the Amazon login (enter 2FA code if prompted)
5. Wait for "Login successful!" message in the terminal
6. Press `Ctrl+C` to stop

Your session is now saved in the Docker volume.

### 4. Start in Production Mode

Choose your remote access method:

**Option A: Cloudflare Tunnel** (recommended)
```bash
docker compose --profile cloudflare up -d
```

**Option B: Tailscale**
```bash
docker compose --profile tailscale up -d
```

**Option C: Direct port exposure** (use with your own reverse proxy)
```bash
docker compose --profile expose up -d
```

### 5. Configure iOS App

In the kindle-lock iOS app:
1. Go to Settings
2. Set **Server URL** to your tunnel URL (e.g., `https://kindle.yourdomain.com`)
3. Set **API Key** to the same value as `API_SECRET_KEY` in your `.env`

---

## Remote Access Setup

### Option 1: Cloudflare Tunnel (Recommended)

Free, works behind any NAT/firewall, provides HTTPS automatically.

1. **Create a Cloudflare account** at [cloudflare.com](https://cloudflare.com) (free tier is fine)

2. **Add a domain** to Cloudflare (or use a free `*.trycloudflare.com` subdomain)

3. **Create a tunnel:**
   - Go to [Zero Trust Dashboard](https://one.dash.cloudflare.com/)
   - Navigate to **Access → Tunnels**
   - Click **Create a tunnel**
   - Name it `kindle-lock`
   - Copy the tunnel token

4. **Configure public hostname:**
   - Add a public hostname (e.g., `kindle.yourdomain.com`)
   - Service: `http://kindle-lock:8080`

5. **Add to `.env`:**
   ```bash
   CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiYWJjMTIz...
   ```

6. **Start with Cloudflare profile:**
   ```bash
   docker compose --profile cloudflare up -d
   ```

Your app is now accessible at `https://kindle.yourdomain.com`

### Option 2: Tailscale

Mesh VPN - access from any device on your Tailscale network.

1. **Create a Tailscale account** at [tailscale.com](https://tailscale.com) (free for personal use)

2. **Install Tailscale** on your phone/devices you want to access from

3. **Create an auth key:**
   - Go to [Admin Console → Keys](https://login.tailscale.com/admin/settings/keys)
   - Click **Generate auth key**
   - Enable **Reusable** (recommended)
   - Copy the key

4. **Add to `.env`:**
   ```bash
   TAILSCALE_AUTHKEY=tskey-auth-xxxxx
   ```

5. **Start with Tailscale profile:**
   ```bash
   docker compose --profile tailscale up -d
   ```

Your app is accessible at `https://kindle-lock.<your-tailnet>.ts.net`

### Option 3: Direct Port Exposure

Use this if you have your own reverse proxy or want to add kindle-lock to an existing tunnel.

```bash
# Expose on port 8080 (or set API_EXPOSE_PORT in .env)
docker compose --profile expose up -d
```

Then configure your reverse proxy to forward to `http://<pi-ip>:8080`

---

## Operations

### View Logs

```bash
# All services
docker compose logs -f

# Just the main app
docker compose logs -f kindle-lock
```

### Restart After Config Change

```bash
docker compose restart kindle-lock
```

### Update to New Version

```bash
git pull
docker compose build
docker compose --profile <your-profile> up -d
```

### Re-authenticate Amazon

If your Amazon session expires:

```bash
# Stop current instance
docker compose --profile <your-profile> down

# Run setup again
KINDLE_SETUP_MODE=true docker compose --profile setup up

# Complete login in browser at http://<pi-ip>:6080
# Then Ctrl+C and restart normally
docker compose --profile <your-profile> up -d
```

### Backup Data

```bash
# Create backup
docker run --rm -v kindle-lock-data:/data -v $(pwd):/backup \
  alpine tar czf /backup/kindle-backup.tar.gz /data

# Restore backup
docker run --rm -v kindle-lock-data:/data -v $(pwd):/backup \
  alpine tar xzf /backup/kindle-backup.tar.gz -C /
```

---

## Troubleshooting

### Container won't start

Check logs:
```bash
docker compose logs kindle-lock
```

Common issues:
- **Out of memory**: Chromium needs ~500MB RAM during scraping. Ensure 4GB+ RAM.
- **Shared memory**: Already configured in docker-compose.yml (`shm_size: 1gb`)

### VNC not connecting

- Ensure port 6080 isn't blocked by firewall
- Check noVNC container is running: `docker compose --profile setup ps`
- Try accessing directly: `http://<pi-ip>:6080/vnc.html`

### Amazon login failing

- Check credentials in `.env`
- If passkey prompt appears, click "Try another way" → "Password"
- If 2FA times out, the script waits up to 5 minutes

### Health check failing

```bash
# Check if API is responding
curl http://localhost:8080/health

# View detailed health status
docker inspect kindle-lock | grep -A 10 Health
```

### Tunnel not connecting

**Cloudflare:**
```bash
docker compose logs cloudflared
```
- Verify `CLOUDFLARE_TUNNEL_TOKEN` is correct
- Check tunnel status in Cloudflare dashboard

**Tailscale:**
```bash
docker compose logs tailscale
```
- Verify `TAILSCALE_AUTHKEY` is valid and not expired
- Check device appears in Tailscale admin console

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Docker Host (Raspberry Pi)                                 │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  kindle-lock container                               │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  │   │
│  │  │ FastAPI     │  │ Playwright   │  │ SQLite     │  │   │
│  │  │ :8080       │  │ (Chromium)   │  │ database   │  │   │
│  │  └─────────────┘  └──────────────┘  └────────────┘  │   │
│  └─────────────────────────────────────────────────────┘   │
│           │                                                 │
│  ┌────────┴────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ noVNC           │  │ cloudflared  │  │ tailscale    │   │
│  │ (setup only)    │  │ OR           │  │              │   │
│  │ :6080           │  │              │  │              │   │
│  └─────────────────┘  └──────────────┘  └──────────────┘   │
│                                                             │
│  Volume: kindle-lock-data                                   │
│  ├── reading.db (progress database)                        │
│  └── browser_profile/ (Amazon session)                     │
└─────────────────────────────────────────────────────────────┘
```

---

## Security Notes

- **API Key**: Always set a strong `API_SECRET_KEY` in production
- **HTTPS**: Cloudflare and Tailscale provide automatic TLS
- **No exposed ports**: When using tunnels, no ports are exposed on your network
- **Credentials**: Amazon credentials are only used for initial login, then session is persisted
- **Container isolation**: App runs as non-root user with minimal privileges
