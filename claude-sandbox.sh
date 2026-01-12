#!/bin/bash
# Run Claude Code in a sandboxed Podman container
#
# Simplified Usage:
#   ./scripts/claude-sandbox.sh --otel clone          # Default: persistent Seq + main branch
#   ./scripts/claude-sandbox.sh --otel --log-api clone    # With full API traffic logging
#   ./scripts/claude-sandbox.sh --otel --no-persist clone  # Ephemeral Seq
#   ./scripts/claude-sandbox.sh --help                # Show full help
#
# Features:
#   - Seq OTel receiver with persistence control
#   - API traffic logging via proxy (--log-api)
#   - Simple branch specification
#   - Clean, focused interface

set -euo pipefail

# Default values when no parameters are given
if [[ $# -eq 0 ]]; then
    set -- --otel clone
fi

# Show help message
show_help() {
    cat << EOF
Claude Sandbox Script - Simplified Development Environment

Usage:
  ./scripts/claude-sandbox.sh [options] [clone|mount]
  ./scripts/claude-sandbox.sh          # Default: --otel clone

Options:
  --otel             Enable OpenTelemetry logging with Seq
  --log-api          Enable full API traffic logging (requires --otel)
  --no-persist       Disable Seq volume persistence (ephemeral mode)
  --branch=BRANCH    Branch to checkout in clone mode [default: main]
  --rm               Remove container on exit (disables 'recover' mode)
  --skip-scope-check Skip GitHub token scope validation
  -h, --help         Show this help message

Modes:
  clone              Clone repo into persistent volume (survives crashes)
  mount              Mount current directory (faster, changes persist)
  recover            Restart and attach to a stopped container
  clean              Remove containers/volumes/images (use with --containers, --volumes, --images, --all)

Examples:
  # Default: Seq with persistence + main branch
  ./scripts/claude-sandbox.sh --otel clone

  # With full API traffic logging (see all requests/responses)
  ./scripts/claude-sandbox.sh --otel --log-api clone

  # Ephemeral Seq (no persistence)
  ./scripts/claude-sandbox.sh --otel --no-persist clone

  # Specific branch
  ./scripts/claude-sandbox.sh --otel --branch=feature-branch clone

  # Just mount current directory
  ./scripts/claude-sandbox.sh mount

  # If container crashes, recover and continue:
  ./scripts/claude-sandbox.sh recover

  # Auto-remove container on exit (no recovery possible)
  ./scripts/claude-sandbox.sh --otel --rm clone

  # Rebuild the Docker image
  ./scripts/claude-sandbox.sh build

  # Pass -h to Claude Code CLI for help
  ./scripts/claude-sandbox.sh -h
  ./scripts/claude-sandbox.sh help

Volumes:
  claude-workspace   Workspace for clone mode (survives crashes)
  claude-home        Entire /home/claude directory (configs, plugins, history, files)
  seq-data           Seq logs (with --otel, unless --no-persist)

File Upload:
  A web upload server runs at http://localhost:8888 allowing you to:
  - Drag & drop files to upload them to the container
  - Paste images from clipboard (Ctrl+V / Cmd+V)
  Files are saved to ~/share in the container (persisted in claude-home volume)

Clean mode options (use with 'clean'):
  --containers       Remove sandbox containers (claude-sandbox, seq-otel, claude-api-logger)
  --volumes          Remove volumes (claude-workspace, claude-config, seq-data)
  --images           Remove images (claude-sandbox, claude-api-logger)
  --all              Remove everything (containers + volumes + images)

Cleanup examples:
  ./scripts/claude-sandbox.sh clean --containers   # Stop and remove containers
  ./scripts/claude-sandbox.sh clean --volumes      # Remove persistent data
  ./scripts/claude-sandbox.sh clean --all          # Full cleanup
EOF
}

# Parse flags
OTEL_ENABLED=false
LOG_API_ENABLED=false
SKIP_SCOPE_CHECK=false
SEQ_PERSIST=true   # Default to persistent (with volume)
BRANCH="main"      # Default to main branch
KEEP_CONTAINER=true   # Keep containers by default (enables recovery)
CLEAN_IMAGES=false
CLEAN_VOLUMES=false
CLEAN_CONTAINERS=false
POSITIONAL_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --otel)
            OTEL_ENABLED=true
            ;;
        --log-api)
            LOG_API_ENABLED=true
            ;;
        --no-persist)
            SEQ_PERSIST=false
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
        --all)
            CLEAN_IMAGES=true
            CLEAN_VOLUMES=true
            CLEAN_CONTAINERS=true
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
CONTAINER_NAME="claude-sandbox"
IMAGE_NAME="claude-sandbox:latest"
WORKSPACE_VOLUME="claude-workspace"  # Volume for clone mode workspace
CLAUDE_HOME_VOLUME="claude-home"  # Volume for /home/claude (persists everything)
SHARE_DIR="${HOME}/.claude-sandbox-share"  # Shared directory with host for file exchange

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Start Seq for OTel logging
start_seq() {
    log "Starting Seq for OTel logging..."

    # Remove existing container if present
    podman rm -f seq-otel 2>/dev/null || true

    local volume_args=""
    local persist_msg=""

    if [[ "$SEQ_PERSIST" == "true" ]]; then
        # Create volume for persistent storage if it doesn't exist
        if ! podman volume exists seq-data; then
            podman volume create seq-data
        fi
        volume_args="-v seq-data:/data"
        persist_msg="(persistent)"
    else
        persist_msg="(ephemeral)"
    fi

        # Start Seq (port 80 serves both UI and OTLP ingestion)
        podman run -d --rm \
            --name seq-otel \
            -p 5341:80 \
            -e ACCEPT_EULA=Y \
            $volume_args \
            datalust/seq:latest

    log "Seq Dashboard: http://localhost:5341 $persist_msg"
    log "Seq OTLP Endpoint: http://host.containers.internal:5341/ingest/otlp (http/protobuf)"
}

# Get OTel environment variables for podman
get_otel_env_args() {
    if [[ "$OTEL_ENABLED" == "true" ]]; then
        echo "-e CLAUDE_CODE_ENABLE_TELEMETRY=1 \
              -e OTEL_LOG_USER_PROMPTS=1 \
              -e OTEL_LOGS_EXPORTER=otlp \
              -e OTEL_EXPORTER_OTLP_ENDPOINT=http://host.containers.internal:5341/ingest/otlp \
              -e OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"
    fi
}

# API Logger image name
API_LOGGER_IMAGE="claude-api-logger:latest"
API_LOGGER_CONTAINER="claude-api-logger"

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

# Start the API logger container
start_api_logger() {
    log "Starting API traffic logger..."

    # Remove existing container if present
    podman rm -f "$API_LOGGER_CONTAINER" 2>/dev/null || true

    # Build image if it doesn't exist
    if ! podman image exists "$API_LOGGER_IMAGE"; then
        build_api_logger_image
    fi

    # Start the logger container
    # Uses host network to communicate with Seq on host.containers.internal
    podman run -d --rm \
        --name "$API_LOGGER_CONTAINER" \
        -p 8800:8000 \
        -e SEQ_HOST=host.containers.internal \
        "$API_LOGGER_IMAGE"

    log "API Logger Proxy: http://localhost:8800"
    log "Traffic logs will appear in Seq Dashboard"
}

# Get API logger environment variables for Claude container
get_api_logger_env_args() {
    if [[ "$LOG_API_ENABLED" == "true" ]]; then
        # Point Claude Code to our proxy instead of Anthropic directly
        echo "-e ANTHROPIC_BASE_URL=http://host.containers.internal:8800"
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
    log "Upload server: http://localhost:8888 (drag & drop files to ~/share)"

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
        -p 8443:8443 \
        -p 8888:8888 \
        -v "$(pwd):/workspace:Z" \
        -v "$CLAUDE_HOME_VOLUME:/home/claude:Z" \
        -v "$podman_socket:/var/run/docker.sock:Z" \
        $otel_args \
        $api_logger_args \
        "$IMAGE_NAME" \
        "$@"
}

# Run container with cloned source
run_clone_mode() {
    log "Running in CLONE mode (workspace on persistent volume)"

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
    log "Upload server: http://localhost:8888 (drag & drop files to ~/share)"

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
        -p 8443:8443 \
        -p 8888:8888 \
        -v "$WORKSPACE_VOLUME:/workspace:Z" \
        -v "$CLAUDE_HOME_VOLUME:/home/claude:Z" \
        -v "$podman_socket:/var/run/docker.sock:Z" \
        $otel_args \
        $api_logger_args \
        "$IMAGE_NAME" \
        "$@"
}

# Recover and attach to an existing stopped container
run_recover_mode() {
    log "Running in RECOVER mode (restarting stopped container)"

    # Check if container exists
    if ! podman container exists "$CONTAINER_NAME"; then
        error "No container named '$CONTAINER_NAME' found. Run with 'clone' or 'mount' first (use --keep to enable recovery)."
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

            # Start Seq if OTel was enabled (check if seq-otel container exists)
            if podman container exists seq-otel; then
                local seq_state
                seq_state=$(podman inspect --format '{{.State.Status}}' seq-otel 2>/dev/null || echo "unknown")
                if [[ "$seq_state" != "running" ]]; then
                    log "Restarting Seq container..."
                    podman start seq-otel
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

    # Check if any clean option was specified
    if [[ "$CLEAN_CONTAINERS" == "false" ]] && [[ "$CLEAN_VOLUMES" == "false" ]] && [[ "$CLEAN_IMAGES" == "false" ]]; then
        error "Clean mode requires at least one of: --containers, --volumes, --images, or --all"
    fi

    # Clean containers
    if [[ "$CLEAN_CONTAINERS" == "true" ]]; then
        log "Removing containers..."
        for container in "$CONTAINER_NAME" "seq-otel" "$API_LOGGER_CONTAINER"; do
            if podman container exists "$container" 2>/dev/null; then
                log "  Removing container: $container"
                podman rm -f "$container" 2>/dev/null || true
            fi
        done
        cleaned=true
    fi

    # Clean volumes
    if [[ "$CLEAN_VOLUMES" == "true" ]]; then
        log "Removing volumes..."
        for volume in "$WORKSPACE_VOLUME" "$CLAUDE_HOME_VOLUME" "seq-data"; do
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
        # Build image if needed, then pass -h to Claude Code CLI
        if ! podman image exists "$IMAGE_NAME"; then
            build_image
        else
            log "Using existing image"
        fi
        shift || true  # Remove -h/help argument
        run_mount_mode "$@"
        return
    fi

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

    # Validate --log-api requires --otel
    if [[ "$LOG_API_ENABLED" == "true" ]] && [[ "$OTEL_ENABLED" != "true" ]]; then
        error "--log-api requires --otel (API logs are shipped to Seq)"
    fi

    # Build image if it doesn't exist
    if ! podman image exists "$IMAGE_NAME"; then
        build_image
    else
        log "Using existing image (run 'podman rmi $IMAGE_NAME' to rebuild)"
    fi

    # Start Seq if OTel is enabled
    if [[ "$OTEL_ENABLED" == "true" ]]; then
        start_seq
    fi

    # Start API logger if enabled (after Seq, so logs have somewhere to go)
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
