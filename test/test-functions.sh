#!/bin/bash
# Unit tests for sandbox.sh functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASSED=0
FAILED=0

# =============================================================================
# Test Helpers
# =============================================================================

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗${NC} $msg"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

assert_not_empty() {
    local actual="$1"
    local msg="$2"

    if [[ -n "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗${NC} $msg (empty)"
        FAILED=$((FAILED + 1))
    fi
}

# =============================================================================
# Source functions from sandbox.sh
# =============================================================================

# Extract and define functions manually to avoid executing main()
eval "$(sed -n '/^derive_project_name()/,/^}/p' "$SCRIPT_DIR/sandbox.sh")"
eval "$(sed -n '/^detect_repo_type()/,/^}/p' "$SCRIPT_DIR/sandbox.sh")"
eval "$(sed -n '/^set_resource_names()/,/^}/p' "$SCRIPT_DIR/sandbox.sh")"

# Simplified get_project_ports for testing (macOS compatible)
get_project_ports() {
    local project="$1"
    local base="${2:-18443}"

    # Use md5 on macOS, md5sum on Linux
    local hash
    if command -v md5 &>/dev/null; then
        hash=$(echo -n "$project" | md5 -q | cut -c1-4)
    else
        hash=$(echo -n "$project" | md5sum | cut -c1-4)
    fi

    local offset=$(( 16#$hash % 100 ))
    local port_offset=$((offset * 10))

    CODE_SERVER_PORT=$((base + port_offset))
    UPLOAD_PORT=$((base + 445 + port_offset))
    API_LOGGER_PORT=$((base + 357 + port_offset))
}

# =============================================================================
# Tests
# =============================================================================

echo "=== Testing derive_project_name ==="

assert_eq "my-repo" "$(derive_project_name 'https://github.com/user/my-repo.git')" \
    "GitHub URL with .git"

assert_eq "repo" "$(derive_project_name 'https://github.com/user/repo')" \
    "GitHub URL without .git"

assert_eq "repo" "$(derive_project_name 'https://dev.azure.com/org/proj/_git/repo')" \
    "Azure DevOps URL"

assert_eq "myproject" "$(derive_project_name '/path/to/MyProject')" \
    "Local path"

assert_eq "sandbox" "$(derive_project_name '')" \
    "Empty input returns default"

assert_eq "verylongprojectnamet" "$(derive_project_name 'https://github.com/user/VeryLongProjectNameThatExceeds20Chars.git')" \
    "Truncates to 20 chars"

echo ""
echo "=== Testing detect_repo_type ==="

assert_eq "github" "$(detect_repo_type 'https://github.com/user/repo')" \
    "GitHub HTTPS"

assert_eq "github" "$(detect_repo_type 'git@github.com:user/repo.git')" \
    "GitHub SSH"

assert_eq "azuredevops" "$(detect_repo_type 'https://dev.azure.com/org/proj/_git/repo')" \
    "Azure DevOps"

assert_eq "azuredevops" "$(detect_repo_type 'https://org.visualstudio.com/proj/_git/repo')" \
    "Visual Studio Online"

assert_eq "unknown" "$(detect_repo_type 'https://gitlab.com/user/repo')" \
    "GitLab returns unknown"

assert_eq "unknown" "$(detect_repo_type 'https://bitbucket.org/user/repo')" \
    "Bitbucket returns unknown"

echo ""
echo "=== Testing get_project_ports ==="

get_project_ports "testproject" 18443
assert_not_empty "$CODE_SERVER_PORT" "CODE_SERVER_PORT is set"
assert_not_empty "$UPLOAD_PORT" "UPLOAD_PORT is set"
assert_not_empty "$API_LOGGER_PORT" "API_LOGGER_PORT is set"

# Verify ports are in expected range
if [[ $CODE_SERVER_PORT -ge 18443 ]] && [[ $CODE_SERVER_PORT -lt 19443 ]]; then
    echo -e "${GREEN}✓${NC} CODE_SERVER_PORT ($CODE_SERVER_PORT) in expected range"
    ((PASSED++))
else
    echo -e "${RED}✗${NC} CODE_SERVER_PORT ($CODE_SERVER_PORT) out of range"
    ((FAILED++))
fi

echo ""
echo "=== Testing set_resource_names ==="

# Initialize variables used by set_resource_names
CONTAINER_PREFIX="claude-sandbox"
VOLUME_PREFIX="claude"

set_resource_names "myproject"
assert_eq "claude-sandbox-myproject" "$CONTAINER_NAME" "Container name"
assert_eq "claude-workspace-myproject" "$WORKSPACE_VOLUME" "Workspace volume"
assert_eq "claude-home-myproject" "$HOME_VOLUME" "Home volume"

# =============================================================================
# Results
# =============================================================================

echo ""
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
