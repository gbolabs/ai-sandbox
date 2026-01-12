#!/bin/bash
# Unified entrypoint for AI Sandbox containers
# Supports: Claude Code, Vibe CLI, GitHub Copilot CLI

# Detect CLI type from username or environment
USER_NAME=$(whoami)
CLI_TYPE="${CLI_TYPE:-$USER_NAME}"

echo "AI Sandbox"
echo "=========="
echo "CLI: $CLI_TYPE"
echo "Project: ${PROJECT_NAME:-unknown}"
echo ""

# =============================================================================
# Authentication Status
# =============================================================================

# GitHub CLI
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "GitHub CLI: authenticated (GH_TOKEN)"
elif [[ -d "$HOME/.config/gh" ]] && gh auth status &>/dev/null; then
    echo "GitHub CLI: authenticated (mounted config)"
else
    echo "GitHub CLI: not authenticated"
fi

# CLI-specific auth
case "$CLI_TYPE" in
    claude)
        if [[ -d "$HOME/.claude" ]]; then
            echo "Claude Code: auth context mounted"
        else
            echo "Claude Code: no auth (run 'claude' on host first)"
        fi
        ;;
    vibe)
        if [[ -d "$HOME/.vibe" ]]; then
            echo "Vibe CLI: auth context mounted"
        else
            echo "Vibe CLI: no auth (run 'vibe' on host first)"
        fi
        ;;
    copilot)
        if gh extension list 2>/dev/null | grep -q "gh-copilot"; then
            echo "Copilot: extension installed"
        else
            echo "Copilot: installing extension..."
            gh extension install github/gh-copilot 2>/dev/null || echo "  (requires gh auth)"
        fi
        ;;
esac

# Azure DevOps
if [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
    echo "Azure DevOps: PAT configured"
elif [[ -d "$HOME/.azure" ]]; then
    echo "Azure DevOps: az CLI context mounted"
fi

# Telemetry
if [[ "${CLAUDE_CODE_ENABLE_TELEMETRY:-}" == "1" ]]; then
    echo "Telemetry: enabled (Jaeger)"
fi

echo ""

# =============================================================================
# Start Services
# =============================================================================

echo "Starting code-server on 0.0.0.0:8443..."
code-server --bind-addr 0.0.0.0:8443 --auth none &

echo "Starting upload server on 0.0.0.0:8888..."
python3 /opt/upload-server.py > /tmp/upload-server.log 2>&1 &

echo ""

# =============================================================================
# Clone Repository (if in clone mode)
# =============================================================================

if [[ -n "${REPO_URL:-}" ]]; then
    CLONE_URL="$REPO_URL"

    # Handle Azure DevOps PAT authentication
    if [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
        if [[ "$REPO_URL" =~ dev\.azure\.com ]] || [[ "$REPO_URL" =~ visualstudio\.com ]]; then
            echo "Using Azure DevOps PAT for authentication"
            CLONE_URL=$(echo "$REPO_URL" | sed "s|https://|https://${AZURE_DEVOPS_PAT}@|")
        fi
    fi

    if [[ -d ".git" ]]; then
        echo "Repository already cloned, resuming..."
        echo "Branch: $(git branch --show-current 2>/dev/null || echo 'detached')"
        echo "Last commit: $(git log -1 --oneline 2>/dev/null || echo 'unknown')"
    elif [[ -z "$(ls -A . 2>/dev/null)" ]]; then
        echo "Cloning repository: $REPO_URL"
        git clone "$CLONE_URL" . || { echo "Failed to clone"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            echo "Checking out branch: $BRANCH"
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    else
        echo "Workspace has files but no .git - cleaning and cloning..."
        rm -rf ./* ./.[!.]* 2>/dev/null || true
        git clone "$CLONE_URL" . || { echo "Failed to clone"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    fi
    echo ""
fi

# =============================================================================
# Start AI CLI
# =============================================================================

case "$CLI_TYPE" in
    claude)
        echo "Starting Claude Code..."
        echo ""
        exec claude --dangerously-skip-permissions "$@"
        ;;
    vibe)
        echo "Starting Vibe CLI..."
        echo ""
        # Check if vibe is available
        if ! command -v vibe &>/dev/null; then
            echo "Error: Vibe CLI not found in PATH"
            echo "PATH: $PATH"
            exit 1
        fi
        exec vibe "$@"
        ;;
    copilot)
        echo "GitHub Copilot CLI ready!"
        echo ""
        echo "Usage:"
        echo "  gh copilot suggest \"how to find large files\""
        echo "  gh copilot explain \"git rebase -i HEAD~3\""
        echo ""
        exec bash
        ;;
    *)
        echo "Unknown CLI type: $CLI_TYPE"
        echo "Supported: claude, vibe, copilot"
        exit 1
        ;;
esac
