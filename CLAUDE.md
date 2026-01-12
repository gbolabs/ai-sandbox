# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides containerized sandbox environments for running Claude Code and Mistral Vibe CLI in isolated Podman containers. The sandboxes support **multi-project portability** - work with any GitHub or Azure DevOps repository, run concurrent containers for different projects, and reuse host authentication contexts.

## Quick Start

### Claude Sandbox
```bash
# Mount current directory (project name derived from dirname)
./claude-sandbox.sh mount

# Clone a GitHub repository
./claude-sandbox.sh --repo=https://github.com/user/repo.git clone

# Clone an Azure DevOps repository
./claude-sandbox.sh --repo=https://dev.azure.com/org/project/_git/repo clone

# With OpenTelemetry tracing (traces to Jaeger)
./claude-sandbox.sh --otel mount

# With API traffic logging (for development reports)
./claude-sandbox.sh --otel --log-api mount

# Custom project name and port base
./claude-sandbox.sh --project=myproj --port-base=20000 mount
```

### Vibe Sandbox
```bash
# Mount current directory
./vibe-sandbox.sh mount

# Clone a repository
./vibe-sandbox.sh --repo=https://github.com/user/repo.git clone
```

### Management Commands
```bash
./claude-sandbox.sh recover                  # Reattach to stopped container
./claude-sandbox.sh build                    # Rebuild Docker image
./claude-sandbox.sh clean                    # Clean current project resources
./claude-sandbox.sh clean --clean-shared     # Also clean Jaeger and shared resources
```

## Architecture

### Multi-Project Support

- **Project naming**: Automatically derived from repo URL or directory name (sanitized, max 20 chars)
- **Container naming**: Suffixed with project name (e.g., `claude-sandbox-myproject`)
- **Volume naming**: Per-project volumes (e.g., `claude-workspace-myproject`)
- **Port allocation**: Hash-based offset from project name in 18xxx range to avoid conflicts

### Two Sandbox Variants

1. **Claude Sandbox** (`claude-sandbox.sh`, `Dockerfile.claude-sandbox`)
   - Runs Claude Code CLI with `--dangerously-skip-permissions` (YOLO mode)
   - Based on .NET SDK 10, includes Node.js 24, Angular CLI, Playwright browsers
   - Runs as non-root `claude` user

2. **Vibe Sandbox** (`vibe-sandbox.sh`, `Dockerfile.vibe-sandbox`)
   - Runs Mistral Vibe CLI with optional `VIBE_ACCEPT_ALL=1`
   - Lighter image, runs as non-root `vibe` user

### Port Allocation (18xxx range)

| Service | Default Base | Formula |
|---------|--------------|---------|
| code-server | 18443 | base + (hash % 100) * 10 |
| upload-server | 18888 | base + 445 + offset |
| api-logger | 18800 | base + 357 + offset |
| Jaeger UI (shared) | 16686 | Fixed |
| Jaeger OTLP (shared) | 4318 | Fixed |

### Host Context Mounts

The sandboxes can reuse authentication from your host machine:
- `~/.anthropic` → Read-write (updatable auth)
- `~/.claude` → Read-only (settings visible, writes to container volume)
- `~/.config/gh` → Read-only (GitHub CLI auth)
- `~/.azure` → Read-only (Azure CLI auth)

### OpenTelemetry Tracing

When `--otel` is enabled:
- **Jaeger** runs as shared container (single instance across all projects)
- Dashboard at `http://localhost:16686`
- All project traces visible in one UI

### API Traffic Logging

When `--log-api` is enabled:
- Simple HTTP proxy logs requests/responses to JSON files
- Logs saved to `~/api-logs/{project}/` in container
- Format: JSONL files per day (for generating development reports)
- Implementation: `claude-api-logger/server.py`

### File Upload Server
- Web UI at dynamic port (shown at startup)
- Drag & drop files or paste images from clipboard
- Files saved to `~/share` in container
- Implementation: `claude-upload-server/server.py`

## Environment Variables

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key (required for Claude) |
| `MISTRAL_API_KEY` | Mistral API key (required for Vibe) |
| `GH_TOKEN` | GitHub token for private repos |
| `AZURE_DEVOPS_PAT` | Azure DevOps personal access token |

## Key Implementation Details

- Project name automatically derived from repo URL or current directory
- Container recovery via `recover` mode (keeps containers after exit)
- Azure DevOps PAT injected into clone URL when detected
- Host `.claude` settings merged on startup (copy if not present locally)
- Concurrent containers supported via unique naming and port allocation
