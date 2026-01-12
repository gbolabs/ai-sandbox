# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**AI Sandbox** - Containerized development environments for AI coding assistants.

Supported AI CLIs:
- **Claude Code** (Anthropic) - Default
- **Vibe CLI** (Mistral AI)
- **GitHub Copilot CLI** (gh copilot)

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

# Use GitHub Copilot CLI
./sandbox.sh --cli=copilot mount

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

### Documentation Server
```bash
./sandbox.sh docs                     # Serve ./docs on http://localhost:3000
./sandbox.sh docs my-folder           # Serve custom folder
DOCS_PORT=4000 ./sandbox.sh docs      # Custom port
```

### Markdown to PDF (in Claude container)
```bash
# Inside container:
md2pdf README.md                      # Creates README.pdf
pandoc doc.md -o doc.pdf --pdf-engine=weasyprint  # Direct usage
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

Authentication is reused from your host machine (read-only):
- `~/.claude` → Claude Code OAuth tokens
- `~/.vibe` → Vibe CLI OAuth tokens
- `~/.config/gh` → GitHub CLI auth (for Copilot and git operations)
- `~/.azure` → Azure CLI auth (for Azure DevOps)

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

## Authentication

Claude Code and Vibe CLI use **OAuth authentication** (not API keys). The container reuses your host's auth context:

| CLI | Auth Directory | How to Authenticate |
|-----|----------------|---------------------|
| Claude Code | `~/.claude` | Run `claude` on host first |
| Vibe CLI | `~/.vibe` | Run `vibe` on host first |
| GitHub Copilot | `~/.config/gh` | Run `gh auth login` on host |

The auth directories are mounted read-only into the container.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GH_TOKEN` | GitHub token for private repos and Copilot |
| `AZURE_DEVOPS_PAT` | Azure DevOps personal access token |

## Development Environment

All containers are **full development environments**, not just CLI wrappers:
- **.NET 10 SDK** - Standard runtime
- **Node.js 24** - JavaScript/TypeScript support
- **Angular CLI** - Frontend development
- **code-server** - VS Code in browser
- **Git, vim, jq** - Essential tools
- **Pandoc + WeasyPrint** - MD to PDF with Unicode/emoji support (Claude container)
- **Noto fonts** - Full emoji and CJK character rendering

## File Structure

```
.
├── sandbox.sh                  # Unified launcher script
├── Dockerfile.claude-sandbox   # Claude Code container (with md2pdf)
├── Dockerfile.vibe-sandbox     # Vibe CLI container
├── Dockerfile.copilot-sandbox  # GitHub Copilot CLI container
├── Dockerfile.docify           # Lightweight docs server (docsify)
├── entrypoint.sh               # Unified entrypoint (all CLIs)
├── api-logger/                 # API traffic logging proxy
│   ├── Dockerfile
│   └── server.py
├── upload-server/              # File upload server
│   └── server.py
├── test/
│   └── test-functions.sh       # Unit tests for sandbox.sh
└── .github/
    └── workflows/
        └── ci.yml              # CI pipeline (ShellCheck, tests, builds)
```

## Key Implementation Details

- Project name automatically derived from repo URL or directory
- Container recovery via `recover` mode
- Azure DevOps PAT injected into clone URL when detected
- Host settings merged on startup
- Concurrent containers via unique naming and port allocation
- Unified entrypoint detects CLI type via `$CLI_TYPE` or username

## CI/CD

GitHub Actions CI runs on every push/PR:
- **ShellCheck** - Lint all shell scripts
- **Unit tests** - Test `sandbox.sh` utility functions
- **Docker builds** - Build all CLI images + docify (matrix)
- **Entrypoint tests** - Verify services start in container

Run tests locally:
```bash
./test/test-functions.sh
```
