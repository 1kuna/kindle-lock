# kindle-lock Docker image
# Supports both headless mode (production) and VNC mode (initial login setup)

FROM mcr.microsoft.com/playwright/python:v1.49.1-noble

# Set working directory
WORKDIR /app

# Install VNC and window manager for setup mode
# These are needed for interactive Amazon login with 2FA
RUN apt-get update && apt-get install -y --no-install-recommends \
    tigervnc-standalone-server \
    tigervnc-common \
    fluxbox \
    xterm \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd -m -s /bin/bash -u 1000 kindle && \
    mkdir -p /app/data && \
    chown -R kindle:kindle /app

# Copy requirements first for better layer caching
COPY --chown=kindle:kindle requirements.txt pyproject.toml ./

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Install Playwright Chromium browser (ARM64 compatible)
RUN playwright install chromium && \
    playwright install-deps chromium

# Copy application code
COPY --chown=kindle:kindle src/ ./src/

# Copy entrypoint script
COPY --chown=kindle:kindle docker/start.sh /start.sh
RUN chmod +x /start.sh

# Create fluxbox config directory for VNC mode
RUN mkdir -p /home/kindle/.fluxbox && \
    echo '[startup] {xterm}' > /home/kindle/.fluxbox/startup && \
    chown -R kindle:kindle /home/kindle/.fluxbox

# Switch to non-root user
USER kindle

# Environment defaults
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    BROWSER_HEADLESS=true \
    API_HOST=0.0.0.0 \
    API_PORT=8080 \
    DATABASE_PATH=/app/data/reading.db \
    BROWSER_PROFILE_PATH=/app/data/browser_profile

# Health check - verify API is responding
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose API port (8080) and VNC port (5901 for display :1)
EXPOSE 8080 5901

# Default entrypoint
CMD ["/start.sh"]
