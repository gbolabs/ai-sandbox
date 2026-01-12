# Claude API Traffic Logger
# Simple HTTP proxy that logs API requests/responses to JSON files
#
# Architecture:
#   Claude Code --HTTP--> api-logger:8000 --HTTPS--> api.anthropic.com
#                              |
#                              v (JSON logs)
#                         /data/api-logs/{project}/

FROM python:3.12-slim

# Install dependencies
RUN pip install --no-cache-dir httpx

# Create directories
RUN mkdir -p /data/api-logs /app

# Copy the proxy server
COPY server.py /app/server.py

WORKDIR /app

# Expose the proxy port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["python", "server.py"]
