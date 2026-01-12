# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**AI Sandbox** - Containerized development environments for AI coding assistants.

Supported AI CLIs:
- **Claude Code** (Anthropic) - Default
- **Vibe CLI** (Mistral AI)
- **GitHub Copilot CLI** (planned)

Features:
- Multi-project support with concurrent containers
- Any git repository (GitHub, Azure DevOps)
- Host context mounting (reuse existing auth)
- OpenTelemetry tracing with Jaeger

## Quick Start

```bash
# Mount current directory with Claude Code (default)
./sandbox.sh mount

# Use Vibe CLI instead
./sandbox.sh --cli=vibe mount

# Clone a GitHub repository
./sandbox.sh --repo=https://github.com/user/repo.git clone

# Clone an Azure DevOps repository
./sandbox.sh --repo=https://dev.azure.com/org/project/_git/repo clone

# With OpenTelemetry tracing
./sandbox.sh --otel mount

# With API traffic logging
./sandbox.sh --otel --log-api mount

# Custom project name and port base
./sandbox.sh --project=myproj --port-base=20000 mount
```

### Management Commands
```bash
./sandbox.sh recover                  # Reattach to stopped container
./sandbox.sh build                    # Rebuild Docker image
./sandbox.sh clean --containers       # Clean project containers
./sandbox.sh clean --all              # Full project cleanup
./sandbox.sh clean --all --clean-shared  # Include shared Jaeger
```

## Architecture

### Multi-Project Support

- **Project naming**: Auto-derived from repo URL or directory name (sanitized, max 20 chars)
- **Container naming**: `{cli}-sandbox-{project}` (e.g., `claude-sandbox-myproject`)
- **Volume naming**: `{cli}-{workspace|home}-{project}`
- **Port allocation**: Hash-based offset in 18xxx range to avoid conflicts

### Port Allocation

| Service | Default Base | Formula |
|---------|--------------|---------|
| code-server | 18443 | base + (hash % 100) * 10 |
| upload-server | 18888 | base + 445 + offset |
| api-logger | 18800 | base + 357 + offset |
| Jaeger UI (shared) | 16686 | Fixed |
| Jaeger OTLP (shared) | 4318 | Fixed |

### Host Context Mounts

Authentication is reused from your host machine:
- `~/.anthropic` → Read-write (Claude API credentials)
- `~/.claude` → Read-only (Claude settings)
- `~/.vibe` → Read-write (Vibe settings, when using --cli=vibe)
- `~/.config/gh` → Read-only (GitHub CLI auth)
- `~/.azure` → Read-only (Azure CLI auth)

### OpenTelemetry Tracing

When `--otel` is enabled:
- **Jaeger** runs as shared container (single instance across all projects)
- Dashboard at `http://localhost:16686`
- All project traces visible in one UI

### API Traffic Logging

When `--log-api` is enabled:
- HTTP proxy logs requests/responses to JSON files
- Logs saved to `~/api-logs/{project}/` in container
- Format: JSONL files per day (for development reports)

### File Upload Server
- Web UI at dynamic port (shown at startup)
- Drag & drop files or paste images from clipboard
- Files saved to `~/share` in container

## Environment Variables

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | For Claude Code |
| `MISTRAL_API_KEY` | For Vibe CLI |
| `GH_TOKEN` | GitHub token for private repos |
| `AZURE_DEVOPS_PAT` | Azure DevOps personal access token |

## File Structure

```
.
├── sandbox.sh              # Unified launcher script
├── Dockerfile.claude-sandbox  # Claude Code container
├── Dockerfile.vibe-sandbox    # Vibe CLI container
├── entrypoint.sh           # Container entrypoint
├── api-logger/             # API traffic logging proxy
│   ├── Dockerfile
│   └── server.py
├── claude-upload-server/   # File upload server
│   └── server.py
└── docs/
    └── REFACTORING-PLAN.md
```

## Key Implementation Details

- Project name automatically derived from repo URL or directory
- Container recovery via `recover` mode
- Azure DevOps PAT injected into clone URL when detected
- Host settings merged on startup
- Concurrent containers via unique naming and port allocation
