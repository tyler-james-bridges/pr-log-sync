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

# Cross-platform sed in-place edit
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
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

# Fetch open PRs (created within date range)
OPEN_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --state=open --created="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,createdAt \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.createdAt | split("T")[0]), status: "open"}' 2>/dev/null || echo "")

# Fetch PR updates (PRs updated in date range but created before it - to track ongoing work)
UPDATED_PRS_RAW=$(gh search prs --author=@me --owner="$GITHUB_ORG" --state=open --updated="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,updatedAt,createdAt \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.updatedAt | split("T")[0]), created: (.createdAt | split("T")[0])}' 2>/dev/null || echo "")

# Filter out PRs created within the date range (those are already captured as new PRs)
UPDATED_PRS=$(echo "$UPDATED_PRS_RAW" | while IFS= read -r line; do
    [[ -z "$line" || "$line" != "{"* ]] && continue
    created=$(echo "$line" | jq -r '.created // empty')
    # Only include if created before the FROM_DATE
    if [[ -n "$created" && "$created" < "$FROM_DATE" ]]; then
        echo "$line"
    fi
done)

ALL_PRS="${MERGED_PRS}
${CLOSED_PRS}
${OPEN_PRS}"

merged_count=$(echo "$MERGED_PRS" | grep -c '"status"' || true)
closed_count=$(echo "$CLOSED_PRS" | grep -c '"status"' || true)
open_count=$(echo "$OPEN_PRS" | grep -c '"status"' || true)
updated_count=$(echo "$UPDATED_PRS" | grep -c '"repo"' || true)
echo "  Found $merged_count merged, $closed_count closed, $open_count open PRs, and $updated_count PR updates"

# Fetch code reviews (PRs you reviewed but didn't author)
echo "Fetching your code reviews..."
REVIEWED_PRS=$(gh search prs --reviewed-by=@me --owner="$GITHUB_ORG" --merged --merged-at="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt,author \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), author: .author.login}' 2>/dev/null || echo "")

# Fetch pending reviews (open PRs you reviewed but didn't author, updated in date range)
PENDING_REVIEWS_RAW=$(gh search prs --reviewed-by=@me --owner="$GITHUB_ORG" --state=open --updated="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,updatedAt,author \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.updatedAt | split("T")[0]), author: .author.login}' 2>/dev/null || echo "")

# Filter out PRs authored by self
MY_LOGIN=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [[ -n "$MY_LOGIN" ]]; then
    REVIEWED_PRS=$(echo "$REVIEWED_PRS" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        author=$(echo "$line" | jq -r '.author // empty')
        [[ "$author" != "$MY_LOGIN" ]] && echo "$line" || true
    done)
    PENDING_REVIEWS=$(echo "$PENDING_REVIEWS_RAW" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        author=$(echo "$line" | jq -r '.author // empty')
        [[ "$author" != "$MY_LOGIN" ]] && echo "$line" || true
    done)
else
    PENDING_REVIEWS="$PENDING_REVIEWS_RAW"
fi

review_count=$(echo "$REVIEWED_PRS" | grep -c '"repo"' || true)
pending_review_count=$(echo "$PENDING_REVIEWS" | grep -c '"repo"' || true)
echo "  Found $review_count code reviews, $pending_review_count pending reviews"
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

# Process PR updates
echo ""
echo "Processing PR updates..."
while IFS= read -r pr_json; do
    [[ -z "$pr_json" || "$pr_json" != "{"* ]] && continue

    repo=$(echo "$pr_json" | jq -r '.repo')
    title=$(echo "$pr_json" | jq -r '.title')
    url=$(echo "$pr_json" | jq -r '.url')
    date=$(echo "$pr_json" | jq -r '.date')

    [[ -z "$repo" || "$repo" = "null" ]] && continue

    month_file=$(get_month_file "$date")
    full_path="$VAULT_PATH/$month_file"

    # For updates, check if this specific date+URL combo exists on the same row (same PR can be updated multiple days)
    if [[ -f "$full_path" ]]; then
        # Extract PR Updates section and check for a row containing both date AND URL
        if grep -A1000 "## PR Updates" "$full_path" 2>/dev/null | grep -B1000 "## Code Reviews" 2>/dev/null | grep -F "$date" | grep -qF "$url"; then
            echo "  Skipping (exists): $title"
            continue
        fi
    fi

    title=$(escape_markdown "$title")
    update_row="| $date | $repo | [$title]($url) | Continued work |"
    echo "  + updated $repo: $title"
    echo "$update_row" >> "$TEMP_DIR/${month_file}.updates"
done <<< "$UPDATED_PRS"

# Process pending reviews
echo ""
echo "Processing pending reviews..."
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
    pending_row="| $date | $repo | [$title]($url) | @$author |"
    echo "  + pending review $repo: $title (by @$author)"
    echo "$pending_row" >> "$TEMP_DIR/${month_file}.pending"
done <<< "$PENDING_REVIEWS"

echo ""

# Check if any changes to make
shopt -s nullglob
pr_files=("$TEMP_DIR"/*.prs)
review_files=("$TEMP_DIR"/*.reviews)
update_files=("$TEMP_DIR"/*.updates)
pending_files=("$TEMP_DIR"/*.pending)
shopt -u nullglob

if [[ ${#pr_files[@]} -eq 0 && ${#review_files[@]} -eq 0 && ${#update_files[@]} -eq 0 && ${#pending_files[@]} -eq 0 ]]; then
    echo "No new PRs, updates, or reviews to add"
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
| **Open** | 0 |
| **PR Updates** | 0 |
| **Reviews** | 0 |
| **Pending Reviews** | 0 |

## PRs

| Date | Repo | Title | Status |
|------|------|-------|--------|

## PR Updates

| Date | Repo | Title | Update |
|------|------|-------|--------|

## Code Reviews

| Date | Repo | Title | Author |
|------|------|-------|--------|

## Pending Reviews

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

# Update summary statistics in a month file
update_summary() {
    local file="$1"

    # Count PRs by status (last column in PR table rows)
    local merged=$(grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| merged \|$' "$file" | wc -l | tr -d ' ')
    local closed=$(grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| closed \|$' "$file" | wc -l | tr -d ' ')
    local open=$(grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| open \|$' "$file" | wc -l | tr -d ' ')
    local total=$((merged + closed + open))

    # Count PR updates (rows in PR Updates section - look for "Continued work" pattern)
    local pr_updates=$(grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| Continued work \|$' "$file" | wc -l | tr -d ' ')

    # Count reviews (rows in Code Reviews section only - between "## Code Reviews" and "## Pending Reviews")
    local reviews=$(sed -n '/^## Code Reviews$/,/^## Pending Reviews$/p' "$file" | grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| @' | wc -l | tr -d ' ')

    # Count pending reviews (rows in Pending Reviews section - between "## Pending Reviews" and "## Related Project Notes")
    local pending_reviews=$(sed -n '/^## Pending Reviews$/,/^## Related Project Notes$/p' "$file" | grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| @' | wc -l | tr -d ' ')

    # Update the summary table using sed
    sed_inplace "s/| \*\*Total PRs\*\* | [0-9]* |/| **Total PRs** | $total |/" "$file"
    sed_inplace "s/| \*\*Merged\*\* | [0-9]* |/| **Merged** | $merged |/" "$file"
    sed_inplace "s/| \*\*Closed\*\* | [0-9]* |/| **Closed** | $closed |/" "$file"
    sed_inplace "s/| \*\*Open\*\* | [0-9]* |/| **Open** | $open |/" "$file"
    sed_inplace "s/| \*\*PR Updates\*\* | [0-9]* |/| **PR Updates** | $pr_updates |/" "$file"
    sed_inplace "s/| \*\*Reviews\*\* | [0-9]* |/| **Reviews** | $reviews |/" "$file"
    sed_inplace "s/| \*\*Pending Reviews\*\* | [0-9]* |/| **Pending Reviews** | $pending_reviews |/" "$file"
}

if [[ "$DRY_RUN" = true ]]; then
    echo "DRY RUN - Changes that would be made:"
    for pr_file in "$TEMP_DIR"/*.prs; do
        [[ -f "$pr_file" ]] || continue
        echo ""
        echo "$(basename "$pr_file" .prs) - PRs:"
        cat "$pr_file"
    done
    for update_file in "$TEMP_DIR"/*.updates; do
        [[ -f "$update_file" ]] || continue
        echo ""
        echo "$(basename "$update_file" .updates) - PR Updates:"
        cat "$update_file"
    done
    for review_file in "$TEMP_DIR"/*.reviews; do
        [[ -f "$review_file" ]] || continue
        echo ""
        echo "$(basename "$review_file" .reviews) - Reviews:"
        cat "$review_file"
    done
    for pending_file in "$TEMP_DIR"/*.pending; do
        [[ -f "$pending_file" ]] || continue
        echo ""
        echo "$(basename "$pending_file" .pending) - Pending Reviews:"
        cat "$pending_file"
    done
else
    # Get unique months (use nullglob to handle missing file types)
    shopt -s nullglob
    all_temp_files=("$TEMP_DIR"/*.prs "$TEMP_DIR"/*.updates "$TEMP_DIR"/*.reviews "$TEMP_DIR"/*.pending)
    shopt -u nullglob
    months=$(printf '%s\n' "${all_temp_files[@]}" | xargs -n1 basename 2>/dev/null | sed -E 's/\.(prs|updates|reviews|pending)$//' | sort -u)

    for month_file in $months; do
        full_path="$VAULT_PATH/$month_file"

        # Create file if needed
        if [[ ! -f "$full_path" ]]; then
            month_name=$(echo "$month_file" | sed 's/[0-9]*-//' | sed 's/.md//')
            echo "Creating: $month_file"
            create_month_file "$full_path" "$month_name"
        fi

        # Insert PRs before PR Updates section
        if [[ -f "$TEMP_DIR/${month_file}.prs" ]]; then
            insert_before_section "$full_path" "## PR Updates" "$(cat "$TEMP_DIR/${month_file}.prs")"
        fi

        # Insert PR updates before Code Reviews section
        if [[ -f "$TEMP_DIR/${month_file}.updates" ]]; then
            insert_before_section "$full_path" "## Code Reviews" "$(cat "$TEMP_DIR/${month_file}.updates")"
        fi

        # Insert reviews before Pending Reviews section
        if [[ -f "$TEMP_DIR/${month_file}.reviews" ]]; then
            insert_before_section "$full_path" "## Pending Reviews" "$(cat "$TEMP_DIR/${month_file}.reviews")"
        fi

        # Insert pending reviews before Related Project Notes section
        if [[ -f "$TEMP_DIR/${month_file}.pending" ]]; then
            insert_before_section "$full_path" "## Related Project Notes" "$(cat "$TEMP_DIR/${month_file}.pending")"
        fi

        # Update summary statistics
        update_summary "$full_path"

        echo "Updated: $month_file"
    done
fi

echo ""
echo "Done!"
