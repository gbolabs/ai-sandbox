#!/bin/bash
# =============================================================================
# Vibe Sandbox Script - Containerized Development Environment for Mistral Vibe CLI
# =============================================================================
#
# Multi-project portable sandbox for running Vibe CLI in isolated containers.
# Supports GitHub and Azure DevOps repositories with host context reuse.
#
# Usage:
#   ./vibe-sandbox.sh [options] <mode>
#   ./vibe-sandbox.sh mount              # Mount pwd, derive project from dirname
#   ./vibe-sandbox.sh clone              # Clone from git remote, derive project
#   ./vibe-sandbox.sh --repo=URL clone   # Clone specific repo
#   ./vibe-sandbox.sh clean              # Clean current project resources
#
# See --help for full options and examples.
# =============================================================================

set -euo pipefail

# =============================================================================
# Help and Usage
# =============================================================================

show_help() {
    cat << 'EOF'
Vibe Sandbox - Containerized Development Environment for Mistral Vibe CLI

Usage:
  ./vibe-sandbox.sh [options] <mode>

Modes:
  mount              Mount current directory into container (faster, changes persist)
  clone              Clone repository inside container (isolated)
  build              Rebuild the Docker image
  recover            Recover a stopped container (reattach)
  clean              Clean up project resources
  help               Show this help message

Options:
  --repo=URL         Repository URL (GitHub or Azure DevOps)
                     If not specified, uses current git remote or directory name
  --project=NAME     Override project name (default: derived from repo/dir)
  --branch=BRANCH    Branch to checkout in clone mode [default: main]
  --port-base=PORT   Base port for services (default: 18443)
                     Actual ports: base + hash-based offset
  --accept-all       Enable accept-all mode for Vibe CLI (default)
  --no-accept-all    Disable accept-all mode
  --no-context       Disable Vibe context forwarding
  --skip-scope-check Skip GitHub token scope validation
  --clean-shared     Also clean shared resources (Jaeger) - use with 'clean'
  -h, --help         Show this help message

Environment Variables:
  MISTRAL_API_KEY    Mistral API key (required)
  GH_TOKEN           GitHub token for private repos
  AZURE_DEVOPS_PAT   Azure DevOps personal access token

Examples:
  # Mount current directory (project name from dirname)
  ./vibe-sandbox.sh mount

  # Clone a GitHub repository
  ./vibe-sandbox.sh --repo=https://github.com/user/repo.git clone

  # Clone an Azure DevOps repository
  ./vibe-sandbox.sh --repo=https://dev.azure.com/org/project/_git/repo clone

  # Custom project name and port
  ./vibe-sandbox.sh --project=myproj --port-base=20000 mount

  # Clean up project resources
  ./vibe-sandbox.sh clean

  # Clean everything including shared Jaeger
  ./vibe-sandbox.sh clean --clean-shared

  # Rebuild the Docker image
  ./vibe-sandbox.sh build
EOF
}

# =============================================================================
# Default Configuration
# =============================================================================

PORT_BASE=18443
BRANCH="main"
ACCEPT_ALL_MODE=true
FORWARD_VIBE_CONTEXT=true
SKIP_SCOPE_CHECK=false
CLEAN_SHARED=false
REPO_URL=""
PROJECT_NAME=""

IMAGE_NAME="vibe-sandbox:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# Utility Functions
# =============================================================================

# Derive a sanitized project name from URL or path
derive_project_name() {
    local input="$1"
    local name=""

    if [[ "$input" =~ \.git$ ]]; then
        # Extract repo name from URL
        name=$(basename "$input" .git)
    elif [[ "$input" =~ ^https?:// ]]; then
        # URL without .git extension
        name=$(basename "$input")
    else
        # Local path - use directory name
        name=$(basename "$input")
    fi

    # Sanitize: lowercase, alphanumeric only, max 20 chars
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-20)

    # Default if empty
    if [[ -z "$name" ]]; then
        name="default"
    fi

    echo "$name"
}

# Detect repository type from URL
detect_repo_type() {
    local url="$1"

    if [[ "$url" =~ github\.com ]]; then
        echo "github"
    elif [[ "$url" =~ dev\.azure\.com ]] || [[ "$url" =~ visualstudio\.com ]]; then
        echo "azuredevops"
    else
        echo "unknown"
    fi
}

# Get git remote URL from current directory
get_git_remote_url() {
    if git remote get-url origin 2>/dev/null; then
        return 0
    fi
    return 1
}

# Set container and volume names based on project
set_resource_names() {
    local project="$1"
    CONTAINER_NAME="vibe-sandbox-${project}"
    VOLUME_NAME="vibe-workspace-${project}"
}

# Calculate ports based on project name hash
get_project_ports() {
    local project="$1"
    local base="${2:-$PORT_BASE}"

    # Calculate hash-based offset (0-99 range, multiplied by 10)
    local hash=$(echo -n "$project" | md5sum | cut -c1-4)
    local offset=$(( (16#$hash % 100) * 10 ))

    CODE_SERVER_PORT=$((base + offset))
    UPLOAD_PORT=$((base + 445 + offset))
}

# Get volume mount arguments for host contexts
get_host_context_mounts() {
    local mounts=""

    # Vibe config (read-write for updates)
    if [[ -d "${HOME}/.vibe" ]]; then
        mounts+=" -v ${HOME}/.vibe:/home/vibe/.vibe:Z"
    fi

    # GitHub CLI auth (read-only)
    if [[ -d "${HOME}/.config/gh" ]]; then
        mounts+=" -v ${HOME}/.config/gh:/home/vibe/.config/gh:ro,Z"
    fi

    # Azure CLI auth (read-only)
    if [[ -d "${HOME}/.azure" ]]; then
        mounts+=" -v ${HOME}/.azure:/home/vibe/.azure:ro,Z"
    fi

    echo "$mounts"
}

# Get Azure DevOps authentication arguments
get_azdo_auth_args() {
    local env_args=""

    # PAT from environment takes precedence
    if [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
        env_args+=" -e AZURE_DEVOPS_PAT=${AZURE_DEVOPS_PAT}"
    fi

    echo "$env_args"
}

# =============================================================================
# Argument Parsing
# =============================================================================

POSITIONAL_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --repo=*)
            REPO_URL="${arg#*=}"
            ;;
        --project=*)
            PROJECT_NAME="${arg#*=}"
            ;;
        --port-base=*)
            PORT_BASE="${arg#*=}"
            ;;
        --branch=*)
            BRANCH="${arg#*=}"
            ;;
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
        --clean-shared)
            CLEAN_SHARED=true
            ;;
        -h|--help|help)
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

# =============================================================================
# Prerequisites Check
# =============================================================================

check_prereqs() {
    log "Checking prerequisites..."

    command -v podman >/dev/null 2>&1 || error "Podman is not installed"

    # Check for Mistral API key
    if [[ -z "${MISTRAL_API_KEY:-}" ]]; then
        warn "MISTRAL_API_KEY not set - Vibe CLI may not work"
    fi

    # Interactive GitHub token setup
    get_gh_token

    log "Prerequisites OK"
}

# Required GitHub token scopes for full functionality
REQUIRED_SCOPES="repo,workflow"

# Check if token has required scopes
check_token_scopes() {
    local scopes
    scopes=$(gh auth status 2>&1 | grep "Token scopes:" | sed "s/.*Token scopes: //" || echo "")

    if [[ -z "$scopes" ]]; then
        warn "Could not determine token scopes"
        return 1
    fi

    log "Current token scopes: $scopes"

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

# =============================================================================
# Build Image
# =============================================================================

build_image() {
    log "Building container image..."

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local dockerfile="$script_dir/Dockerfile.vibe-sandbox"

    if [[ ! -f "$dockerfile" ]]; then
        error "Dockerfile not found: $dockerfile"
    fi

    podman build -t "$IMAGE_NAME" -f "$dockerfile" "$script_dir"

    log "Image built successfully"
}

# =============================================================================
# Run Modes
# =============================================================================

# Get Vibe environment variables for podman
get_vibe_env_args() {
    local env_args=""

    if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
        env_args+=" -e VIBE_ACCEPT_ALL=1"
    fi

    if [[ -n "${VIBE_MODEL:-}" ]]; then
        env_args+=" -e VIBE_MODEL=${VIBE_MODEL}"
    fi

    if [[ -n "${VIBE_PROMPT:-}" ]]; then
        env_args+=" -e VIBE_PROMPT=${VIBE_PROMPT}"
    fi

    echo "$env_args"
}

# Run container with mounted source
run_mount_mode() {
    log "Running in MOUNT mode (current directory mounted)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"
    log "Ports: code-server=$CODE_SERVER_PORT, upload=$UPLOAD_PORT"

    local git_name=$(git config user.name 2>/dev/null || echo "Vibe Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "vibe@localhost")

    local host_mounts=$(get_host_context_mounts)
    local azdo_auth=$(get_azdo_auth_args)
    local vibe_env_args=$(get_vibe_env_args)

    if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
        log "Accept-all mode enabled (VIBE_ACCEPT_ALL=1)"
    fi

    # shellcheck disable=SC2086
    podman run -it --rm \
        --name "$CONTAINER_NAME" \
        -e PROJECT_NAME="$PROJECT_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e MISTRAL_API_KEY="${MISTRAL_API_KEY:-}" \
        $azdo_auth \
        $vibe_env_args \
        -p ${CODE_SERVER_PORT}:8443 \
        -p ${UPLOAD_PORT}:8888 \
        -v "$(pwd):/workspace:Z" \
        $host_mounts \
        "$IMAGE_NAME" \
        "$@"
}

# Run container with cloned source
run_clone_mode() {
    log "Running in CLONE mode (fresh clone inside container)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"
    log "Repository: $REPO_URL"
    log "Ports: code-server=$CODE_SERVER_PORT, upload=$UPLOAD_PORT"

    local git_name=$(git config user.name 2>/dev/null || echo "Vibe Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "vibe@localhost")

    local host_mounts=$(get_host_context_mounts)
    local azdo_auth=$(get_azdo_auth_args)
    local vibe_env_args=$(get_vibe_env_args)

    if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
        log "Accept-all mode enabled (VIBE_ACCEPT_ALL=1)"
    fi

    # shellcheck disable=SC2086
    podman run -it --rm \
        --name "$CONTAINER_NAME" \
        -e PROJECT_NAME="$PROJECT_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e MISTRAL_API_KEY="${MISTRAL_API_KEY:-}" \
        -e REPO_URL="$REPO_URL" \
        -e BRANCH="$BRANCH" \
        $azdo_auth \
        $vibe_env_args \
        -p ${CODE_SERVER_PORT}:8443 \
        -p ${UPLOAD_PORT}:8888 \
        -v "${VOLUME_NAME}:/workspace:Z" \
        $host_mounts \
        "$IMAGE_NAME" \
        "$@"
}

# Recover a stopped container
run_recover_mode() {
    log "Attempting to recover container: $CONTAINER_NAME"

    if ! podman container exists "$CONTAINER_NAME"; then
        error "Container $CONTAINER_NAME does not exist"
    fi

    local state=$(podman container inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null)

    if [[ "$state" == "running" ]]; then
        log "Container is running, attaching..."
        podman attach "$CONTAINER_NAME"
    elif [[ "$state" == "exited" ]] || [[ "$state" == "stopped" ]]; then
        log "Container is stopped, starting and attaching..."
        podman start -ai "$CONTAINER_NAME"
    else
        error "Container is in unexpected state: $state"
    fi
}

# Clean up resources
run_clean_mode() {
    log "Cleaning up project resources: $PROJECT_NAME"

    # Stop and remove container
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        log "Stopping container: $CONTAINER_NAME"
        podman stop "$CONTAINER_NAME" 2>/dev/null || true
        podman rm "$CONTAINER_NAME" 2>/dev/null || true
    fi

    # Remove volume
    if podman volume exists "$VOLUME_NAME" 2>/dev/null; then
        log "Removing volume: $VOLUME_NAME"
        podman volume rm "$VOLUME_NAME" 2>/dev/null || true
    fi

    # Clean shared resources if requested
    if [[ "$CLEAN_SHARED" == "true" ]]; then
        log "Cleaning shared resources..."

        # Stop Jaeger
        if podman container exists jaeger 2>/dev/null; then
            log "Stopping Jaeger..."
            podman stop jaeger 2>/dev/null || true
            podman rm jaeger 2>/dev/null || true
        fi
    fi

    log "Cleanup complete"
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Initialize project name from various sources
    if [[ -z "$PROJECT_NAME" ]]; then
        if [[ -n "$REPO_URL" ]]; then
            PROJECT_NAME=$(derive_project_name "$REPO_URL")
        elif git_url=$(get_git_remote_url 2>/dev/null); then
            REPO_URL="$git_url"
            PROJECT_NAME=$(derive_project_name "$git_url")
        else
            PROJECT_NAME=$(derive_project_name "$(pwd)")
        fi
    fi

    # Set resource names based on project
    set_resource_names "$PROJECT_NAME"

    # Calculate ports
    get_project_ports "$PROJECT_NAME" "$PORT_BASE"

    case "$MODE" in
        mount)
            check_prereqs
            if ! podman image exists "$IMAGE_NAME"; then
                build_image
            else
                log "Using existing image (run './vibe-sandbox.sh build' to rebuild)"
            fi
            shift || true
            run_mount_mode "$@"
            ;;
        clone)
            if [[ -z "$REPO_URL" ]]; then
                error "No repository URL. Use --repo=URL or run from a git directory"
            fi
            check_prereqs
            if ! podman image exists "$IMAGE_NAME"; then
                build_image
            else
                log "Using existing image (run './vibe-sandbox.sh build' to rebuild)"
            fi
            shift || true
            run_clone_mode "$@"
            ;;
        build)
            build_image
            ;;
        recover)
            run_recover_mode
            ;;
        clean)
            run_clean_mode
            ;;
        *)
            error "Unknown mode: $MODE (use 'mount', 'clone', 'build', 'recover', or 'clean')"
            ;;
    esac
}

main "$@"
