#!/bin/bash
echo "AI Code Sandbox"
echo "==============="
echo "Project: ${PROJECT_NAME:-unknown}"
echo "Mode: YOLO (all permissions granted)"
echo ""

# =============================================================================
# Authentication Status
# =============================================================================
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "GitHub CLI: authenticated"
else
    echo "GitHub CLI: not authenticated (GH_TOKEN not set)"
fi

if [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
    echo "Azure DevOps: PAT configured"
elif [[ -d "$HOME/.azure" ]]; then
    echo "Azure DevOps: az CLI context mounted"
fi

if [[ "${CLAUDE_CODE_ENABLE_TELEMETRY:-}" == "1" ]]; then
    echo "Telemetry: Enabled (OTel to ${OTEL_EXPORTER_OTLP_ENDPOINT:-Jaeger})"
else
    echo "Telemetry: Disabled (use --otel flag to enable)"
fi
echo ""

# =============================================================================
# Claude Auth Context
# =============================================================================
if [[ -d "/home/claude/.claude" ]]; then
    echo "Claude Code: auth context mounted from host"
else
    echo "Claude Code: no auth context found"
    echo "  Run 'claude' on host first to authenticate"
fi

# =============================================================================
# Start services
# =============================================================================
echo "Starting code-server on 0.0.0.0:8443..."
code-server --bind-addr 0.0.0.0:8443 --auth none &

echo "Starting upload server on 0.0.0.0:8888..."
python3 /opt/upload-server.py > /tmp/upload-server.log 2>&1 &
echo "Upload files at http://localhost:UPLOAD_PORT -> available at ~/share"
echo ""

# =============================================================================
# Clone repository if in clone mode
# =============================================================================
if [[ -n "${REPO_URL:-}" ]]; then
    # Handle Azure DevOps PAT authentication
    CLONE_URL="$REPO_URL"
    if [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
        if [[ "$REPO_URL" =~ dev\.azure\.com ]] || [[ "$REPO_URL" =~ visualstudio\.com ]]; then
            echo "Using Azure DevOps PAT for authentication"
            CLONE_URL=$(echo "$REPO_URL" | sed "s|https://|https://${AZURE_DEVOPS_PAT}@|")
        fi
    fi

    if [[ -d ".git" ]]; then
        echo "Repository already cloned, resuming..."
        echo "Current branch: $(git branch --show-current)"
        echo "Last commit: $(git log -1 --oneline)"
    elif [[ -z "$(ls -A .)" ]]; then
        # Directory is empty, clone fresh
        echo "Cloning repository: $REPO_URL"
        git clone "$CLONE_URL" . || { echo "Failed to clone repository"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            echo "Checking out branch: $BRANCH"
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    else
        # Directory has files but no .git - clear and clone
        echo "Workspace has files but no git repository. Cleaning and cloning fresh..."
        rm -rf ./* ./.[!.]* 2>/dev/null || true
        echo "Cloning repository: $REPO_URL"
        git clone "$CLONE_URL" . || { echo "Failed to clone repository"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            echo "Checking out branch: $BRANCH"
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    fi
    echo ""
fi

# =============================================================================
# Start Claude Code
# =============================================================================
echo "Starting Claude Code..."
echo ""
exec claude --dangerously-skip-permissions "$@"
