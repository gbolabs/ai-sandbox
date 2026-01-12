#!/bin/bash
# Development Environment Setup Script
# Installs required dependencies for Photos Index development
#
# Usage:
#   ./setup-dev-env.sh          # Full setup
#   ./setup-dev-env.sh vibe     # Only setup Vibe CLI prompt
#   ./setup-dev-env.sh --help   # Show help

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check OS
OS="$(uname -s)"

show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)    Full development environment setup"
    echo "  vibe      Only install Mistral Vibe CLI prompt"
    echo "  --help    Show this help message"
    echo ""
    exit 0
}

# Handle help early
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
fi

# =============================================================================
# .NET SDK Check/Install
# =============================================================================
check_dotnet() {
    log_info "Checking .NET SDK..."

    if command -v dotnet &> /dev/null; then
        DOTNET_VERSION=$(dotnet --version 2>/dev/null || echo "unknown")
        log_info ".NET SDK found: $DOTNET_VERSION"

        # Check if it's .NET 10+
        if [[ "$DOTNET_VERSION" =~ ^10\. ]] || [[ "$DOTNET_VERSION" =~ ^[1-9][0-9]\. ]]; then
            log_info ".NET SDK version is compatible"
            return 0
        else
            log_warn ".NET 10+ is required, found $DOTNET_VERSION"
        fi
    else
        log_warn ".NET SDK not found"
    fi

    echo ""
    log_error ".NET 10 SDK is required but not installed"
    echo "Please install from: https://dotnet.microsoft.com/download/dotnet/10.0"
    echo ""
    case "$OS" in
        Darwin)
            echo "On macOS with Homebrew:"
            echo "  brew install --cask dotnet-sdk"
            ;;
        Linux)
            echo "On Ubuntu/Debian:"
            echo "  wget https://dot.net/v1/dotnet-install.sh -O - | bash /dev/stdin --channel 10.0"
            ;;
    esac
    return 1
}

# =============================================================================
# Node.js Check/Install via nvm
# =============================================================================
check_nvm() {
    # Load nvm if available
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if command -v nvm &> /dev/null; then
        return 0
    fi
    return 1
}

install_nvm() {
    log_info "Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

    # Load nvm
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

check_node() {
    log_info "Checking Node.js..."

    # Check for nvm
    if ! check_nvm; then
        log_warn "nvm not found, installing..."
        install_nvm

        if ! check_nvm; then
            log_error "Failed to install nvm"
            return 1
        fi
    fi

    log_info "nvm is available"

    # Check for .nvmrc and use it
    if [ -f "$PROJECT_ROOT/src/Web/.nvmrc" ]; then
        REQUIRED_NODE=$(cat "$PROJECT_ROOT/src/Web/.nvmrc" | tr -d '[:space:]')
        log_info "Required Node version from .nvmrc: $REQUIRED_NODE"

        # Install the required version if not present
        if ! nvm ls "$REQUIRED_NODE" &> /dev/null; then
            log_info "Installing Node.js $REQUIRED_NODE..."
            nvm install "$REQUIRED_NODE"
        fi

        # Use the required version
        nvm use "$REQUIRED_NODE"
    else
        # Default to Node 24
        log_info "No .nvmrc found, using Node 24"
        if ! nvm ls 24 &> /dev/null; then
            log_info "Installing Node.js 24..."
            nvm install 24
        fi
        nvm use 24
    fi

    NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")
    log_info "Using Node.js: $NODE_VERSION"

    return 0
}

# =============================================================================
# Angular CLI Check/Install
# =============================================================================
check_angular_cli() {
    log_info "Checking Angular CLI..."

    if command -v ng &> /dev/null; then
        NG_VERSION=$(ng version 2>/dev/null | grep "Angular CLI" | awk '{print $3}' || echo "unknown")
        log_info "Angular CLI found: $NG_VERSION"
        return 0
    fi

    log_info "Installing Angular CLI globally..."
    npm install -g @angular/cli

    if command -v ng &> /dev/null; then
        log_info "Angular CLI installed successfully"
        return 0
    fi

    log_error "Failed to install Angular CLI"
    return 1
}

# =============================================================================
# Project Dependencies
# =============================================================================
install_project_deps() {
    log_info "Installing project dependencies..."

    # Backend dependencies
    log_info "Restoring .NET dependencies..."
    cd "$PROJECT_ROOT"
    dotnet restore src/PhotosIndex.sln

    # Frontend dependencies
    log_info "Installing npm dependencies..."
    cd "$PROJECT_ROOT/src/Web"
    npm install

    cd "$PROJECT_ROOT"
    log_info "All project dependencies installed"
}

# =============================================================================
# Mistral Vibe CLI Setup
# =============================================================================
setup_vibe() {
    log_info "Setting up Mistral Vibe CLI..."

    VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
    VIBE_PROMPTS_DIR="$VIBE_HOME/prompts"

    # Create prompts directory if needed
    if [ ! -d "$VIBE_PROMPTS_DIR" ]; then
        log_info "Creating $VIBE_PROMPTS_DIR..."
        mkdir -p "$VIBE_PROMPTS_DIR"
    fi

    # Copy project prompt if it exists
    if [ -f "$PROJECT_ROOT/.vibe/prompts/photos-index.md" ]; then
        log_info "Installing project prompt to $VIBE_PROMPTS_DIR/photos-index.md..."
        cp "$PROJECT_ROOT/.vibe/prompts/photos-index.md" "$VIBE_PROMPTS_DIR/photos-index.md"
        log_info "Vibe prompt installed successfully"
    else
        log_warn "Project Vibe prompt not found at .vibe/prompts/photos-index.md"
    fi

    # Check if vibe CLI is installed
    if command -v vibe &> /dev/null; then
        VIBE_VERSION=$(vibe --version 2>/dev/null || echo "unknown")
        log_info "Vibe CLI found: $VIBE_VERSION"
    else
        log_warn "Vibe CLI not installed"
        echo "  Install with: pip install mistral-vibe"
        echo "  Or see: https://github.com/mistralai/mistral-vibe"
    fi
}

# =============================================================================
# Container Runtime Check
# =============================================================================
check_container_runtime() {
    log_info "Checking container runtime..."

    if command -v podman &> /dev/null; then
        PODMAN_VERSION=$(podman --version 2>/dev/null | awk '{print $3}' || echo "unknown")
        log_info "Podman found: $PODMAN_VERSION"

        # Check if machine is running (macOS/Windows)
        if [[ "$OS" == "Darwin" ]] || [[ "$OS" =~ MINGW|MSYS|CYGWIN ]]; then
            if podman machine list 2>/dev/null | grep -q "Currently running"; then
                log_info "Podman machine is running"
            else
                log_warn "Podman machine is not running"
                echo "  Start with: podman machine start"
            fi
        fi
        return 0
    fi

    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "unknown")
        log_info "Docker found: $DOCKER_VERSION"
        return 0
    fi

    log_warn "No container runtime found (podman or docker)"
    echo "  Install Podman: https://podman.io/getting-started/installation"
    echo "  Install Docker: https://docs.docker.com/get-docker/"
    return 1
}

# =============================================================================
# Main
# =============================================================================
main() {
    ERRORS=0

    # Check .NET
    if ! check_dotnet; then
        ((ERRORS++))
    fi
    echo ""

    # Check Node.js
    if ! check_node; then
        ((ERRORS++))
    fi
    echo ""

    # Check Angular CLI (only if Node is available)
    if command -v node &> /dev/null; then
        if ! check_angular_cli; then
            ((ERRORS++))
        fi
        echo ""
    fi

    # Check container runtime
    check_container_runtime || true
    echo ""

    # Setup Vibe CLI (optional)
    setup_vibe || true
    echo ""

    # Install project dependencies if all tools are available
    if [ $ERRORS -eq 0 ]; then
        install_project_deps
        echo ""

        echo "========================================"
        echo " Setup Complete!"
        echo "========================================"
        echo ""
        echo "Next steps:"
        echo "  1. Start the full stack:  PHOTOS_PATH=~/Pictures ./deploy/kubernetes/local-dev.sh start"
        echo "  2. Run backend only:      dotnet run --project src/Api/Api.csproj"
        echo "  3. Run frontend only:     cd src/Web && ng serve"
        echo "  4. Run all tests:         dotnet test src/PhotosIndex.sln"
        echo ""
    else
        echo "========================================"
        echo " Setup Incomplete"
        echo "========================================"
        echo ""
        echo "Please install the missing dependencies listed above and run this script again."
        exit 1
    fi
}

# Run based on command
case "${1:-}" in
    vibe)
        setup_vibe
        echo ""
        echo "Vibe CLI setup complete!"
        echo "Run 'vibe' in the project directory to start."
        ;;
    "")
        main
        ;;
esac
