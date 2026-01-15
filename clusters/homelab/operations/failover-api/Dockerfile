FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 failover

WORKDIR /app

# Copy application
COPY app.py requirements.txt ./

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Set permissions
RUN chown -R failover:failover /app && \
    mkdir -p /tmp/gitops-failover && \
    chown -R failover:failover /tmp/gitops-failover

USER failover

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8080/api/health').raise_for_status()"

ENTRYPOINT ["python", "app.py"]
