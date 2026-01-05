#!/bin/bash
#
# PR Log Sync - Sync GitHub PRs and code reviews to Obsidian markdown files
# https://github.com/tyler-james-bridges/pr-log-sync
#
# Generates monthly PR log files for tracking your contributions and code reviews.
# Run with --help for usage information.

set -euo pipefail

# Configuration (override via environment variables)
YEAR=$(date +%Y)
VAULT_PATH="${VAULT_PATH:-$HOME/Documents/Obsidian Vault/$YEAR/Work/PR Log}"
GITHUB_ORG="${GITHUB_ORG:-}"
# Security: Create temp directory with verification
TEMP_DIR=$(mktemp -d -t pr-log-sync.XXXXXXXXXX) || { echo "Error: Failed to create temp directory"; exit 1; }

# Verify temp directory is in expected location (macOS uses /var/folders, Linux uses /tmp)
if [[ ! "$TEMP_DIR" =~ ^/tmp/ ]] && [[ ! "$TEMP_DIR" =~ ^/var/folders/ ]]; then
    echo "Error: Temporary directory created in unexpected location: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Dependency checks
check_dependencies() {
    local missing=()
    command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI)")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required dependencies:"
        printf '  - %s\n' "${missing[@]}"
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        echo "Error: GitHub CLI not authenticated. Run: gh auth login"
        exit 1
    fi
}

check_dependencies

# Security: Validate GitHub organization name (alphanumeric, hyphens, underscores only)
validate_github_org() {
    local org="$1"
    if [[ ! "$org" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Invalid GitHub organization name '$org'. Only alphanumeric characters, hyphens, and underscores are allowed."
        exit 1
    fi
    if [[ ${#org} -gt 39 ]]; then
        echo "Error: GitHub organization name too long (max 39 characters)"
        exit 1
    fi
}

# Security: Validate vault path to prevent path traversal attacks
validate_vault_path() {
    local path="$1"

    # Resolve to absolute path
    local resolved_path
    if [[ "$OSTYPE" == darwin* ]]; then
        # macOS: Use python as fallback if realpath not available
        resolved_path=$(cd "$path" 2>/dev/null && pwd -P || python3 -c "import os; print(os.path.realpath('$path'))" 2>/dev/null || echo "$path")
    else
        resolved_path=$(realpath -m "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || echo "$path")
    fi

    # Check for symlink at the path itself
    if [[ -L "$path" ]]; then
        echo "Error: Vault path cannot be a symbolic link: $path"
        exit 1
    fi

    # Ensure path is under user's home directory
    if [[ ! "$resolved_path" =~ ^"$HOME" ]]; then
        echo "Error: Vault path must be within your home directory for security"
        echo "  Provided: $path"
        echo "  Resolved: $resolved_path"
        echo "  Home: $HOME"
        exit 1
    fi

    # Return the resolved path
    echo "$resolved_path"
}

# Security: Sanitize strings for safe use in shell and markdown
# Removes/escapes characters that could cause command injection
sanitize_string() {
    local input="$1"
    # Remove null bytes, escape backticks, dollar signs, and backslashes
    # These are the primary shell injection vectors
    printf '%s' "$input" | tr -d '\0' | sed 's/[`$\\]/\\&/g'
}

# Security: Sanitize strings for markdown table cells
# Escapes pipe characters and removes dangerous content
sanitize_for_markdown() {
    local input="$1"
    # First sanitize for shell safety, then escape markdown pipes
    local sanitized
    sanitized=$(sanitize_string "$input")
    # Escape pipe characters for markdown tables, remove newlines
    printf '%s' "$sanitized" | tr -d '\n\r' | sed 's/|/\\|/g'
}

# Security: Check if a path is a symlink (TOCTOU protection)
reject_if_symlink() {
    local path="$1"
    if [[ -L "$path" ]]; then
        echo "Error: Refusing to operate on symbolic link: $path"
        exit 1
    fi
}

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Date helper for cross-platform compatibility
get_date_days_ago() {
    local days=$1
    if [[ "$OSTYPE" == darwin* ]]; then
        date -v-${days}d +%Y-%m-%d
    else
        date -d "${days} days ago" +%Y-%m-%d
    fi
}

validate_date() {
    local date_str="$1"

    # Check format first (strict regex)
    if [[ ! "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: Invalid date format '$date_str'. Use YYYY-MM-DD"
        exit 1
    fi

    # Security: Verify it's an actual valid calendar date (not just well-formatted)
    # This prevents potential issues with date command processing
    if [[ "$OSTYPE" == darwin* ]]; then
        if ! date -j -f "%Y-%m-%d" "$date_str" "+%Y-%m-%d" >/dev/null 2>&1; then
            echo "Error: Invalid date '$date_str'. Please use a valid calendar date."
            exit 1
        fi
    else
        if ! date -d "$date_str" "+%Y-%m-%d" >/dev/null 2>&1; then
            echo "Error: Invalid date '$date_str'. Please use a valid calendar date."
            exit 1
        fi
    fi
}

# Default date range (last 7 days)
FROM_DATE=$(get_date_days_ago 7)
TO_DATE=$(date +%Y-%m-%d)
DRY_RUN=false

# Cleanup on exit (with security verification)
cleanup() {
    # Security: Only delete if TEMP_DIR looks like a temp directory we created
    if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]] && \
       [[ "$TEMP_DIR" =~ ^(/tmp/|/var/folders/).*pr-log-sync\. ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --org)
            GITHUB_ORG="$2"
            shift 2
            ;;
        --vault)
            VAULT_PATH="$2"
            shift 2
            ;;
        --from)
            FROM_DATE="$2"
            validate_date "$FROM_DATE"
            shift 2
            ;;
        --to)
            TO_DATE="$2"
            validate_date "$TO_DATE"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            cat << 'HELP'
Usage: pr-log-sync.sh --org ORGANIZATION [OPTIONS]

Fetches your GitHub PRs and code reviews, then updates Obsidian markdown files.

Required:
  --org ORG        GitHub organization name (or set GITHUB_ORG env var)

Options:
  --vault PATH     Obsidian vault PR Log path (default: ~/Documents/Obsidian Vault/YEAR/PR Log)
  --from DATE      Start date in YYYY-MM-DD format (default: 7 days ago)
  --to DATE        End date in YYYY-MM-DD format (default: today)
  --dry-run        Preview changes without writing files
  -h, --help       Show this help message

Environment variables:
  GITHUB_ORG       GitHub organization (alternative to --org)
  VAULT_PATH       Override default vault path

Examples:
  pr-log-sync.sh --org mycompany
  pr-log-sync.sh --org mycompany --from 2024-01-01 --to 2024-01-31
  GITHUB_ORG=mycompany pr-log-sync.sh --dry-run
HELP
            exit 0
            ;;
        *)
            echo "Unknown option: $1. Use --help for usage."
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$GITHUB_ORG" ]; then
    echo "Error: GitHub organization required. Use --org or set GITHUB_ORG env var."
    echo "Run with --help for usage information."
    exit 1
fi

# Security: Validate GitHub organization name
validate_github_org "$GITHUB_ORG"

# Validate and secure vault path
if [ ! -d "$VAULT_PATH" ]; then
    echo "Warning: Vault path does not exist: $VAULT_PATH"
    echo "Creating directory..."
    mkdir -p "$VAULT_PATH" || { echo "Error: Failed to create vault path"; exit 1; }
fi

# Security: Validate vault path is safe (under $HOME, not a symlink)
VAULT_PATH=$(validate_vault_path "$VAULT_PATH")

echo -e "${BLUE}PR Log Sync${NC}"
echo -e "Date range: ${GREEN}$FROM_DATE${NC} to ${GREEN}$TO_DATE${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN - no files will be modified${NC}"
fi
echo ""

# Get month file name from date
get_month_file() {
    local date="$1"
    local month_num=$(date -j -f "%Y-%m-%d" "$date" "+%m" 2>/dev/null || date -d "$date" "+%m")
    local month_name=$(date -j -f "%Y-%m-%d" "$date" "+%B" 2>/dev/null || date -d "$date" "+%B")
    echo "${month_num}-${month_name}.md"
}

# Check if URL already exists in file (with security checks)
url_exists_in_file() {
    local file="$1"
    local url="$2"

    # Security: Reject symlinks (TOCTOU protection)
    if [[ -L "$file" ]]; then
        echo "Error: Refusing to operate on symbolic link: $file" >&2
        exit 1
    fi

    if [[ -f "$file" ]]; then
        # Security: Use -F for fixed string matching (prevents regex injection)
        grep -qF "$url" "$file" && return 0
    fi
    return 1
}

# ============================================
# FETCH AUTHORED PRs
# ============================================
echo -e "${BLUE}Fetching your PRs...${NC}"

# Fetch merged PRs using GitHub API search
MERGED_PRS=$(gh api search/issues \
    --method GET \
    -f q="author:@me org:$GITHUB_ORG is:pr is:merged merged:${FROM_DATE}..${TO_DATE}" \
    -f per_page=100 \
    --jq '.items[] | {
        repo: (.repository_url | split("/") | .[-1]),
        title: .title,
        url: .pull_request.html_url,
        date: (.closed_at | split("T")[0]),
        status: "merged"
    }' 2>/dev/null || echo "")

# Fetch closed (not merged) PRs
CLOSED_PRS=$(gh api search/issues \
    --method GET \
    -f q="author:@me org:$GITHUB_ORG is:pr is:closed is:unmerged closed:${FROM_DATE}..${TO_DATE}" \
    -f per_page=100 \
    --jq '.items[] | {
        repo: (.repository_url | split("/") | .[-1]),
        title: .title,
        url: .pull_request.html_url,
        date: (.closed_at | split("T")[0]),
        status: "closed"
    }' 2>/dev/null || echo "")

# Combine PRs
ALL_PRS="${MERGED_PRS}
${CLOSED_PRS}"

# Count PRs (grep -c returns 1 when no matches, so use || true)
MERGED_COUNT=$(echo "$MERGED_PRS" | grep -c '"status": "merged"' || true)
CLOSED_COUNT=$(echo "$CLOSED_PRS" | grep -c '"status": "closed"' || true)
: "${MERGED_COUNT:=0}"
: "${CLOSED_COUNT:=0}"

echo -e "  Found ${GREEN}$MERGED_COUNT merged${NC} and ${YELLOW}$CLOSED_COUNT closed${NC} PRs"

# ============================================
# FETCH CODE REVIEWS
# ============================================
echo -e "${BLUE}Fetching your code reviews...${NC}"

# Fetch PRs reviewed by user (not authored by them)
REVIEWED_PRS=$(gh api search/issues \
    --method GET \
    -f q="reviewed-by:@me org:$GITHUB_ORG is:pr is:merged -author:@me merged:${FROM_DATE}..${TO_DATE}" \
    -f per_page=100 \
    --jq '.items[] | {
        repo: (.repository_url | split("/") | .[-1]),
        title: .title,
        url: .pull_request.html_url,
        date: (.closed_at | split("T")[0]),
        author: .user.login
    }' 2>/dev/null || echo "")

REVIEW_COUNT=$(echo "$REVIEWED_PRS" | grep -c '"repo"' || true)
: "${REVIEW_COUNT:=0}"
echo -e "  Found ${CYAN}$REVIEW_COUNT code reviews${NC}"

echo ""

# ============================================
# PROCESS AUTHORED PRs
# ============================================
echo -e "${BLUE}Processing your PRs...${NC}"

while read -r pr_json; do
    [ -z "$pr_json" ] && continue

    repo=$(echo "$pr_json" | jq -r '.repo')
    title=$(echo "$pr_json" | jq -r '.title')
    url=$(echo "$pr_json" | jq -r '.url')
    date=$(echo "$pr_json" | jq -r '.date')
    status=$(echo "$pr_json" | jq -r '.status')

    [ -z "$repo" ] || [ "$repo" = "null" ] && continue

    # Security: Sanitize all user-controlled content from GitHub API
    repo=$(sanitize_for_markdown "$repo")
    title=$(sanitize_for_markdown "$title")
    # URL should only contain safe characters, but sanitize anyway
    url=$(sanitize_string "$url")

    month_file=$(get_month_file "$date")
    full_path="$VAULT_PATH/$month_file"

    # Skip if already exists
    if url_exists_in_file "$full_path" "$url"; then
        printf '%b  Skipping (exists):%b %s\n' "${YELLOW}" "${NC}" "$title"
        continue
    fi

    # Build table row (using printf for safety)
    pr_row="| $date | $repo | [$title]($url) | $status |"

    if [ "$status" = "merged" ]; then
        printf '%b  + %s:%b %s\n' "${GREEN}" "$repo" "${NC}" "$title"
    else
        printf '%b  + %s:%b %s (closed)\n' "${RED}" "$repo" "${NC}" "$title"
    fi

    # Write to temp files (grouped by month)
    printf '%s\n' "$pr_row" >> "$TEMP_DIR/${month_file}.prs"
done <<< "$ALL_PRS"

# ============================================
# PROCESS CODE REVIEWS
# ============================================
echo ""
echo -e "${BLUE}Processing code reviews...${NC}"

while read -r pr_json; do
    [ -z "$pr_json" ] && continue

    repo=$(echo "$pr_json" | jq -r '.repo')
    title=$(echo "$pr_json" | jq -r '.title')
    url=$(echo "$pr_json" | jq -r '.url')
    date=$(echo "$pr_json" | jq -r '.date')
    author=$(echo "$pr_json" | jq -r '.author')

    [ -z "$repo" ] || [ "$repo" = "null" ] && continue

    # Security: Sanitize all user-controlled content from GitHub API
    repo=$(sanitize_for_markdown "$repo")
    title=$(sanitize_for_markdown "$title")
    url=$(sanitize_string "$url")
    author=$(sanitize_for_markdown "$author")

    month_file=$(get_month_file "$date")
    full_path="$VAULT_PATH/$month_file"

    # Skip if already exists
    if url_exists_in_file "$full_path" "$url"; then
        printf '%b  Skipping (exists):%b %s\n' "${YELLOW}" "${NC}" "$title"
        continue
    fi

    # Build table row for reviews (using printf for safety)
    review_row="| $date | $repo | [$title]($url) | @$author |"

    printf '%b  + reviewed %s:%b %s (by @%s)\n' "${CYAN}" "$repo" "${NC}" "$title" "$author"

    # Write to temp files (grouped by month)
    printf '%s\n' "$review_row" >> "$TEMP_DIR/${month_file}.reviews"
done <<< "$REVIEWED_PRS"

echo ""

# ============================================
# APPLY CHANGES
# ============================================

# Check if any changes to make
PR_FILES=$(find "$TEMP_DIR" -name "*.prs" 2>/dev/null | wc -l | tr -d ' ')
REVIEW_FILES=$(find "$TEMP_DIR" -name "*.reviews" 2>/dev/null | wc -l | tr -d ' ')

if [ "$PR_FILES" = "0" ] && [ "$REVIEW_FILES" = "0" ]; then
    echo -e "${YELLOW}No new PRs or reviews to add${NC}"
    exit 0
fi

# Apply changes to files
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN - Changes that would be made:${NC}"

    # Show PR changes
    for pr_file in "$TEMP_DIR"/*.prs; do
        [ -f "$pr_file" ] || continue
        month_file=$(basename "$pr_file" .prs)
        echo -e "\n${BLUE}$month_file - PRs:${NC}"
        cat "$pr_file"
    done

    # Show review changes
    for review_file in "$TEMP_DIR"/*.reviews; do
        [ -f "$review_file" ] || continue
        month_file=$(basename "$review_file" .reviews)
        echo -e "\n${CYAN}$month_file - Reviews:${NC}"
        cat "$review_file"
    done
else
    # Get all unique months that need updates
    ALL_MONTHS=$(ls "$TEMP_DIR"/*.prs "$TEMP_DIR"/*.reviews 2>/dev/null | xargs -n1 basename | sed 's/\.prs$//' | sed 's/\.reviews$//' | sort -u)

    for month_file in $ALL_MONTHS; do
        full_path="$VAULT_PATH/$month_file"

        # Security: Check for symlink attacks before any file operations
        if [[ -e "$full_path" ]] && [[ -L "$full_path" ]]; then
            echo "Error: Refusing to operate on symbolic link: $full_path" >&2
            exit 1
        fi

        # Create new file if needed
        if [ ! -f "$full_path" ]; then
            echo -e "${YELLOW}Creating new file:${NC} $month_file"
            month_name=$(echo "$month_file" | sed 's/[0-9]*-//' | sed 's/.md//')
            cat > "$full_path" << EOF
[[PR Log]]

# $month_name $YEAR - PR Log

## Summary

| Metric | Value |
|--------|-------|
| **Total PRs** | 0 |
| **Merged** | 0 |
| **Closed** | 0 |
| **Reviews** | 0 |
| **Repos** | TBD |

## Themes
<!-- TODO: Add themes based on PRs -->

## PRs

| Date | Repo | Title | Status |
|------|------|-------|--------|

## Code Reviews

| Date | Repo | Title | Author |
|------|------|-------|--------|

## Related Project Notes
EOF
        fi

        # Ensure Code Reviews section exists
        # Security: Use -qF for fixed string matching (prevents regex injection)
        if ! grep -qF "## Code Reviews" "$full_path"; then
            # Insert Code Reviews section before Related Project Notes
            if grep -qF "## Related Project Notes" "$full_path"; then
                line_num=$(grep -nF "## Related Project Notes" "$full_path" | head -1 | cut -d: -f1)
                # Security: Validate line number
                if [[ "$line_num" =~ ^[0-9]+$ ]] && [ "$line_num" -ge 1 ]; then
                    head -n $((line_num - 1)) "$full_path" > "${full_path}.tmp"
                    echo "" >> "${full_path}.tmp"
                    echo "## Code Reviews" >> "${full_path}.tmp"
                    echo "" >> "${full_path}.tmp"
                    echo "| Date | Repo | Title | Author |" >> "${full_path}.tmp"
                    echo "|------|------|-------|--------|" >> "${full_path}.tmp"
                    echo "" >> "${full_path}.tmp"
                    tail -n +$line_num "$full_path" >> "${full_path}.tmp"
                    mv "${full_path}.tmp" "$full_path"
                fi
            fi
        fi

        # Insert PRs if we have any for this month
        pr_file="$TEMP_DIR/${month_file}.prs"
        if [ -f "$pr_file" ]; then
            if grep -qF "## Code Reviews" "$full_path"; then
                line_num=$(grep -nF "## Code Reviews" "$full_path" | head -1 | cut -d: -f1)
                # Security: Validate line number
                if [[ "$line_num" =~ ^[0-9]+$ ]] && [ "$line_num" -ge 1 ]; then
                    head -n $((line_num - 1)) "$full_path" > "${full_path}.tmp"
                    cat "$pr_file" >> "${full_path}.tmp"
                    echo "" >> "${full_path}.tmp"
                    tail -n +$line_num "$full_path" >> "${full_path}.tmp"
                    mv "${full_path}.tmp" "$full_path"
                fi
            elif grep -qF "## Related Project Notes" "$full_path"; then
                line_num=$(grep -nF "## Related Project Notes" "$full_path" | head -1 | cut -d: -f1)
                # Security: Validate line number
                if [[ "$line_num" =~ ^[0-9]+$ ]] && [ "$line_num" -ge 1 ]; then
                    head -n $((line_num - 1)) "$full_path" > "${full_path}.tmp"
                    cat "$pr_file" >> "${full_path}.tmp"
                    echo "" >> "${full_path}.tmp"
                    tail -n +$line_num "$full_path" >> "${full_path}.tmp"
                    mv "${full_path}.tmp" "$full_path"
                fi
            fi
        fi

        # Insert reviews if we have any for this month
        review_file="$TEMP_DIR/${month_file}.reviews"
        if [ -f "$review_file" ]; then
            if grep -qF "## Related Project Notes" "$full_path"; then
                line_num=$(grep -nF "## Related Project Notes" "$full_path" | head -1 | cut -d: -f1)
                # Security: Validate line number
                if [[ "$line_num" =~ ^[0-9]+$ ]] && [ "$line_num" -ge 1 ]; then
                    head -n $((line_num - 1)) "$full_path" > "${full_path}.tmp"
                    cat "$review_file" >> "${full_path}.tmp"
                    echo "" >> "${full_path}.tmp"
                    tail -n +$line_num "$full_path" >> "${full_path}.tmp"
                    mv "${full_path}.tmp" "$full_path"
                fi
            fi
        fi

        echo -e "${GREEN}Updated:${NC} $month_file"
    done
fi

echo ""
echo -e "${GREEN}Done!${NC}"
