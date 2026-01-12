#!/bin/bash
set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <version>

Create and push a new git tag for releases.

Arguments:
    version         Version number (e.g., 1.2.3 or v1.2.3)

Options:
    -h, --help      Show this help message
    -m, --message   Tag message (optional, will prompt if not provided)
    -n, --dry-run   Show what would be done without actually creating the tag
    -f, --force     Force overwrite existing tag

Examples:
    $(basename "$0") 1.0.0
    $(basename "$0") v1.0.0 -m "Release version 1.0.0"
    $(basename "$0") 1.2.3 --dry-run

EOF
    exit 1
}

# Parse command line arguments
DRY_RUN=false
FORCE=false
MESSAGE=""
VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -m|--message)
            MESSAGE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
        *)
            VERSION="$1"
            shift
            ;;
    esac
done

# Validate version argument
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Version number is required${NC}"
    usage
fi

# Normalize version (ensure it starts with 'v')
if [[ ! "$VERSION" =~ ^v ]]; then
    VERSION="v$VERSION"
fi

# Validate semantic version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo -e "${RED}Error: Invalid version format. Expected: v<major>.<minor>.<patch> (e.g., v1.2.3)${NC}"
    exit 1
fi

echo -e "${GREEN}Creating tag: $VERSION${NC}"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: Not in a git repository${NC}"
    exit 1
fi

# Check if there are uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
    read -p "Do you want to continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    if [ "$FORCE" = true ]; then
        echo -e "${YELLOW}Tag $VERSION already exists. Force mode enabled - will overwrite.${NC}"
    else
        echo -e "${RED}Error: Tag $VERSION already exists${NC}"
        echo "Use --force to overwrite the existing tag"
        exit 1
    fi
fi

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $CURRENT_BRANCH"

# Prompt for tag message if not provided
if [ -z "$MESSAGE" ]; then
    read -p "Enter tag message (press Enter for default): " MESSAGE
    if [ -z "$MESSAGE" ]; then
        MESSAGE="Release $VERSION"
    fi
fi

# Show what will be done
echo ""
echo "Tag Summary:"
echo "  Version: $VERSION"
echo "  Message: $MESSAGE"
echo "  Branch:  $CURRENT_BRANCH"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] Would create and push tag $VERSION${NC}"
    exit 0
fi

# Confirm before proceeding
read -p "Create and push this tag? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Create the tag
echo -e "${GREEN}Creating tag...${NC}"
if [ "$FORCE" = true ]; then
    git tag -a "$VERSION" -m "$MESSAGE" -f
else
    git tag -a "$VERSION" -m "$MESSAGE"
fi

# Push the tag
echo -e "${GREEN}Pushing tag to remote...${NC}"
if [ "$FORCE" = true ]; then
    git push origin "$VERSION" --force
else
    git push origin "$VERSION"
fi

echo ""
echo -e "${GREEN}✓ Successfully created and pushed tag $VERSION${NC}"
echo ""
echo "The release pipeline should now be triggered automatically."
echo "Monitor the progress at: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/actions"
