# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides containerized sandbox environments for running Claude Code and Mistral Vibe CLI in isolated Podman containers. The sandboxes include persistent volumes, OpenTelemetry logging with Seq, API traffic logging, and a web-based file upload server.

## Common Commands

### Running Claude Sandbox
```bash
./claude-sandbox.sh                          # Default: --otel clone mode
./claude-sandbox.sh --otel clone             # With OTel logging to Seq
./claude-sandbox.sh --otel --log-api clone   # With full API traffic logging
./claude-sandbox.sh mount                    # Mount current directory
./claude-sandbox.sh recover                  # Reattach to stopped container
./claude-sandbox.sh build                    # Rebuild Docker image
./claude-sandbox.sh clean --all              # Full cleanup (containers, volumes, images)
```

### Running Vibe Sandbox
```bash
./vibe-sandbox.sh                    # Default: --accept-all clone
./vibe-sandbox.sh mount              # Mount current directory
./vibe-sandbox.sh build              # Rebuild Docker image
```

### Creating Release Tags
```bash
./create-tag.sh 1.0.0                        # Create and push tag
./create-tag.sh v1.2.3 -m "Release message"  # With custom message
./create-tag.sh 1.0.0 --dry-run              # Preview without creating
```

## Architecture

### Two Sandbox Variants

1. **Claude Sandbox** (`claude-sandbox.sh`, `Dockerfile.claude-sandbox`)
   - Runs Claude Code CLI with `--dangerously-skip-permissions` (YOLO mode)
   - Based on .NET SDK 10, includes Node.js 24, Angular CLI, Playwright browsers
   - Runs as non-root `claude` user
   - Services: code-server (port 8443), upload server (port 8888)

2. **Vibe Sandbox** (`vibe-sandbox.sh`, `Dockerfile.vibe-sandbox`)
   - Runs Mistral Vibe CLI with optional `VIBE_ACCEPT_ALL=1`
   - Lighter image without Node.js/Playwright
   - Runs as non-root `vibe` user
   - Service: code-server (port 8444)

### Persistent Volumes (Claude Sandbox)
- `claude-workspace`: Workspace for clone mode (survives container crashes)
- `claude-home`: Entire `/home/claude` directory (configs, plugins, history)
- `seq-data`: Seq logs (when using `--otel` without `--no-persist`)

### API Logging Pipeline
When `--log-api` is enabled:
1. Claude Code sends requests to local proxy (`claude-api-logger` container on port 8800)
2. Proxy forwards to Anthropic API and logs traffic
3. Fluent Bit ships logs to Seq via OTLP

### File Upload Server
- Web UI at `http://localhost:8888`
- Drag & drop files or paste images from clipboard
- Files saved to `~/share` in container (persisted via `claude-home` volume)
- Implementation: `claude-upload-server/server.py`

### Container Communication
- Uses `host.containers.internal` for container-to-host communication
- Podman socket mounted at `/var/run/docker.sock` for Docker CLI compatibility
- GitHub token obtained from `gh` CLI or `GH_TOKEN` environment variable

## Key Implementation Details

- Both entrypoints clone a repo if `REPO_URL` environment variable is set
- Container recovery works by keeping containers after exit (use `--rm` to disable)
- Seq dashboard available at `http://localhost:5341` when OTel is enabled
- The `setup-dev-env.sh` script is for the target project (photos-index), not this repo
