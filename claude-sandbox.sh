#!/bin/bash
# Run Claude Code in a sandboxed Podman container
#
# Multi-project portable sandbox with support for:
#   - Any git repository (GitHub, Azure DevOps)
#   - Concurrent container execution (one per project)
#   - Host context mounting (reuse existing auth)
#   - Jaeger tracing for observability
#
# Usage:
#   ./claude-sandbox.sh mount                    # Mount current directory
#   ./claude-sandbox.sh clone                    # Clone from git remote
#   ./claude-sandbox.sh --repo=URL clone         # Clone specific repo
#   ./claude-sandbox.sh --project=NAME mount     # Explicit project name
#   ./claude-sandbox.sh --help                   # Show full help

set -euo pipefail

# Default values when no parameters are given
if [[ $# -eq 0 ]]; then
    set -- mount
fi

# Show help message
show_help() {
    cat << EOF
Claude Sandbox - Multi-Project Portable Development Environment

Usage:
  ./claude-sandbox.sh [options] [clone|mount|recover|clean|build]
  ./claude-sandbox.sh                    # Default: mount current directory

Project Options:
  --repo=URL           Repository URL (GitHub or Azure DevOps)
  --project=NAME       Project name for container/volume naming (auto-derived if not set)
  --branch=BRANCH      Branch to checkout in clone mode [default: main]

Port Options:
  --port-base=PORT     Base port for services [default: 18443]
                       code-server: base, upload: base+445, api-logger: base+357

Observability:
  --otel               Enable OpenTelemetry tracing with Jaeger
  --log-api            Enable API traffic logging to JSON files

Container Options:
  --rm                 Remove container on exit (disables 'recover' mode)
  --skip-scope-check   Skip GitHub token scope validation
  -h, --help           Show this help message

Modes:
  clone                Clone repo into persistent volume (survives crashes)
  mount                Mount current directory (default)
  recover              Restart and attach to a stopped container
  clean                Remove containers/volumes/images
  build                Rebuild the Docker image

Examples:
  # Mount current directory (derives project name from dirname)
  ./claude-sandbox.sh mount

  # Clone from current git remote
  ./claude-sandbox.sh clone

  # Clone specific repository
  ./claude-sandbox.sh --repo=https://github.com/user/repo.git clone

  # Clone Azure DevOps repository
  ./claude-sandbox.sh --repo=https://dev.azure.com/org/project/_git/repo clone

  # With Jaeger tracing
  ./claude-sandbox.sh --otel mount

  # Custom port range (for running multiple instances)
  ./claude-sandbox.sh --port-base=20000 mount

  # Recover crashed container
  ./claude-sandbox.sh recover

  # Rebuild image
  ./claude-sandbox.sh build

Volumes (per-project):
  claude-workspace-{project}   Workspace for clone mode
  claude-home-{project}        Home directory (configs, plugins, history)

Shared Services:
  Jaeger UI: http://localhost:16686 (when --otel enabled)

Host Context (mounted from host):
  ~/.anthropic         API credentials (read-write)
  ~/.claude            Settings (read-only, writes go to container volume)
  ~/.config/gh         GitHub CLI auth (read-only)
  ~/.azure             Azure CLI auth (read-only)

Clean mode options:
  --containers         Remove project containers
  --volumes            Remove project volumes
  --images             Remove images
  --clean-shared       Also remove shared Jaeger container
  --all                Remove everything for current project

Cleanup examples:
  ./claude-sandbox.sh clean --containers      # Stop and remove project containers
  ./claude-sandbox.sh clean --all             # Full project cleanup
  ./claude-sandbox.sh clean --all --clean-shared  # Include shared Jaeger
EOF
}

# Parse flags
OTEL_ENABLED=false
LOG_API_ENABLED=false
SKIP_SCOPE_CHECK=false
BRANCH="main"                    # Default to main branch
KEEP_CONTAINER=true              # Keep containers by default (enables recovery)
CLEAN_IMAGES=false
CLEAN_VOLUMES=false
CLEAN_CONTAINERS=false
CLEAN_SHARED=false               # Clean shared resources (Jaeger)
REPO_URL=""                      # Empty = derive from git remote or skip
PROJECT_NAME=""                  # Empty = derive from repo/directory
PORT_BASE=18443                  # Base port for services
POSITIONAL_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --otel)
            OTEL_ENABLED=true
            ;;
        --log-api)
            LOG_API_ENABLED=true
            ;;
        --skip-scope-check)
            SKIP_SCOPE_CHECK=true
            ;;
        --rm)
            KEEP_CONTAINER=false
            ;;
        --images)
            CLEAN_IMAGES=true
            ;;
        --volumes)
            CLEAN_VOLUMES=true
            ;;
        --containers)
            CLEAN_CONTAINERS=true
            ;;
        --clean-shared)
            CLEAN_SHARED=true
            ;;
        --all)
            CLEAN_IMAGES=true
            CLEAN_VOLUMES=true
            CLEAN_CONTAINERS=true
            ;;
        --branch=*)
            BRANCH="${arg#*=}"
            ;;
        --repo=*)
            REPO_URL="${arg#*=}"
            ;;
        --project=*)
            PROJECT_NAME="${arg#*=}"
            ;;
        --port-base=*)
            PORT_BASE="${arg#*=}"
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

# Base image name (container/volume names are set dynamically per project)
IMAGE_NAME="claude-sandbox:latest"
API_LOGGER_IMAGE="claude-api-logger:latest"

# Shared resources (not per-project)
JAEGER_CONTAINER="jaeger"
JAEGER_UI_PORT=16686
JAEGER_OTLP_PORT=4318

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

# Derive project name from repo URL or directory path
# Returns a sanitized name suitable for container/volume naming
derive_project_name() {
    local source="$1"
    local name=""

    if [[ "$source" =~ ^https?:// ]] || [[ "$source" =~ ^git@ ]]; then
        # Extract repo name from URL
        # Handles: https://github.com/owner/repo.git
        #          https://dev.azure.com/org/project/_git/repo
        #          git@github.com:owner/repo.git
        name=$(echo "$source" | sed -E 's/.*[\/:]([^\/]+)(\.git)?$/\1/' | sed 's/\.git$//')
    else
        # Use directory basename
        name=$(basename "$source")
    fi

    # Sanitize: lowercase, replace non-alphanumeric with dash, max 20 chars
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-20)

    # Remove leading/trailing dashes
    name=$(echo "$name" | sed 's/^-*//;s/-*$//')

    echo "${name:-sandbox}"
}

# Detect repository host type
# Returns: "github", "azuredevops", or "unknown"
detect_repo_type() {
    local url="$1"

    if [[ "$url" =~ github\.com ]] || [[ "$url" =~ ^git@github\.com ]]; then
        echo "github"
    elif [[ "$url" =~ dev\.azure\.com ]] || [[ "$url" =~ visualstudio\.com ]] || [[ "$url" =~ azure\.com.*/_git/ ]]; then
        echo "azuredevops"
    else
        echo "unknown"
    fi
}

# Get repo URL from current git directory
get_git_remote_url() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git remote get-url origin 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Set resource names based on project
set_resource_names() {
    local project="$1"

    CONTAINER_NAME="claude-sandbox-${project}"
    WORKSPACE_VOLUME="claude-workspace-${project}"
    CLAUDE_HOME_VOLUME="claude-home-${project}"
    API_LOGGER_CONTAINER="claude-api-logger-${project}"
}

# Calculate ports based on project name hash
get_project_ports() {
    local project="$1"
    local base="${PORT_BASE:-18443}"

    # Use first 4 hex digits of MD5 hash modulo 100 for offset
    local hash=$(echo -n "$project" | md5 -q 2>/dev/null || echo -n "$project" | md5sum | cut -c1-4)
    hash=$(echo "$hash" | cut -c1-4)
    local offset=$(( 16#$hash % 100 ))
    local port_offset=$((offset * 10))

    CODE_SERVER_PORT=$((base + port_offset))
    UPLOAD_PORT=$((base + 445 + port_offset))
    API_LOGGER_PORT=$((base + 357 + port_offset))
}

# Get host context mount arguments
get_host_context_mounts() {
    local mounts=""

    # ~/.anthropic (read-write for updatable auth credentials)
    if [[ -d "$HOME/.anthropic" ]]; then
        mounts+="-v $HOME/.anthropic:/home/claude/.anthropic:Z "
    fi

    # ~/.claude (read-only, container writes to volume for local settings)
    if [[ -d "$HOME/.claude" ]]; then
        mounts+="-v $HOME/.claude:/home/claude/.claude-host:ro "
    fi

    # ~/.config/gh (read-only for GitHub CLI auth)
    if [[ -d "$HOME/.config/gh" ]]; then
        mounts+="-v $HOME/.config/gh:/home/claude/.config/gh:ro "
    fi

    # ~/.azure (read-only for Azure CLI auth)
    if [[ -d "$HOME/.azure" ]]; then
        mounts+="-v $HOME/.azure:/home/claude/.azure:ro "
    fi

    echo "$mounts"
}

# Get Azure DevOps authentication environment variables
get_azdo_auth_args() {
    local repo_type="$1"
    local auth_args=""

    if [[ "$repo_type" != "azuredevops" ]]; then
        echo ""
        return 0
    fi

    # AZURE_DEVOPS_PAT environment variable (takes precedence)
    if [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
        auth_args+="-e AZURE_DEVOPS_PAT=${AZURE_DEVOPS_PAT} "
    fi

    echo "$auth_args"
}

# Start Jaeger for OTel tracing (shared instance)
start_jaeger() {
    log "Checking Jaeger status..."

    # Check if Jaeger is already running
    if podman container exists "$JAEGER_CONTAINER" 2>/dev/null; then
        local state=$(podman inspect --format '{{.State.Status}}' "$JAEGER_CONTAINER" 2>/dev/null || echo "unknown")
        if [[ "$state" == "running" ]]; then
            log "Jaeger is already running (shared instance)"
            log "Jaeger UI: http://localhost:${JAEGER_UI_PORT}"
            return 0
        else
            log "Restarting stopped Jaeger container..."
            podman start "$JAEGER_CONTAINER"
            log "Jaeger UI: http://localhost:${JAEGER_UI_PORT}"
            return 0
        fi
    fi

    log "Starting Jaeger for OTel tracing (shared instance)..."

    # Start Jaeger all-in-one (no --rm so it persists)
    podman run -d \
        --name "$JAEGER_CONTAINER" \
        -p ${JAEGER_UI_PORT}:16686 \
        -p ${JAEGER_OTLP_PORT}:4318 \
        jaegertracing/all-in-one:latest

    log "Jaeger UI: http://localhost:${JAEGER_UI_PORT}"
    log "Jaeger OTLP Endpoint: http://host.containers.internal:${JAEGER_OTLP_PORT}"
}

# Get OTel environment variables for podman (points to Jaeger)
get_otel_env_args() {
    if [[ "$OTEL_ENABLED" == "true" ]]; then
        echo "-e CLAUDE_CODE_ENABLE_TELEMETRY=1 \
              -e OTEL_EXPORTER_OTLP_ENDPOINT=http://host.containers.internal:${JAEGER_OTLP_PORT} \
              -e OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
              -e OTEL_TRACES_EXPORTER=otlp \
              -e OTEL_METRICS_EXPORTER=none \
              -e OTEL_LOGS_EXPORTER=otlp"
    fi
}

# Build the API logger image
build_api_logger_image() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local logger_dir="$script_dir/claude-api-logger"

    if [[ ! -d "$logger_dir" ]]; then
        error "API logger directory not found: $logger_dir"
    fi

    log "Building API logger image..."
    podman build -t "$API_LOGGER_IMAGE" "$logger_dir"
    log "API logger image built successfully"
}

# Start the API logger container (per-project, logs to JSON files)
start_api_logger() {
    log "Starting API traffic logger for project..."

    # Remove existing container if present
    podman rm -f "$API_LOGGER_CONTAINER" 2>/dev/null || true

    # Build image if it doesn't exist
    if ! podman image exists "$API_LOGGER_IMAGE"; then
        build_api_logger_image
    fi

    # Start the logger container with project-specific port and log directory
    podman run -d --rm \
        --name "$API_LOGGER_CONTAINER" \
        -p ${API_LOGGER_PORT}:8000 \
        -e PROJECT_NAME="${PROJECT_NAME}" \
        -v "${CLAUDE_HOME_VOLUME}:/data:Z" \
        "$API_LOGGER_IMAGE"

    log "API Logger Proxy: http://localhost:${API_LOGGER_PORT}"
    log "API logs saved to ~/api-logs/ in container"
}

# Get API logger environment variables for Claude container
get_api_logger_env_args() {
    if [[ "$LOG_API_ENABLED" == "true" ]]; then
        # Point Claude Code to our proxy instead of Anthropic directly
        echo "-e ANTHROPIC_BASE_URL=http://host.containers.internal:${API_LOGGER_PORT}"
    fi
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
    local dockerfile="$script_dir/Dockerfile.claude-sandbox"

    if [[ ! -f "$dockerfile" ]]; then
        error "Dockerfile not found: $dockerfile"
    fi

    podman build -t "$IMAGE_NAME" -f "$dockerfile" "$script_dir/.."

    log "Image built successfully"
}

# Run container with mounted source
run_mount_mode() {
    log "Running in MOUNT mode (current directory mounted)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"

    local git_name=$(git config user.name 2>/dev/null || echo "Claude Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "claude@localhost")

    # Get OTel environment variables
    local otel_args=""
    if [[ "$OTEL_ENABLED" == "true" ]]; then
        otel_args=$(get_otel_env_args)
    fi

    # Get API logger environment variables
    local api_logger_args=""
    if [[ "$LOG_API_ENABLED" == "true" ]]; then
        api_logger_args=$(get_api_logger_env_args)
    fi

    # Get host context mounts
    local host_mounts=$(get_host_context_mounts)

    # Get Azure DevOps auth if applicable
    local repo_type=$(detect_repo_type "${REPO_URL:-}")
    local azdo_args=$(get_azdo_auth_args "$repo_type")

    # Determine if we should use --rm
    local rm_flag=""
    if [[ "$KEEP_CONTAINER" == "false" ]]; then
        rm_flag="--rm"
        log "Container will be removed after exit (--rm)"
    fi

    # Remove existing container if it exists (can't reuse name otherwise)
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

    # Create claude home volume if it doesn't exist (persists entire home directory)
    if ! podman volume exists "$CLAUDE_HOME_VOLUME"; then
        log "Creating claude home volume: $CLAUDE_HOME_VOLUME"
        podman volume create "$CLAUDE_HOME_VOLUME"
    fi

    log "Home directory: $CLAUDE_HOME_VOLUME volume (persists across runs)"
    log "Ports: code-server=$CODE_SERVER_PORT, upload=$UPLOAD_PORT"

    # Get Podman socket path
    local podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ ! -S "$podman_socket" ]]; then
        podman_socket="/run/user/$(id -u)/podman/podman.sock"
    fi

    # shellcheck disable=SC2086
    podman run -it $rm_flag \
        --name "$CONTAINER_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e DOCKER_HOST="unix:///var/run/docker.sock" \
        -e PROJECT_NAME="$PROJECT_NAME" \
        -p ${CODE_SERVER_PORT}:8443 \
        -p ${UPLOAD_PORT}:8888 \
        -v "$(pwd):/workspace:Z" \
        -v "$CLAUDE_HOME_VOLUME:/home/claude:Z" \
        -v "$podman_socket:/var/run/docker.sock:Z" \
        $host_mounts \
        $otel_args \
        $api_logger_args \
        $azdo_args \
        "$IMAGE_NAME" \
        "$@"
}

# Run container with cloned source
run_clone_mode() {
    log "Running in CLONE mode (workspace on persistent volume)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"
    log "Repository: $REPO_URL"

    local git_name=$(git config user.name 2>/dev/null || echo "Claude Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "claude@localhost")
    local branch="$BRANCH"

    # Get OTel environment variables
    local otel_args=""
    if [[ "$OTEL_ENABLED" == "true" ]]; then
        otel_args=$(get_otel_env_args)
    fi

    # Get API logger environment variables
    local api_logger_args=""
    if [[ "$LOG_API_ENABLED" == "true" ]]; then
        api_logger_args=$(get_api_logger_env_args)
    fi

    # Get host context mounts
    local host_mounts=$(get_host_context_mounts)

    # Get Azure DevOps auth if applicable
    local repo_type=$(detect_repo_type "$REPO_URL")
    local azdo_args=$(get_azdo_auth_args "$repo_type")
    if [[ "$repo_type" == "azuredevops" ]]; then
        log "Repository type: Azure DevOps"
    fi

    # Determine if we should use --rm
    local rm_flag=""
    if [[ "$KEEP_CONTAINER" == "false" ]]; then
        rm_flag="--rm"
        log "Container will be removed after exit (--rm)"
    fi

    # Create workspace volume if it doesn't exist
    if ! podman volume exists "$WORKSPACE_VOLUME"; then
        log "Creating workspace volume: $WORKSPACE_VOLUME"
        podman volume create "$WORKSPACE_VOLUME"
    else
        log "Reusing existing workspace volume: $WORKSPACE_VOLUME"
    fi

    # Create claude home volume if it doesn't exist (persists entire home directory)
    if ! podman volume exists "$CLAUDE_HOME_VOLUME"; then
        log "Creating claude home volume: $CLAUDE_HOME_VOLUME"
        podman volume create "$CLAUDE_HOME_VOLUME"
    fi

    log "Home directory: $CLAUDE_HOME_VOLUME volume (persists across runs)"
    log "Ports: code-server=$CODE_SERVER_PORT, upload=$UPLOAD_PORT"

    # Remove existing container if it exists (can't reuse name otherwise)
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

    # Get Podman socket path
    local podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ ! -S "$podman_socket" ]]; then
        podman_socket="/run/user/$(id -u)/podman/podman.sock"
    fi

    # shellcheck disable=SC2086
    podman run -it $rm_flag \
        --name "$CONTAINER_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e REPO_URL="$REPO_URL" \
        -e BRANCH="$branch" \
        -e DOCKER_HOST="unix:///var/run/docker.sock" \
        -e PROJECT_NAME="$PROJECT_NAME" \
        -p ${CODE_SERVER_PORT}:8443 \
        -p ${UPLOAD_PORT}:8888 \
        -v "$WORKSPACE_VOLUME:/workspace:Z" \
        -v "$CLAUDE_HOME_VOLUME:/home/claude:Z" \
        -v "$podman_socket:/var/run/docker.sock:Z" \
        $host_mounts \
        $otel_args \
        $api_logger_args \
        $azdo_args \
        "$IMAGE_NAME" \
        "$@"
}

# Recover and attach to an existing stopped container
run_recover_mode() {
    log "Running in RECOVER mode (restarting stopped container)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"

    # Check if container exists
    if ! podman container exists "$CONTAINER_NAME"; then
        error "No container named '$CONTAINER_NAME' found. Run with 'clone' or 'mount' first."
    fi

    # Check container state
    local state
    state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

    case "$state" in
        running)
            log "Container is already running, attaching..."
            podman attach "$CONTAINER_NAME"
            ;;
        exited|stopped|created)
            log "Container state: $state. Starting and attaching..."

            # Start Jaeger if it exists but is stopped
            if podman container exists "$JAEGER_CONTAINER"; then
                local jaeger_state
                jaeger_state=$(podman inspect --format '{{.State.Status}}' "$JAEGER_CONTAINER" 2>/dev/null || echo "unknown")
                if [[ "$jaeger_state" != "running" ]]; then
                    log "Restarting Jaeger container..."
                    podman start "$JAEGER_CONTAINER"
                fi
            fi

            # Start API logger if it exists
            if podman container exists "$API_LOGGER_CONTAINER"; then
                local logger_state
                logger_state=$(podman inspect --format '{{.State.Status}}' "$API_LOGGER_CONTAINER" 2>/dev/null || echo "unknown")
                if [[ "$logger_state" != "running" ]]; then
                    log "Restarting API logger container..."
                    podman start "$API_LOGGER_CONTAINER"
                fi
            fi

            # Start and attach atomically (avoids race condition)
            podman start -ai "$CONTAINER_NAME"
            ;;
        *)
            error "Container is in unexpected state: $state"
            ;;
    esac
}

# Clean up containers, volumes, and/or images
run_clean_mode() {
    local cleaned=false

    log "Cleaning project: $PROJECT_NAME"

    # Check if any clean option was specified
    if [[ "$CLEAN_CONTAINERS" == "false" ]] && [[ "$CLEAN_VOLUMES" == "false" ]] && [[ "$CLEAN_IMAGES" == "false" ]]; then
        error "Clean mode requires at least one of: --containers, --volumes, --images, or --all"
    fi

    # Clean project containers
    if [[ "$CLEAN_CONTAINERS" == "true" ]]; then
        log "Removing project containers..."
        for container in "$CONTAINER_NAME" "$API_LOGGER_CONTAINER"; do
            if podman container exists "$container" 2>/dev/null; then
                log "  Removing container: $container"
                podman rm -f "$container" 2>/dev/null || true
            fi
        done

        # Clean shared Jaeger if requested
        if [[ "$CLEAN_SHARED" == "true" ]]; then
            log "Removing shared containers..."
            if podman container exists "$JAEGER_CONTAINER" 2>/dev/null; then
                log "  Removing container: $JAEGER_CONTAINER"
                podman rm -f "$JAEGER_CONTAINER" 2>/dev/null || true
            fi
        fi
        cleaned=true
    fi

    # Clean project volumes
    if [[ "$CLEAN_VOLUMES" == "true" ]]; then
        log "Removing project volumes..."
        for volume in "$WORKSPACE_VOLUME" "$CLAUDE_HOME_VOLUME"; do
            if podman volume exists "$volume" 2>/dev/null; then
                log "  Removing volume: $volume"
                podman volume rm "$volume" 2>/dev/null || true
            fi
        done
        cleaned=true
    fi

    # Clean images
    if [[ "$CLEAN_IMAGES" == "true" ]]; then
        log "Removing images..."
        for image in "$IMAGE_NAME" "$API_LOGGER_IMAGE"; do
            if podman image exists "$image" 2>/dev/null; then
                log "  Removing image: $image"
                podman rmi "$image" 2>/dev/null || true
            fi
        done
        cleaned=true
    fi

    if [[ "$cleaned" == "true" ]]; then
        log "Cleanup complete"
    fi
}

# Main
main() {
    # Handle -h or help flags to pass to Claude Code CLI
    if [[ "$1" == "-h" ]] || [[ "$1" == "help" ]]; then
        show_help
        exit 0
    fi

    # ==========================================================================
    # Initialize project name and resource names
    # ==========================================================================

    # Determine project name
    if [[ -n "$PROJECT_NAME" ]]; then
        # Explicit project name provided
        :
    elif [[ "$MODE" == "clone" ]]; then
        # Clone mode: derive from repo URL
        if [[ -z "$REPO_URL" ]]; then
            # Try to get from current git remote
            REPO_URL=$(get_git_remote_url)
            if [[ -z "$REPO_URL" ]]; then
                error "Clone mode requires --repo=URL or being in a git repository with an origin remote"
            fi
        fi
        PROJECT_NAME=$(derive_project_name "$REPO_URL")
    else
        # Mount/other modes: derive from current directory
        PROJECT_NAME=$(derive_project_name "$(pwd)")
    fi

    # Set resource names based on project
    set_resource_names "$PROJECT_NAME"

    # Calculate ports
    get_project_ports "$PROJECT_NAME"

    # ==========================================================================
    # Handle modes
    # ==========================================================================

    # Handle modes that don't need full setup
    case "$MODE" in
        clean)
            run_clean_mode
            return
            ;;
        build)
            build_image
            return
            ;;
    esac

    # Full setup for container modes
    check_prereqs

    # Build image if it doesn't exist
    if ! podman image exists "$IMAGE_NAME"; then
        build_image
    else
        log "Using existing image (run 'podman rmi $IMAGE_NAME' to rebuild)"
    fi

    # Start Jaeger if OTel is enabled
    if [[ "$OTEL_ENABLED" == "true" ]]; then
        start_jaeger
    fi

    # Start API logger if enabled
    if [[ "$LOG_API_ENABLED" == "true" ]]; then
        start_api_logger
    fi

    shift || true  # Remove mode argument

    case "$MODE" in
        mount)
            run_mount_mode "$@"
            ;;
        clone)
            run_clone_mode "$@"
            ;;
        recover)
            run_recover_mode
            ;;
        *)
            error "Unknown mode: $MODE (use 'mount', 'clone', 'recover', 'clean', or 'build')"
            ;;
    esac
}

main "$@"
