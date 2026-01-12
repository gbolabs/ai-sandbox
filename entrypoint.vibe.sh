#!/bin/bash

# Run initialization script if it exists
if [ -f /init-vibe.sh ]; then
    echo "🔧 Running initialization script..."
    source /init-vibe.sh
    echo ""
fi

echo "🤖 Mistral Vibe CLI Sandbox"
echo "=========================="
echo "Mode: YOLO (all permissions granted)"
echo ""
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "✅ GitHub CLI authenticated"
else
    echo "⚠️  GitHub CLI not authenticated (GH_TOKEN not set)"
fi
if [[ "${VIBE_TELEMETRY:-}" == "1" ]]; then
    echo "✅ Telemetry: Enabled (OTel to ${OTEL_EXPORTER_OTLP_ENDPOINT:-not set})"
else
    echo "ℹ️  Telemetry: Disabled (use --otel flag to enable)"
fi
echo ""
# Start code-server in the background
echo "🚀 Starting code-server on 0.0.0.0:8444..."
code-server --bind-addr 0.0.0.0:8444 --auth none &
echo "✅ code-server running at http://0.0.0.0:8444"
echo ""

# Clone repo if in clone mode
if [[ -n "${REPO_URL:-}" ]]; then
    echo "Cloning repository: $REPO_URL"
    git clone "$REPO_URL" . || { echo "Failed to clone repository"; exit 1; }
    if [[ -n "${BRANCH:-}" ]]; then
        echo "Checking out branch: $BRANCH"
        git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
    fi
    echo ""
fi

echo "Starting Mistral Vibe CLI..."
echo ""

# Source bashrc to get updated PATH (including uv and vibe)
if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
    # Export PATH to ensure it's available in the current shell
    export PATH
fi

# Check if vibe is installed
if ! command -v vibe &> /dev/null; then
    echo "❌ Error: Vibe CLI not found!"
    echo ""
    echo "Please try rebuilding the container with:"
    echo "  ./scripts/vibe-sandbox.sh build"
    echo ""
    echo "If the issue persists, check the Dockerfile installation method."
    exit 1
fi

exec vibe "$@"
