#!/bin/bash
# Init script for Vibe sandbox - runs as the vibe user
# Installs uv and vibe CLI in the user's home directory

set -euo pipefail

# Colors
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }

# Global PATH variable
UV_BIN="$HOME/.local/bin"
UV_TOOLS="$HOME/.local/share/uv/tools"

# Install uv in user space
install_uv() {
    log "Installing uv (Python package installer)..."
    
    if command -v uv &> /dev/null; then
        log "uv already installed"
        return 0
    fi
    
    # Install uv using the official installer
    curl -LsSf https://astral.sh/uv/install.sh | sh
    
    # Add uv to PATH if not already there
    if [[ ":$PATH:" != *":$UV_BIN:"* ]]; then
        PATH="$UV_BIN:$PATH"
        echo "export PATH=\"$UV_BIN:\$PATH\"" >> "$HOME/.bashrc"
    fi
    
    # Verify installation
    if command -v uv &> /dev/null; then
        UV_VERSION=$(uv --version 2>/dev/null || echo "unknown")
        log "uv installed successfully: $UV_VERSION"
        return 0
    fi
    
    echo "ERROR: Failed to install uv"
    return 1
}

# Install Mistral Vibe CLI
install_vibe() {
    log "Installing Mistral Vibe CLI..."
    
    if command -v vibe &> /dev/null; then
        log "Vibe CLI already installed"
        return 0
    fi
    
    # Install vibe using uv
    uv tool install mistral-vibe
    
    # Add uv tools to PATH if not already there
    if [[ ":$PATH:" != *":$UV_TOOLS:"* ]]; then
        PATH="$UV_TOOLS:$PATH"
        echo "export PATH=\"$UV_TOOLS:\$PATH\"" >> "$HOME/.bashrc"
    fi
    
    # Verify installation
    if command -v vibe &> /dev/null; then
        VIBE_VERSION=$(vibe --version 2>/dev/null || echo "unknown")
        log "Vibe CLI installed successfully: $VIBE_VERSION"
        return 0
    fi
    
    echo "ERROR: Failed to install Vibe CLI"
    return 1
}

# Main installation
main() {
    log "Starting Vibe sandbox initialization..."
    
    # Install uv first
    if ! install_uv; then
        echo "ERROR: uv installation failed"
        exit 1
    fi
    
    # Install vibe
    if ! install_vibe; then
        echo "ERROR: Vibe CLI installation failed"
        exit 1
    fi
    
    # Export PATH to make it available to the calling shell
    export PATH
    
    log "Vibe sandbox initialization complete!"
}

# Run as the current user
main
