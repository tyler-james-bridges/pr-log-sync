#!/bin/bash
#
# PR Log Sync - Sync GitHub PRs and code reviews to Obsidian markdown files
# https://github.com/tyler-james-bridges/pr-log-sync
#
# Generates monthly PR log files for tracking your contributions and code reviews.
# Run with --help for usage information.

set -euo pipefail

# Configuration
YEAR=$(date +%Y)
VAULT_PATH="${VAULT_PATH:-$HOME/Documents/Obsidian Vault/$YEAR/Work/PR Log}"
GITHUB_ORG="${GITHUB_ORG:-}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Check dependencies
command -v gh >/dev/null 2>&1 || { echo "Error: gh (GitHub CLI) required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq required"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: GitHub CLI not authenticated. Run: gh auth login"; exit 1; }

# Cross-platform date helper
date_days_ago() {
    local days=$1
    date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "${days} days ago" +%Y-%m-%d
}

# Get month file name from date
get_month_file() {
    local d="$1"
    local month_num month_name
    month_num=$(date -j -f "%Y-%m-%d" "$d" "+%m" 2>/dev/null || date -d "$d" "+%m")
    month_name=$(date -j -f "%Y-%m-%d" "$d" "+%B" 2>/dev/null || date -d "$d" "+%B")
    echo "${month_num}-${month_name}.md"
}

# Escape pipes for markdown tables
escape_markdown() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's/|/\\|/g'
}

# Default date range
FROM_DATE=$(date_days_ago 7)
TO_DATE=$(date +%Y-%m-%d)
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --org) GITHUB_ORG="$2"; shift 2 ;;
        --vault) VAULT_PATH="$2"; shift 2 ;;
        --from) FROM_DATE="$2"; shift 2 ;;
        --to) TO_DATE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            cat << 'HELP'
Usage: pr-log-sync.sh --org ORGANIZATION [OPTIONS]

Fetches your GitHub PRs and code reviews, then updates Obsidian markdown files.

Required:
  --org ORG        GitHub organization name (or set GITHUB_ORG env var)

Options:
  --vault PATH     Obsidian vault PR Log path (default: ~/Documents/Obsidian Vault/YEAR/Work/PR Log)
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
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

# Validate required parameters
if [[ -z "$GITHUB_ORG" ]]; then
    echo "Error: GitHub organization required. Use --org or set GITHUB_ORG env var."
    exit 1
fi

# Ensure vault path exists
mkdir -p "$VAULT_PATH"

echo "PR Log Sync"
echo "Date range: $FROM_DATE to $TO_DATE"
[[ "$DRY_RUN" = true ]] && echo "DRY RUN - no files will be modified"
echo ""

# Fetch merged PRs
echo "Fetching your PRs..."
MERGED_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --merged --merged-at="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), status: "merged"}' 2>/dev/null || echo "")

# Fetch closed (not merged) PRs
CLOSED_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --state=closed --closed="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt,state \
    --jq '.[] | select(.state != "merged") | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), status: "closed"}' 2>/dev/null || echo "")

ALL_PRS="${MERGED_PRS}
${CLOSED_PRS}"

merged_count=$(echo "$MERGED_PRS" | grep -c '"status"' || true)
closed_count=$(echo "$CLOSED_PRS" | grep -c '"status"' || true)
echo "  Found $merged_count merged and $closed_count closed PRs"

# Fetch code reviews (PRs you reviewed but didn't author)
echo "Fetching your code reviews..."
REVIEWED_PRS=$(gh search prs --reviewed-by=@me --owner="$GITHUB_ORG" --merged --merged-at="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt,author \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), author: .author.login}' 2>/dev/null || echo "")

# Filter out PRs authored by self
MY_LOGIN=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [[ -n "$MY_LOGIN" ]]; then
    REVIEWED_PRS=$(echo "$REVIEWED_PRS" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        author=$(echo "$line" | jq -r '.author // empty')
        [[ "$author" != "$MY_LOGIN" ]] && echo "$line"
    done)
fi

review_count=$(echo "$REVIEWED_PRS" | grep -c '"repo"' || true)
echo "  Found $review_count code reviews"
echo ""

# Process authored PRs
echo "Processing your PRs..."
while IFS= read -r pr_json; do
    [[ -z "$pr_json" || "$pr_json" != "{"* ]] && continue

    repo=$(echo "$pr_json" | jq -r '.repo')
    title=$(echo "$pr_json" | jq -r '.title')
    url=$(echo "$pr_json" | jq -r '.url')
    date=$(echo "$pr_json" | jq -r '.date')
    status=$(echo "$pr_json" | jq -r '.status')

    [[ -z "$repo" || "$repo" = "null" ]] && continue

    month_file=$(get_month_file "$date")
    full_path="$VAULT_PATH/$month_file"

    # Skip if URL already exists in file
    [[ -f "$full_path" ]] && grep -qF "$url" "$full_path" && { echo "  Skipping (exists): $title"; continue; }

    title=$(escape_markdown "$title")
    pr_row="| $date | $repo | [$title]($url) | $status |"
    echo "  + $repo: $title"
    echo "$pr_row" >> "$TEMP_DIR/${month_file}.prs"
done <<< "$ALL_PRS"

# Process code reviews
echo ""
echo "Processing code reviews..."
while IFS= read -r pr_json; do
    [[ -z "$pr_json" || "$pr_json" != "{"* ]] && continue

    repo=$(echo "$pr_json" | jq -r '.repo')
    title=$(echo "$pr_json" | jq -r '.title')
    url=$(echo "$pr_json" | jq -r '.url')
    date=$(echo "$pr_json" | jq -r '.date')
    author=$(echo "$pr_json" | jq -r '.author')

    [[ -z "$repo" || "$repo" = "null" ]] && continue

    month_file=$(get_month_file "$date")
    full_path="$VAULT_PATH/$month_file"

    # Skip if URL already exists in file
    [[ -f "$full_path" ]] && grep -qF "$url" "$full_path" && { echo "  Skipping (exists): $title"; continue; }

    title=$(escape_markdown "$title")
    review_row="| $date | $repo | [$title]($url) | @$author |"
    echo "  + reviewed $repo: $title (by @$author)"
    echo "$review_row" >> "$TEMP_DIR/${month_file}.reviews"
done <<< "$REVIEWED_PRS"

echo ""

# Check if any changes to make
shopt -s nullglob
pr_files=("$TEMP_DIR"/*.prs)
review_files=("$TEMP_DIR"/*.reviews)
shopt -u nullglob

if [[ ${#pr_files[@]} -eq 0 && ${#review_files[@]} -eq 0 ]]; then
    echo "No new PRs or reviews to add"
    exit 0
fi

# Create file template
create_month_file() {
    local path="$1"
    local month_name="$2"
    cat > "$path" << EOF
[[PR Log]]

# $month_name $YEAR - PR Log

## Summary

| Metric | Value |
|--------|-------|
| **Total PRs** | 0 |
| **Merged** | 0 |
| **Closed** | 0 |
| **Reviews** | 0 |

## PRs

| Date | Repo | Title | Status |
|------|------|-------|--------|

## Code Reviews

| Date | Repo | Title | Author |
|------|------|-------|--------|

## Related Project Notes
EOF
}

# Insert rows before a section marker
insert_before_section() {
    local file="$1"
    local section="$2"
    local content="$3"

    if grep -qF "$section" "$file"; then
        local line_num
        line_num=$(grep -nF "$section" "$file" | head -1 | cut -d: -f1)
        head -n $((line_num - 1)) "$file" > "${file}.tmp"
        echo "$content" >> "${file}.tmp"
        tail -n +"$line_num" "$file" >> "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

if [[ "$DRY_RUN" = true ]]; then
    echo "DRY RUN - Changes that would be made:"
    for pr_file in "$TEMP_DIR"/*.prs; do
        [[ -f "$pr_file" ]] || continue
        echo ""
        echo "$(basename "$pr_file" .prs) - PRs:"
        cat "$pr_file"
    done
    for review_file in "$TEMP_DIR"/*.reviews; do
        [[ -f "$review_file" ]] || continue
        echo ""
        echo "$(basename "$review_file" .reviews) - Reviews:"
        cat "$review_file"
    done
else
    # Get unique months
    months=$(ls "$TEMP_DIR"/*.prs "$TEMP_DIR"/*.reviews 2>/dev/null | xargs -n1 basename | sed 's/\.\(prs\|reviews\)$//' | sort -u)

    for month_file in $months; do
        full_path="$VAULT_PATH/$month_file"

        # Create file if needed
        if [[ ! -f "$full_path" ]]; then
            month_name=$(echo "$month_file" | sed 's/[0-9]*-//' | sed 's/.md//')
            echo "Creating: $month_file"
            create_month_file "$full_path" "$month_name"
        fi

        # Insert PRs before Code Reviews section
        if [[ -f "$TEMP_DIR/${month_file}.prs" ]]; then
            insert_before_section "$full_path" "## Code Reviews" "$(cat "$TEMP_DIR/${month_file}.prs")"
        fi

        # Insert reviews before Related Project Notes section
        if [[ -f "$TEMP_DIR/${month_file}.reviews" ]]; then
            insert_before_section "$full_path" "## Related Project Notes" "$(cat "$TEMP_DIR/${month_file}.reviews")"
        fi

        echo "Updated: $month_file"
    done
fi

echo ""
echo "Done!"
