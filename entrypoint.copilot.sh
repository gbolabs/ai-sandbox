#!/bin/bash
echo "AI Sandbox - GitHub Copilot CLI"
echo "================================"
echo "Project: ${PROJECT_NAME:-unknown}"
echo ""

# =============================================================================
# Authentication Status
# =============================================================================
if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "GitHub CLI: authenticated via GH_TOKEN"
    # Set up gh auth using token
    echo "${GH_TOKEN}" | gh auth login --with-token 2>/dev/null || true
elif gh auth status &>/dev/null; then
    echo "GitHub CLI: authenticated via mounted config"
else
    echo "GitHub CLI: not authenticated"
    echo "  Run 'gh auth login' or set GH_TOKEN"
fi

# Check Copilot extension
if gh extension list | grep -q "gh-copilot"; then
    echo "Copilot extension: installed"
else
    echo "Copilot extension: not found, installing..."
    gh extension install github/gh-copilot 2>/dev/null || echo "  Failed to install (may need auth)"
fi

if [[ -d "$HOME/.azure" ]]; then
    echo "Azure CLI: context mounted"
fi
echo ""

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
        echo "Cloning repository: $REPO_URL"
        git clone "$CLONE_URL" . || { echo "Failed to clone repository"; exit 1; }
        if [[ -n "${BRANCH:-}" ]]; then
            echo "Checking out branch: $BRANCH"
            git checkout "$BRANCH" || { echo "Failed to checkout branch"; exit 1; }
        fi
    else
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
# Interactive shell with Copilot
# =============================================================================
echo "GitHub Copilot CLI ready!"
echo ""
echo "Usage:"
echo "  gh copilot suggest \"how to find large files in git\""
echo "  gh copilot explain \"git rebase -i HEAD~3\""
echo ""
echo "Type 'exit' to leave the container."
echo ""

# Start interactive bash shell
exec bash
