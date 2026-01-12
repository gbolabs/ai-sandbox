#!/bin/bash
echo "🤖 Claude Code Sandbox"
echo "======================"
echo "Mode: YOLO (all permissions granted)"
echo ""
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "✅ GitHub CLI authenticated"
else
    echo "⚠️  GitHub CLI not authenticated (GH_TOKEN not set)"
fi
if [[ "${CLAUDE_CODE_ENABLE_TELEMETRY:-}" == "1" ]]; then
    echo "✅ Telemetry: Enabled (OTel to ${OTEL_EXPORTER_OTLP_ENDPOINT:-not set})"
else
    echo "ℹ️  Telemetry: Disabled (use --otel flag to enable)"
fi
echo ""
# Start code-server in the background
echo "🚀 Starting code-server on 0.0.0.0:8443..."
code-server --bind-addr 0.0.0.0:8443 --auth none &
echo "✅ code-server running at http://0.0.0.0:8443"

# Start upload server in the background
echo "🚀 Starting upload server on 0.0.0.0:8888..."
python3 /opt/upload-server.py > /tmp/upload-server.log 2>&1 &
echo "✅ Upload server running at http://0.0.0.0:8888"
echo "   Drop/paste files there → available at ~/share in container"
echo ""

# Clone repo if in clone mode (or update if already cloned)
if [[ -n "${REPO_URL:-}" ]]; then
    if [[ -d ".git" ]]; then
        echo "Repository already cloned, resuming..."
        echo "Current branch: $(git branch --show-current)"
        echo "Last commit: $(git log -1 --oneline)"
    elif [[ -z "$(ls -A .)" ]]; then
        # Directory is empty, clone fresh
        echo "Cloning repository: $REPO_URL"
        git clone "$REPO_URL" . || { echo "Failed to clone repository"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            echo "Checking out branch: $BRANCH"
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    else
        # Directory has files but no .git - clear and clone
        echo "⚠️  Workspace has files but no git repository. Cleaning and cloning fresh..."
        rm -rf ./* ./.[!.]* 2>/dev/null || true
        echo "Cloning repository: $REPO_URL"
        git clone "$REPO_URL" . || { echo "Failed to clone repository"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            echo "Checking out branch: $BRANCH"
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    fi
    echo ""
fi

echo "Starting Claude Code..."
echo ""
exec claude --dangerously-skip-permissions "$@"
