#!/bin/bash
# Entrypoint for Claude API Logger container
# Runs claude-code-logger and Fluent Bit in parallel

set -euo pipefail

# Configuration
LOG_FILE="/var/log/claude-api.log"
PROXY_PORT="${PROXY_PORT:-8000}"
SEQ_HOST="${SEQ_HOST:-host.containers.internal}"

# Export for Fluent Bit config
export SEQ_HOST

echo "==================================="
echo " Claude API Traffic Logger"
echo "==================================="
echo ""
echo " Proxy:     http://0.0.0.0:${PROXY_PORT}"
echo " Seq Host:  ${SEQ_HOST}:5341"
echo " Log File:  ${LOG_FILE}"
echo ""
echo "==================================="

# Create log file
touch "$LOG_FILE"

# Cleanup function
cleanup() {
    echo ""
    echo "Shutting down..."
    # Kill background processes
    kill $(jobs -p) 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Start Fluent Bit in background
echo "Starting Fluent Bit..."
/opt/fluent-bit/bin/fluent-bit -c /etc/fluent-bit/fluent-bit.conf &
FLUENT_PID=$!

# Give Fluent Bit a moment to start
sleep 1

# Start claude-code-logger in foreground, pipe to log file and stdout
echo "Starting claude-code-logger on port ${PROXY_PORT}..."
echo ""

# Run claude-code-logger with full body logging
# Output goes to both stdout (for docker logs) and file (for Fluent Bit)
npx claude-code-logger start \
    --port "$PROXY_PORT" \
    --log-body \
    --verbose \
    --chat-mode=false \
    2>&1 | tee "$LOG_FILE"

# If claude-code-logger exits, also stop Fluent Bit
cleanup
