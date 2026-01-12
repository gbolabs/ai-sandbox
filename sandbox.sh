#!/bin/bash
# =============================================================================
# AI Sandbox - Containerized Development Environment for AI Coding Assistants
# =============================================================================
#
# Multi-project portable sandbox supporting:
#   - Claude Code (Anthropic)
#   - Vibe CLI (Mistral AI)
#   - GitHub Copilot CLI (planned)
#
# Features:
#   - Any git repository (GitHub, Azure DevOps)
#   - Concurrent container execution (one per project)
#   - Host context mounting (reuse existing auth)
#   - Jaeger tracing for observability
#
# Usage:
#   ./sandbox.sh mount                         # Mount current dir (default: Claude)
#   ./sandbox.sh --cli=vibe mount              # Use Vibe CLI
#   ./sandbox.sh --repo=URL clone              # Clone specific repo
#   ./sandbox.sh --help                        # Show full help

set -euo pipefail

# Allow sourcing for testing (--source-only)
if [[ "${1:-}" == "--source-only" ]]; then
    # Export functions for testing, skip execution
    set +euo pipefail
    return 0 2>/dev/null || exit 0
fi

# =============================================================================
# Help and Usage
# =============================================================================

show_help() {
    cat << 'EOF'
AI Sandbox - Containerized Development Environment for AI Coding Assistants

Usage:
  ./sandbox.sh [options] <mode>
  ./sandbox.sh                              # Default: mount with Claude Code
  ./sandbox.sh --cli=vibe mount             # Use Vibe CLI instead

Supported AI CLIs:
  claude       Claude Code by Anthropic (default)
  vibe         Vibe CLI by Mistral AI
  copilot      GitHub Copilot CLI (gh copilot)

Modes:
  mount        Mount current directory (default)
  clone        Clone repository into persistent volume
  recover      Restart and attach to stopped container
  clean        Remove containers/volumes/images
  build        Rebuild the Docker image
  docs [path]  Start documentation server for /docs (or custom path)

CLI Selection:
  --cli=NAME           AI CLI to use: claude, vibe, copilot [default: claude]

Project Options:
  --repo=URL           Repository URL (GitHub or Azure DevOps)
  --project=NAME       Project name for container/volume naming (auto-derived)
  --branch=BRANCH      Branch to checkout in clone mode [default: main]

Port Options:
  --port-base=PORT     Base port for services [default: 18443]

Observability:
  --otel               Enable OpenTelemetry tracing with Jaeger
  --log-api            Enable API traffic logging to JSON files

Container Options:
  --rm                 Remove container on exit (disables 'recover')
  --skip-scope-check   Skip GitHub token scope validation
  -h, --help           Show this help message

Authentication:
  Claude Code and Vibe CLI use OAuth authentication (not API keys).
  Run the CLI on your host first to authenticate, then the container
  will reuse your auth context from ~/.claude or ~/.vibe.

Environment Variables:
  GH_TOKEN             GitHub token for private repos and Copilot
  AZURE_DEVOPS_PAT     Azure DevOps personal access token

Examples:
  # Mount current directory with Claude Code
  ./sandbox.sh mount

  # Use Vibe CLI instead
  ./sandbox.sh --cli=vibe mount

  # Use GitHub Copilot CLI
  ./sandbox.sh --cli=copilot mount

  # Clone a GitHub repository with Claude
  ./sandbox.sh --repo=https://github.com/user/repo.git clone

  # Clone Azure DevOps repo with Vibe
  ./sandbox.sh --cli=vibe --repo=https://dev.azure.com/org/project/_git/repo clone

  # With Jaeger tracing
  ./sandbox.sh --otel mount

  # Custom port range (for running multiple instances)
  ./sandbox.sh --port-base=20000 mount

  # Recover crashed container
  ./sandbox.sh recover

  # Clean up
  ./sandbox.sh clean --all

  # Start documentation server
  ./sandbox.sh docs
  ./sandbox.sh docs my-docs    # Custom path
  DOCS_PORT=4000 ./sandbox.sh docs

Clean mode options:
  --containers         Remove project containers
  --volumes            Remove project volumes
  --images             Remove images
  --clean-shared       Also remove shared Jaeger container
  --all                Remove everything for current project
EOF
}

# =============================================================================
# Default Configuration
# =============================================================================

CLI_TYPE="claude"                # claude, vibe, copilot
OTEL_ENABLED=false
LOG_API_ENABLED=false
SKIP_SCOPE_CHECK=false
BRANCH="main"
KEEP_CONTAINER=true
CLEAN_IMAGES=false
CLEAN_VOLUMES=false
CLEAN_CONTAINERS=false
CLEAN_SHARED=false
REPO_URL=""
PROJECT_NAME=""
PORT_BASE=18443

# Vibe-specific
ACCEPT_ALL_MODE=true

# Shared resources
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
# CLI-Specific Configuration
# =============================================================================

set_cli_config() {
    case "$CLI_TYPE" in
        claude)
            IMAGE_NAME="ai-sandbox-claude:latest"
            DOCKERFILE="Dockerfile.claude-sandbox"
            CONTAINER_PREFIX="claude-sandbox"
            VOLUME_PREFIX="claude"
            USER_NAME="claude"
            ;;
        vibe)
            IMAGE_NAME="ai-sandbox-vibe:latest"
            DOCKERFILE="Dockerfile.vibe-sandbox"
            CONTAINER_PREFIX="vibe-sandbox"
            VOLUME_PREFIX="vibe"
            USER_NAME="vibe"
            ;;
        copilot)
            IMAGE_NAME="ai-sandbox-copilot:latest"
            DOCKERFILE="Dockerfile.copilot-sandbox"
            CONTAINER_PREFIX="copilot-sandbox"
            VOLUME_PREFIX="copilot"
            USER_NAME="copilot"
            ;;
        *)
            error "Unknown CLI type: $CLI_TYPE (use: claude, vibe, copilot)"
            ;;
    esac

    API_LOGGER_IMAGE="ai-sandbox-api-logger:latest"
}

# =============================================================================
# Argument Parsing
# =============================================================================

POSITIONAL_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --cli=*)
            CLI_TYPE="${arg#*=}"
            ;;
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
        --accept-all)
            ACCEPT_ALL_MODE=true
            ;;
        --no-accept-all)
            ACCEPT_ALL_MODE=false
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
# Utility Functions
# =============================================================================

derive_project_name() {
    local source="$1"
    local name=""

    if [[ "$source" =~ ^https?:// ]] || [[ "$source" =~ ^git@ ]]; then
        name=$(echo "$source" | sed -E 's/.*[\/:]([^\/]+)(\.git)?$/\1/' | sed 's/\.git$//')
    else
        name=$(basename "$source")
    fi

    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-20)
    name=$(echo "$name" | sed 's/^-*//;s/-*$//')

    echo "${name:-sandbox}"
}

detect_repo_type() {
    local url="$1"

    if [[ "$url" =~ github\.com ]] || [[ "$url" =~ ^git@github\.com ]]; then
        echo "github"
    elif [[ "$url" =~ dev\.azure\.com ]] || [[ "$url" =~ visualstudio\.com ]]; then
        echo "azuredevops"
    else
        echo "unknown"
    fi
}

get_git_remote_url() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git remote get-url origin 2>/dev/null || echo ""
    else
        echo ""
    fi
}

set_resource_names() {
    local project="$1"

    CONTAINER_NAME="${CONTAINER_PREFIX}-${project}"
    WORKSPACE_VOLUME="${VOLUME_PREFIX}-workspace-${project}"
    HOME_VOLUME="${VOLUME_PREFIX}-home-${project}"
    API_LOGGER_CONTAINER="api-logger-${project}"
}

get_project_ports() {
    local project="$1"
    local base="${PORT_BASE:-18443}"

    local hash=$(echo -n "$project" | md5 -q 2>/dev/null || echo -n "$project" | md5sum | cut -c1-4)
    hash=$(echo "$hash" | cut -c1-4)
    local offset=$(( 16#$hash % 100 ))
    local port_offset=$((offset * 10))

    CODE_SERVER_PORT=$((base + port_offset))
    UPLOAD_PORT=$((base + 445 + port_offset))
    API_LOGGER_PORT=$((base + 357 + port_offset))
    DOCS_PORT=$((base + 557 + port_offset))
}

get_host_context_mounts() {
    local mounts=""

    # CLI-specific auth context (OAuth tokens, not API keys)
    case "$CLI_TYPE" in
        claude)
            # Claude Code stores OAuth tokens in ~/.claude
            if [[ -d "$HOME/.claude" ]]; then
                mounts+="-v $HOME/.claude:/home/claude/.claude:ro "
                log "Mounting Claude auth context from ~/.claude"
            fi
            ;;
        vibe)
            # Vibe CLI stores OAuth tokens in ~/.vibe
            if [[ -d "$HOME/.vibe" ]]; then
                mounts+="-v $HOME/.vibe:/home/vibe/.vibe:ro "
                log "Mounting Vibe auth context from ~/.vibe"
            fi
            ;;
        copilot)
            # Copilot uses gh CLI config - mounted below as common
            ;;
    esac

    # Common mounts (read-only)
    if [[ -d "$HOME/.config/gh" ]]; then
        mounts+="-v $HOME/.config/gh:/home/${USER_NAME}/.config/gh:ro "
    fi
    if [[ -d "$HOME/.azure" ]]; then
        mounts+="-v $HOME/.azure:/home/${USER_NAME}/.azure:ro "
    fi

    echo "$mounts"
}

get_azdo_auth_args() {
    local repo_type="$1"

    if [[ "$repo_type" == "azuredevops" ]] && [[ -n "${AZURE_DEVOPS_PAT:-}" ]]; then
        echo "-e AZURE_DEVOPS_PAT=${AZURE_DEVOPS_PAT} "
    fi
}

get_cli_env_args() {
    local env_args=""

    case "$CLI_TYPE" in
        claude)
            # Claude doesn't need special env vars
            ;;
        vibe)
            if [[ "$ACCEPT_ALL_MODE" == "true" ]]; then
                env_args+="-e VIBE_ACCEPT_ALL=1 "
            fi
            if [[ -n "${VIBE_MODEL:-}" ]]; then
                env_args+="-e VIBE_MODEL=${VIBE_MODEL} "
            fi
            ;;
    esac

    echo "$env_args"
}

# =============================================================================
# Jaeger (Shared OTel Backend)
# =============================================================================

start_jaeger() {
    log "Checking Jaeger status..."

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

    podman run -d \
        --name "$JAEGER_CONTAINER" \
        -p ${JAEGER_UI_PORT}:16686 \
        -p ${JAEGER_OTLP_PORT}:4318 \
        jaegertracing/all-in-one:latest

    log "Jaeger UI: http://localhost:${JAEGER_UI_PORT}"
}

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

# =============================================================================
# API Logger
# =============================================================================

build_api_logger_image() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local logger_dir="$script_dir/api-logger"

    if [[ ! -d "$logger_dir" ]]; then
        error "API logger directory not found: $logger_dir"
    fi

    log "Building API logger image..."
    podman build -t "$API_LOGGER_IMAGE" "$logger_dir"
}

start_api_logger() {
    log "Starting API traffic logger..."

    podman rm -f "$API_LOGGER_CONTAINER" 2>/dev/null || true

    if ! podman image exists "$API_LOGGER_IMAGE"; then
        build_api_logger_image
    fi

    podman run -d --rm \
        --name "$API_LOGGER_CONTAINER" \
        -p ${API_LOGGER_PORT}:8000 \
        -e PROJECT_NAME="${PROJECT_NAME}" \
        -v "${HOME_VOLUME}:/data:Z" \
        "$API_LOGGER_IMAGE"

    log "API Logger Proxy: http://localhost:${API_LOGGER_PORT}"
}

get_api_logger_env_args() {
    if [[ "$LOG_API_ENABLED" == "true" ]]; then
        echo "-e ANTHROPIC_BASE_URL=http://host.containers.internal:${API_LOGGER_PORT}"
    fi
}

# =============================================================================
# GitHub Token
# =============================================================================

check_token_scopes() {
    local scopes
    scopes=$(gh auth status 2>&1 | grep "Token scopes:" | sed "s/.*Token scopes: //" || echo "")

    if [[ -z "$scopes" ]]; then
        warn "Could not determine token scopes"
        return 1
    fi

    if [[ "$scopes" != *"workflow"* ]]; then
        warn "Token missing 'workflow' scope"
        return 1
    fi

    return 0
}

get_gh_token() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        log "Using GH_TOKEN from environment"
        return 0
    fi

    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        if [[ "$SKIP_SCOPE_CHECK" != "true" ]] && ! check_token_scopes; then
            warn "Token missing required scopes. Refreshing..."
            gh auth refresh -h github.com -s workflow
        fi

        GH_TOKEN=$(gh auth token)
        export GH_TOKEN
        log "GitHub token obtained from gh CLI"
        return 0
    fi

    warn "GitHub token not available"
    read -p "Continue without GitHub token? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# =============================================================================
# Prerequisites and Build
# =============================================================================

check_prereqs() {
    log "Checking prerequisites..."

    command -v podman >/dev/null 2>&1 || error "Podman is not installed"

    # Check auth context for selected CLI (OAuth-based, not API keys)
    case "$CLI_TYPE" in
        claude)
            if [[ ! -d "$HOME/.claude" ]]; then
                warn "No Claude auth context found (~/.claude)"
                warn "Run 'claude' on host first to authenticate"
            fi
            ;;
        vibe)
            if [[ ! -d "$HOME/.vibe" ]]; then
                warn "No Vibe auth context found (~/.vibe)"
                warn "Run 'vibe' on host first to authenticate"
            fi
            ;;
        copilot)
            # Copilot needs gh auth, checked via get_gh_token
            ;;
    esac

    get_gh_token

    log "Prerequisites OK"
}

build_image() {
    log "Building container image for $CLI_TYPE..."

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local dockerfile="$script_dir/$DOCKERFILE"

    if [[ ! -f "$dockerfile" ]]; then
        error "Dockerfile not found: $dockerfile"
    fi

    podman build -t "$IMAGE_NAME" -f "$dockerfile" "$script_dir"

    log "Image built successfully: $IMAGE_NAME"
}

# =============================================================================
# Run Modes
# =============================================================================

run_mount_mode() {
    log "Running in MOUNT mode ($CLI_TYPE)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"

    local git_name=$(git config user.name 2>/dev/null || echo "AI Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "agent@localhost")

    local otel_args=""
    [[ "$OTEL_ENABLED" == "true" ]] && otel_args=$(get_otel_env_args)

    local api_logger_args=""
    [[ "$LOG_API_ENABLED" == "true" ]] && api_logger_args=$(get_api_logger_env_args)

    local host_mounts=$(get_host_context_mounts)
    local repo_type=$(detect_repo_type "${REPO_URL:-}")
    local azdo_args=$(get_azdo_auth_args "$repo_type")
    local cli_env_args=$(get_cli_env_args)

    local rm_flag=""
    [[ "$KEEP_CONTAINER" == "false" ]] && rm_flag="--rm"

    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

    if ! podman volume exists "$HOME_VOLUME"; then
        podman volume create "$HOME_VOLUME"
    fi

    log "Ports: code-server=$CODE_SERVER_PORT, upload=$UPLOAD_PORT, docs=$DOCS_PORT"

    local podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"

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
        -p ${DOCS_PORT}:3000 \
        -v "$(pwd):/workspace:Z" \
        -v "$HOME_VOLUME:/home/${USER_NAME}:Z" \
        -v "$podman_socket:/var/run/docker.sock:Z" \
        $host_mounts \
        $otel_args \
        $api_logger_args \
        $azdo_args \
        $cli_env_args \
        "$IMAGE_NAME" \
        "$@"
}

run_clone_mode() {
    log "Running in CLONE mode ($CLI_TYPE)"
    log "Project: $PROJECT_NAME"
    log "Container: $CONTAINER_NAME"
    log "Repository: $REPO_URL"

    local git_name=$(git config user.name 2>/dev/null || echo "AI Agent")
    local git_email=$(git config user.email 2>/dev/null || echo "agent@localhost")

    local otel_args=""
    [[ "$OTEL_ENABLED" == "true" ]] && otel_args=$(get_otel_env_args)

    local api_logger_args=""
    [[ "$LOG_API_ENABLED" == "true" ]] && api_logger_args=$(get_api_logger_env_args)

    local host_mounts=$(get_host_context_mounts)
    local repo_type=$(detect_repo_type "$REPO_URL")
    local azdo_args=$(get_azdo_auth_args "$repo_type")
    local cli_env_args=$(get_cli_env_args)

    local rm_flag=""
    [[ "$KEEP_CONTAINER" == "false" ]] && rm_flag="--rm"

    for vol in "$WORKSPACE_VOLUME" "$HOME_VOLUME"; do
        if ! podman volume exists "$vol"; then
            podman volume create "$vol"
        fi
    done

    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

    log "Ports: code-server=$CODE_SERVER_PORT, upload=$UPLOAD_PORT, docs=$DOCS_PORT"

    local podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"

    # shellcheck disable=SC2086
    podman run -it $rm_flag \
        --name "$CONTAINER_NAME" \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e GIT_AUTHOR_NAME="$git_name" \
        -e GIT_AUTHOR_EMAIL="$git_email" \
        -e GIT_COMMITTER_NAME="$git_name" \
        -e GIT_COMMITTER_EMAIL="$git_email" \
        -e REPO_URL="$REPO_URL" \
        -e BRANCH="$BRANCH" \
        -e DOCKER_HOST="unix:///var/run/docker.sock" \
        -e PROJECT_NAME="$PROJECT_NAME" \
        -p ${CODE_SERVER_PORT}:8443 \
        -p ${UPLOAD_PORT}:8888 \
        -p ${DOCS_PORT}:3000 \
        -v "$WORKSPACE_VOLUME:/workspace:Z" \
        -v "$HOME_VOLUME:/home/${USER_NAME}:Z" \
        -v "$podman_socket:/var/run/docker.sock:Z" \
        $host_mounts \
        $otel_args \
        $api_logger_args \
        $azdo_args \
        $cli_env_args \
        "$IMAGE_NAME" \
        "$@"
}

run_recover_mode() {
    log "Recovering container: $CONTAINER_NAME"

    if ! podman container exists "$CONTAINER_NAME"; then
        error "No container named '$CONTAINER_NAME' found"
    fi

    local state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)

    case "$state" in
        running)
            log "Container is running, attaching..."
            podman attach "$CONTAINER_NAME"
            ;;
        exited|stopped|created)
            log "Container state: $state. Starting..."

            # Restart support containers
            for container in "$JAEGER_CONTAINER" "$API_LOGGER_CONTAINER"; do
                if podman container exists "$container" 2>/dev/null; then
                    local cs=$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
                    [[ "$cs" != "running" ]] && podman start "$container" 2>/dev/null || true
                fi
            done

            podman start -ai "$CONTAINER_NAME"
            ;;
        *)
            error "Container in unexpected state: $state"
            ;;
    esac
}

run_clean_mode() {
    log "Cleaning project: $PROJECT_NAME ($CLI_TYPE)"

    if [[ "$CLEAN_CONTAINERS" == "false" ]] && [[ "$CLEAN_VOLUMES" == "false" ]] && [[ "$CLEAN_IMAGES" == "false" ]]; then
        error "Specify: --containers, --volumes, --images, or --all"
    fi

    if [[ "$CLEAN_CONTAINERS" == "true" ]]; then
        for c in "$CONTAINER_NAME" "$API_LOGGER_CONTAINER"; do
            podman rm -f "$c" 2>/dev/null && log "Removed container: $c" || true
        done

        if [[ "$CLEAN_SHARED" == "true" ]]; then
            podman rm -f "$JAEGER_CONTAINER" 2>/dev/null && log "Removed Jaeger" || true
        fi
    fi

    if [[ "$CLEAN_VOLUMES" == "true" ]]; then
        for v in "$WORKSPACE_VOLUME" "$HOME_VOLUME"; do
            podman volume rm "$v" 2>/dev/null && log "Removed volume: $v" || true
        done
    fi

    if [[ "$CLEAN_IMAGES" == "true" ]]; then
        for i in "$IMAGE_NAME" "$API_LOGGER_IMAGE"; do
            podman rmi "$i" 2>/dev/null && log "Removed image: $i" || true
        done
    fi

    log "Cleanup complete"
}

# =============================================================================
# Documentation Server Mode
# =============================================================================

run_docs_mode() {
    local docs_path="${1:-docs}"
    local docs_port="${DOCS_PORT:-3000}"
    local docify_image="ai-sandbox-docify:latest"

    # Create docs folder with basic README if it doesn't exist
    if [[ ! -d "$docs_path" ]]; then
        log "Creating $docs_path directory with default README..."
        mkdir -p "$docs_path"
        cat > "$docs_path/README.md" << 'DOCEOF'
# Documentation

Welcome to your documentation!

Edit this file or add more markdown files to build your docs.

## Features

- Live reload on file changes
- GitHub-flavored markdown
- Sidebar navigation (add `_sidebar.md`)

## Getting Started

1. Edit `README.md`
2. Add more `.md` files
3. Create `_sidebar.md` for navigation
DOCEOF
    fi

    # Build docify image if needed
    if ! podman image exists "$docify_image" 2>/dev/null; then
        log "Building docify image..."
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        podman build -t "$docify_image" -f "$script_dir/Dockerfile.docify" "$script_dir"
    fi

    log "Starting documentation server..."
    log "URL: http://localhost:$docs_port"
    log "Serving: $(pwd)/$docs_path"
    log "Press Ctrl+C to stop"
    echo ""

    podman run -it --rm \
        --name "docify-$(basename "$(pwd)")" \
        -p "${docs_port}:3000" \
        -v "$(pwd)/${docs_path}:/workspace/docs:Z" \
        "$docify_image"
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Initialize CLI configuration
    set_cli_config

    # Determine project name
    if [[ -z "$PROJECT_NAME" ]]; then
        if [[ "$MODE" == "clone" ]]; then
            [[ -z "$REPO_URL" ]] && REPO_URL=$(get_git_remote_url)
            [[ -z "$REPO_URL" ]] && error "Clone mode requires --repo=URL or git remote"
            PROJECT_NAME=$(derive_project_name "$REPO_URL")
        else
            PROJECT_NAME=$(derive_project_name "$(pwd)")
        fi
    fi

    # Set resource names and ports
    set_resource_names "$PROJECT_NAME"
    get_project_ports "$PROJECT_NAME"

    # Handle modes
    case "$MODE" in
        docs)
            shift || true
            run_docs_mode "$@"
            exit 0
            ;;
        clean)
            run_clean_mode
            ;;
        build)
            build_image
            ;;
        mount|clone|recover)
            check_prereqs

            if ! podman image exists "$IMAGE_NAME"; then
                build_image
            else
                log "Using existing image: $IMAGE_NAME"
            fi

            [[ "$OTEL_ENABLED" == "true" ]] && start_jaeger
            [[ "$LOG_API_ENABLED" == "true" ]] && start_api_logger

            shift || true

            case "$MODE" in
                mount) run_mount_mode "$@" ;;
                clone) run_clone_mode "$@" ;;
                recover) run_recover_mode ;;
            esac
            ;;
        *)
            error "Unknown mode: $MODE (use: mount, clone, recover, clean, build, docs)"
            ;;
    esac
}

main "$@"
