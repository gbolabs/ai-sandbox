# Refactoring Plan: Multi-Project Portable Sandbox

## Summary

Refactor the sandbox scripts to work with any git repo (GitHub/Azure DevOps), support concurrent execution, and reuse host authentication contexts.

## Key Design Decisions

1. **Project naming**: Derive from repo URL or directory name, sanitized (lowercase, alphanumeric, max 20 chars)
2. **Container/volume naming**: Suffix with project name (e.g., `claude-sandbox-myproject`)
3. **Port allocation**: Hash-based offset from project name (avoids conflicts)
4. **Jaeger tracing**: Shared single instance across all containers (UI: 16686, OTLP: 4318)
5. **API logger**: Simplified to JSON file logging (for development reports), per-project
6. **Host context mounts**:
   - `~/.anthropic` → read-write (updatable auth)
   - `~/.claude` → read-only (settings visible, writes go to container volume)
   - `~/.config/gh` → read-only (GitHub CLI auth)
   - `~/.azure` → read-only (Azure CLI auth)

## Files to Modify

### 1. `claude-sandbox.sh` (major changes)

**Add new functions:**
```bash
derive_project_name()     # Extract sanitized name from URL/path
detect_repo_type()        # Returns "github", "azuredevops", or "unknown"
get_repo_url()            # Get URL from arg or git remote
set_resource_names()      # Set container/volume names with project suffix
get_project_ports()       # Calculate ports based on project hash and PORT_BASE
get_host_context_mounts() # Return volume mount args for host configs
get_azdo_auth_args()      # Return Azure DevOps auth env vars
```

**Add new arguments:** `--repo=URL`, `--project=NAME`, `--port-base=XXXXX`

**Modify:**
- Remove hardcoded `REPO_URL="https://github.com/gbolabs/photos-index.git"` (line 158)
- Replace `start_seq()` with `start_jaeger()` - check if already running before starting
- Update OTEL env vars to point to Jaeger: `OTEL_EXPORTER_OTLP_ENDPOINT=http://host.containers.internal:4318`
- Update `start_api_logger()` to use per-project naming
- Update `run_mount_mode()` and `run_clone_mode()` with dynamic ports and host mounts
- Update `run_clean_mode()` for project-specific cleanup with `--clean-shared` option
- Update help text

### 2. `vibe-sandbox.sh` (parallel changes)

Same pattern as claude-sandbox.sh:
- Remove hardcoded `REPO_URL` (line 110)
- Add project derivation and dynamic naming
- Add Azure DevOps support
- Update port allocation

### 3. `Dockerfile.claude-sandbox`

Add mount target directories:
```dockerfile
RUN mkdir -p /home/claude/.config/gh /home/claude/.azure
```

### 4. `entrypoint.sh`

Add:
- Host `.claude` settings merge (copy from `/home/claude/.claude-host` if not present locally)
- Azure DevOps PAT handling for git clone:
```bash
if [[ -n "${AZURE_DEVOPS_PAT:-}" ]] && [[ "$REPO_URL" =~ dev\.azure\.com ]]; then
    REPO_URL=$(echo "$REPO_URL" | sed "s|https://|https://${AZURE_DEVOPS_PAT}@|")
fi
```

### 5. `CLAUDE.md`

Update documentation for new features, remove photos-index references.

### 6. `setup-dev-env.sh`

**Delete** - This is project-specific (photos-index) and doesn't belong in generic sandbox tooling.

## New CLI Interface

```bash
# Examples
./claude-sandbox.sh mount                           # Mount pwd, derive project from dirname
./claude-sandbox.sh clone                           # Clone from git remote, derive project
./claude-sandbox.sh --repo=https://github.com/user/repo.git clone
./claude-sandbox.sh --project=myproj mount          # Explicit project name
./claude-sandbox.sh --port-base=20000 mount         # Custom port range
./claude-sandbox.sh clean --containers              # Clean current project
./claude-sandbox.sh clean --all --clean-shared      # Clean everything including Jaeger
```

## Jaeger Shared Instance Behavior

When multiple containers run concurrently with `--otel`:

1. **First container**: Starts `jaeger` container (jaegertracing/all-in-one)
2. **Subsequent containers**: Detect Jaeger is running → skip start, reuse existing
3. **All containers**: Send OTel traces to `http://host.containers.internal:4318` (OTLP HTTP)
4. **Single dashboard**: All project traces visible at `http://localhost:16686`

```bash
# start_jaeger() logic:
if podman container exists jaeger && state == "running":
    return 0  # Reuse existing
elif exists but stopped:
    podman start jaeger
else:
    podman run -d --name jaeger \
        -p 16686:16686 \  # UI
        -p 4318:4318 \    # OTLP HTTP
        jaegertracing/all-in-one:latest
```

**Cleanup**: `./claude-sandbox.sh clean --clean-shared` stops Jaeger (affects all projects)

## Port Allocation Scheme

Default base ports in 18xxx range (configurable via `--port-base=XXXXX`):

| Service | Default Base | Formula |
|---------|--------------|---------|
| code-server | 18443 | `base + (hash % 100) * 10` |
| upload-server | 18888 | `base + 445 + (hash % 100) * 10` |
| api-logger | 18800 | `base + 357 + (hash % 100) * 10` |
| Jaeger UI (shared) | 16686 | Fixed |
| Jaeger OTLP (shared) | 4318 | Fixed |

Example with `--port-base=20000`:
- code-server: 20000 + offset
- upload-server: 20445 + offset
- api-logger: 20357 + offset

## Implementation Order

1. Add utility functions to claude-sandbox.sh
2. Add new argument parsing (`--repo`, `--project`, `--port-base`)
3. Update resource naming with project suffix
4. Implement port allocation (18xxx range)
5. Replace Seq with Jaeger (`start_jaeger()` with check-before-start)
6. Add host context mounts (~/.anthropic RW, ~/.claude RO, ~/.config/gh RO, ~/.azure RO)
7. Add Azure DevOps auth support (PAT + az CLI)
8. Update entrypoint.sh (settings merge, Azure PAT handling)
9. Apply same changes to vibe-sandbox.sh
10. Update Dockerfile (add mount target directories)
11. Simplify claude-api-logger/ (remove Fluent Bit, log to JSON files)
12. Delete setup-dev-env.sh (project-specific)
13. Update CLAUDE.md

## API Logger Simplification

**Before**: Complex Fluent Bit → Seq pipeline
**After**: Simple Python proxy → JSON files

```
claude-api-logger/
├── Dockerfile          # Simplified, no Fluent Bit
├── server.py           # Python proxy with JSON logging
└── (remove fluent-bit.conf, parsers.conf, entrypoint.sh)
```

**Log format** (saved to `~/api-logs/{project}/`):
```json
{
  "timestamp": "2024-01-12T10:30:00Z",
  "project": "myproject",
  "model": "claude-3-opus",
  "prompt": "User prompt text...",
  "response_preview": "First 500 chars...",
  "input_tokens": 150,
  "output_tokens": 1200,
  "duration_ms": 3500
}
```

**Usage for reports**: Parse JSON files to generate development reports
