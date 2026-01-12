#!/bin/bash
# Vibe Sandbox Script - Simplified Development Environment for Mistral Vibe CLI
#
# Simplified Usage:
#   ./scripts/vibe-sandbox.sh clone          # Default: accept-all mode + main branch
#   ./scripts/vibe-sandbox.sh --accept-all clone  # Explicit accept-all mode
#   ./scripts/vibe-sandbox.sh mount          # Mount current directory
#   ./scripts/vibe-sandbox.sh --help         # Show full help
#
# Features:
#   - Accept-all mode for Vibe CLI (automatic prompt acceptance)
#   - Vibe context forwarding (mounts ~/.vibe directory)
#   - Simple branch specification
#   - Clean, focused interface

set -euo pipefail

# Default values when no parameters are given
if [[ $# -eq 0 ]]; then
    set -- --accept-all clone
fi

# Show help message
show_help() {
    cat << EOF
Vibe Sandbox Script - Development Environment for Mistral Vibe CLI

Usage:
  ./scripts/vibe-sandbox.sh [options] [clone|mount|build]
  ./scripts/vibe-sandbox.sh          # Default: --accept-all clone

Options:
  --accept-all      Enable accept-all mode for Vibe CLI (default)
  --no-accept-all   Disable accept-all mode
  --no-context      Disable Vibe context forwarding
  --branch=BRANCH   Branch to checkout in clone mode [default: main]
  --skip-scope-check Skip GitHub token scope validation
  -h, --help        Show this help message

Modes:
  clone              Clone repo fresh inside container
  mount              Mount current directory (faster, changes persist)
  build              Rebuild the Docker image

Vibe Features:
  Accept-All Mode:  Automatically accepts all Vibe prompts (VIBE_ACCEPT_ALL=1)
  Context Forwarding: Mounts ~/.vibe directory for consistent configuration

Examples:
  # Default: Accept-all mode + main branch
  ./scripts/vibe-sandbox.sh clone

  # Specific branch without accept-all
  ./scripts/vibe-sandbox.sh --branch=feature-branch clone

  # Just mount current directory
  ./scripts/vibe-sandbox.sh mount

  # Disable context forwarding
  ./scripts/vibe-sandbox.sh --no-context mount

  # Specific branch with explicit accept-all
  ./scripts/vibe-sandbox.sh --accept-all --branch=feature-branch clone

  # Rebuild the Docker image
  ./scripts/vibe-sandbox.sh build

  # Pass -h to Vibe CLI for help
  ./scripts/vibe-sandbox.sh -h
  ./scripts/vibe-sandbox.sh help
EOF
}

# Parse flags
ACCEPT_ALL_MODE=true   # Default to accept-all mode
FORWARD_VIBE_CONTEXT=true
SKIP_SCOPE_CHECK=false
BRANCH="main"
POSITIONAL_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --accept-all)
            ACCEPT_ALL_MODE=true
            ;;
        --no-accept-all)
            ACCEPT_ALL_MODE=false
            ;;
        --no-context)
            FORWARD_VIBE_CONTEXT=false
            ;;
        --skip-scope-check)
            SKIP_SCOPE_CHECK=true
            ;;
        --branch=*)
            BRANCH="${arg#*=}"
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$arg")
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]:-}"

MODE="${1:-mount}"
REPO_URL="https://github.com/gbolabs/photos-index.git"
CONTAINER_NAME="vibe-sandbox"
IMAGE_NAME="vibe-sandbox:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Forward Vibe CLI context to container
forward_vibe_context() {
    local vibe_args=""
    
    if [[ "$FORWARD_VIBE_CONTEXT" == "true" ]]; then
        # Mount Vibe configuration directory
        vibe_args+=" -v ${VIBE_HOME:-$HOME/.vibe}:${VIBE_HOME:-/root/.vibe}:Z"
        # Don't log here - logging adds color codes that break command strings
    fi
    
    echo "$vibe_args"
}

# Get Vibe environment variables for podman
get_vibe_env_args() {
    local env_args=""
    
    # Set accept-all mode
    if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
        env_args+=" -e VIBE_ACCEPT_ALL=1"
        # Don't log here - logging adds color codes that break command strings
    fi
    
    # Forward any existing Vibe environment variables
    if [[ -n "${VIBE_MODEL:-}" ]]; then
        env_args+=" -e VIBE_MODEL=${VIBE_MODEL}"
    fi
    
    if [[ -n "${VIBE_PROMPT:-}" ]]; then
        env_args+=" -e VIBE_PROMPT=${VIBE_PROMPT}"
    fi
    
    echo "$env_args"
}

# Required GitHub token scopes for full functionality
REQUIRED_SCOPES="repo,workflow"

# Check if token has required scopes
check_token_scopes() {
    local scopes
    # Use sed instead of grep -oP for macOS compatibility
    scopes=$(gh auth status 2>&1 | grep "Token scopes:" | sed "s/.*Token scopes: //" || echo "")
    
    if [[ -z "$scopes" ]]; then
        warn "Could not determine token scopes"
        return 1
    fi
    
    log "Current token scopes: $scopes"
    
    # Check for workflow scope (needed for pushing workflow files)
    if [[ "$scopes" != *"workflow"* ]]; then
        warn "Token missing 'workflow' scope (needed to push .github/workflows changes)"
        return 1
    fi
    
    return 0
}

# Get GitHub token interactively
get_gh_token() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        log "Using GH_TOKEN from environment"
        return 0
    fi
    
    if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            # Check if token has required scopes (unless skipped)
            if [[ "$SKIP_SCOPE_CHECK" != "true" ]]; then
                if ! check_token_scopes; then
                    warn "Token missing required scopes. Refreshing..."
                    gh auth refresh -h github.com -s workflow
                fi
            else
                log "Skipping scope check (--skip-scope-check)"
            fi
            
            log "Getting GitHub token from gh CLI..."
            GH_TOKEN=$(gh auth token)
            export GH_TOKEN
            log "GitHub token obtained successfully"
            return 0
        else
            warn "gh CLI not authenticated. Run 'gh auth login -s workflow' first"
        fi
    else
        warn "gh CLI not installed"
    fi
    
    echo ""
    echo -e "${YELLOW}GitHub token not available.${NC}"
    echo "Options:"
    echo "  1. Run 'gh auth login -s workflow' and re-run this script"
    echo "  2. Set GH_TOKEN environment variable (must include workflow scope)"
    echo "  3. Continue without GitHub CLI (some features won't work)"
    echo ""
    read -p "Continue without GitHub token? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

# Check prerequisites
check_prereqs() {
    log "Checking prerequisites..."
    
    command -v podman >/dev/null 2>&1 || error "Podman is not installed"
    
    # Interactive token setup
    get_gh_token
    
    log "Prerequisites OK"
}

# Build the container image
build_image() {
    log "Building container image..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local dockerfile="$script_dir/Dockerfile.vibe-sandbox"
    
    if [[ ! -f "$dockerfile" ]]; then
        error "Dockerfile not found: $dockerfile"
    fi
    
    podman build -t "$IMAGE_NAME" -f "$dockerfile" "$script_dir/.."
    
    log "Image built successfully"
}

# Run container with mounted source
run_mount_mode() {
    log "Running in MOUNT mode (current directory mounted)"
    
    local git_name=$(git config user.name 2>/dev/null || echo "Vibe Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "vibe@localhost")
    
    # Get Vibe-specific arguments
    local vibe_args=$(forward_vibe_context)
    local vibe_env_args=$(get_vibe_env_args)
    
    # Log Vibe context info after getting the args
    if [[ "$FORWARD_VIBE_CONTEXT" == "true" ]]; then
        log "Forwarding Vibe context from ${VIBE_HOME:-$HOME/.vibe}"
    else
        log "Vibe context forwarding disabled"
    fi
    
    if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
        log "Accept-all mode enabled (VIBE_ACCEPT_ALL=1)"
    else
        log "Accept-all mode disabled"
    fi
    
    # shellcheck disable=SC2086
    podman run -it --rm \
        --name "$CONTAINER_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e MISTRAL_API_KEY="${MISTRAL_API_KEY:-}" \
        -p 8444:8444 \
        -v "$(pwd):/workspace:Z" \
        $vibe_args \
        $vibe_env_args \
        "$IMAGE_NAME" \
        "$@"
}

# Run container with cloned source
run_clone_mode() {
    log "Running in CLONE mode (fresh clone inside container)"
    
    local git_name=$(git config user.name 2>/dev/null || echo "Vibe Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "vibe@localhost")
    local branch="$BRANCH"
    
    # Get Vibe-specific arguments
    local vibe_args=$(forward_vibe_context)
    local vibe_env_args=$(get_vibe_env_args)
    
    # Log Vibe context info after getting the args
    if [[ "$FORWARD_VIBE_CONTEXT" == "true" ]]; then
        log "Forwarding Vibe context from ${VIBE_HOME:-$HOME/.vibe}"
    else
        log "Vibe context forwarding disabled"
    fi
    
    if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
        log "Accept-all mode enabled (VIBE_ACCEPT_ALL=1)"
    else
        log "Accept-all mode disabled"
    fi
    
    # shellcheck disable=SC2086
    podman run -it --rm \
        --name "$CONTAINER_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e MISTRAL_API_KEY="${MISTRAL_API_KEY:-}" \
        -e REPO_URL="$REPO_URL" \
        -e BRANCH="$branch" \
        -p 8444:8444 \
        $vibe_args \
        $vibe_env_args \
        "$IMAGE_NAME" \
        "$@"
}

# Main
main() {
    # Handle -h or help flags to pass to Vibe CLI
    if [[ "$1" == "-h" ]] || [[ "$1" == "help" ]]; then
        # Build image if needed, then pass -h to Vibe CLI
        if ! podman image exists "$IMAGE_NAME"; then
            build_image
        else
            log "Using existing image"
        fi
        shift || true  # Remove -h/help argument
        run_mount_mode "$@"
        return
    fi
    
    check_prereqs
    
    # Build image if it doesn't exist
    if ! podman image exists "$IMAGE_NAME"; then
        build_image
    else
        log "Using existing image (run 'podman rmi $IMAGE_NAME' to rebuild)"
    fi
    
    shift || true  # Remove mode argument
    
    case "$MODE" in
        mount)
            run_mount_mode "$@"
            ;;
        clone)
            run_clone_mode "$@"
            ;;
        build)
            build_image
            ;;
        *)
            error "Unknown mode: $MODE (use 'mount', 'clone', or 'build')"
            ;;
    esac
}

main "$@"
