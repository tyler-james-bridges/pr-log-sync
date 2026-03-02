#!/usr/bin/env bash
#
# PR Log Sync - Sync GitHub PRs and code reviews to Obsidian markdown files
# https://github.com/tyler-james-bridges/pr-log-sync
#

set -euo pipefail

YEAR=$(date +%Y)
VAULT_PATH="${VAULT_PATH:-$HOME/Documents/Obsidian Vault/$YEAR/Work/PR Log}"
GITHUB_ORG="${GITHUB_ORG:-}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

if [[ "$(uname)" == "Darwin" ]]; then
    SED_INPLACE=(sed -i '')
else
    SED_INPLACE=(sed -i)
fi

command -v gh >/dev/null 2>&1 || { echo "Error: gh (GitHub CLI) required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq required"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: GitHub CLI not authenticated. Run: gh auth login"; exit 1; }

date_days_ago() {
    local days=$1
    date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "${days} days ago" +%Y-%m-%d
}

month_file_for_date() {
    local d="$1"
    local m n
    m=$(date -j -f "%Y-%m-%d" "$d" "+%m" 2>/dev/null || date -d "$d" "+%m")
    n=$(date -j -f "%Y-%m-%d" "$d" "+%B" 2>/dev/null || date -d "$d" "+%B")
    echo "${m}-${n}.md"
}

escape_markdown() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's/\[/\\[/g; s/\]/\\]/g; s/|/\\|/g'
}

FROM_DATE=$(date_days_ago 7)
TO_DATE=$(date +%Y-%m-%d)
DRY_RUN=false

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

Syncs GitHub PRs and code reviews to monthly Obsidian markdown files.
Each entry is filed into the month matching its date.

Required:
  --org ORG        GitHub organization (or set GITHUB_ORG env var)

Options:
  --vault PATH     Obsidian vault PR Log path (default: ~/Documents/Obsidian Vault/YEAR/Work/PR Log)
  --from DATE      Start date YYYY-MM-DD (default: 7 days ago)
  --to DATE        End date YYYY-MM-DD (default: today)
  --dry-run        Preview without writing files
  -h, --help       Show this help

Environment variables:
  GITHUB_ORG       GitHub organization (alternative to --org)
  VAULT_PATH       Override default vault path

Examples:
  pr-log-sync.sh --org mycompany
  pr-log-sync.sh --org mycompany --from 2026-01-01 --to 2026-01-31
  GITHUB_ORG=mycompany pr-log-sync.sh --dry-run
HELP
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

[[ -z "$GITHUB_ORG" ]] && { echo "Error: GitHub organization required. Use --org or set GITHUB_ORG env var."; exit 1; }

mkdir -p "$VAULT_PATH"

echo "PR Log Sync: $FROM_DATE to $TO_DATE"
[[ "$DRY_RUN" = true ]] && echo "DRY RUN - no files will be modified"
echo

MY_LOGIN=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [[ -n "$MY_LOGIN" ]]; then
    NOT_SELF='| select(.author.login != "'"$MY_LOGIN"'")'
else
    NOT_SELF=""
fi

echo "Fetching PRs and reviews..."

MERGED_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --merged --merged-at="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), status: "merged"}' 2>/dev/null || echo "")

CLOSED_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --state=closed --closed="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt,state \
    --jq '.[] | select(.state != "merged") | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), status: "closed"}' 2>/dev/null || echo "")

OPEN_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --state=open --created="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,createdAt \
    --jq '.[] | {repo: .repository.name, title: .title, url: .url, date: (.createdAt | split("T")[0]), status: "open"}' 2>/dev/null || echo "")

# Only include PRs created before the date range (already-open work that's still active)
UPDATED_PRS=$(gh search prs --author=@me --owner="$GITHUB_ORG" --state=open --updated="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,updatedAt,createdAt \
    --jq '.[] | select((.createdAt | split("T")[0]) < "'"$FROM_DATE"'") | {repo: .repository.name, title: .title, url: .url, date: (.updatedAt | split("T")[0])}' 2>/dev/null || echo "")

REVIEWED_PRS=$(gh search prs --reviewed-by=@me --owner="$GITHUB_ORG" --merged --merged-at="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,closedAt,author \
    --jq '.[] '"$NOT_SELF"' | {repo: .repository.name, title: .title, url: .url, date: (.closedAt | split("T")[0]), author: .author.login}' 2>/dev/null || echo "")

PENDING_REVIEWS=$(gh search prs --reviewed-by=@me --owner="$GITHUB_ORG" --state=open --updated="${FROM_DATE}..${TO_DATE}" \
    --limit=100 --json repository,title,url,updatedAt,author \
    --jq '.[] '"$NOT_SELF"' | {repo: .repository.name, title: .title, url: .url, date: (.updatedAt | split("T")[0]), author: .author.login}' 2>/dev/null || echo "")

ALL_PRS="${MERGED_PRS}
${CLOSED_PRS}
${OPEN_PRS}"

merged_count=$(echo "$MERGED_PRS" | grep -c '"status"' || true)
closed_count=$(echo "$CLOSED_PRS" | grep -c '"status"' || true)
open_count=$(echo "$OPEN_PRS" | grep -c '"status"' || true)
updated_count=$(echo "$UPDATED_PRS" | grep -c '"repo"' || true)
review_count=$(echo "$REVIEWED_PRS" | grep -c '"repo"' || true)
pending_count=$(echo "$PENDING_REVIEWS" | grep -c '"repo"' || true)
echo "  $merged_count merged, $closed_count closed, $open_count open, $updated_count updates, $review_count reviews, $pending_count pending"
for c in $merged_count $closed_count $open_count $updated_count $review_count $pending_count; do
    [[ $c -ge 100 ]] && { echo "Warning: results may be truncated at 100. Narrow the date range with --from/--to."; break; }
done
echo

# Each entry is filed into the month matching its own date.
# For updates, allows same URL with different dates (tracks daily activity).
process_entries() {
    local data="$1" ext="$2" extra_field="${3:-}" extra_prefix="${4:-}"

    while IFS= read -r pr_json; do
        [[ -z "$pr_json" || "$pr_json" != "{"* ]] && continue

        local repo title url date
        repo=$(echo "$pr_json" | jq -r '.repo')
        title=$(echo "$pr_json" | jq -r '.title')
        url=$(echo "$pr_json" | jq -r '.url')
        date=$(echo "$pr_json" | jq -r '.date')
        [[ -z "$repo" || "$repo" = "null" ]] && continue

        local month_file full_path
        month_file=$(month_file_for_date "$date")
        full_path="$VAULT_PATH/$month_file"

        if [[ -f "$full_path" ]]; then
            if [[ "$ext" == "updates" ]]; then
                grep -F "$url" "$full_path" | grep -qF "$date" && continue
            else
                grep -qF "$url" "$full_path" && continue
            fi
        fi

        title=$(escape_markdown "$title")
        local last_col
        if [[ -n "$extra_field" ]]; then
            last_col="${extra_prefix}$(echo "$pr_json" | jq -r ".$extra_field")"
        else
            last_col="$extra_prefix"
        fi

        echo "| $date | $repo | [$title]($url) | $last_col |" >> "$TEMP_DIR/${month_file}.$ext"
    done <<< "$data"
}

echo "Processing..."
process_entries "$ALL_PRS" "prs" "status" ""
process_entries "$UPDATED_PRS" "updates" "" "Continued work"
process_entries "$REVIEWED_PRS" "reviews" "author" "@"
process_entries "$PENDING_REVIEWS" "pending" "author" "@"

shopt -s nullglob
temp_files=("$TEMP_DIR"/*)
shopt -u nullglob
[[ ${#temp_files[@]} -eq 0 ]] && { echo "No new data to add"; exit 0; }

create_month_file() {
    local path="$1" month_name="$2"
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

## Notes
EOF
}

insert_before_section() {
    local file="$1" section="$2" content="$3"
    if ! grep -qF "$section" "$file"; then
        echo "Warning: section '$section' not found in $(basename "$file") — skipping insert"
        return 0
    fi
    local line_num
    line_num=$(grep -nF "$section" "$file" | head -1 | cut -d: -f1)
    head -n $((line_num - 1)) "$file" > "${file}.tmp"
    echo "$content" >> "${file}.tmp"
    echo >> "${file}.tmp"
    tail -n +"$line_num" "$file" >> "${file}.tmp"
    mv "${file}.tmp" "$file"
}

update_summary() {
    local file="$1"
    local merged closed open total pr_updates reviews pending_reviews

    merged=$(grep -cE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| merged \|$' "$file" || true)
    closed=$(grep -cE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| closed \|$' "$file" || true)
    open=$(grep -cE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| open \|$' "$file" || true)
    total=$((merged + closed + open))
    pr_updates=$(grep -cE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| Continued work \|$' "$file" || true)
    # Scope review counts to their sections to avoid cross-contamination
    reviews=$(sed -n '/^## Code Reviews$/,/^## Pending Reviews$/p' "$file" | grep -cE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| @' || true)
    pending_reviews=$(sed -n '/^## Pending Reviews$/,/^## Notes$/p' "$file" | grep -cE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|.*\| @' || true)

    "${SED_INPLACE[@]}" "s/| \*\*Total PRs\*\* | [0-9]* |/| **Total PRs** | $total |/" "$file"
    "${SED_INPLACE[@]}" "s/| \*\*Merged\*\* | [0-9]* |/| **Merged** | $merged |/" "$file"
    "${SED_INPLACE[@]}" "s/| \*\*Closed\*\* | [0-9]* |/| **Closed** | $closed |/" "$file"
    "${SED_INPLACE[@]}" "s/| \*\*Open\*\* | [0-9]* |/| **Open** | $open |/" "$file"
    "${SED_INPLACE[@]}" "s/| \*\*PR Updates\*\* | [0-9]* |/| **PR Updates** | $pr_updates |/" "$file"
    "${SED_INPLACE[@]}" "s/| \*\*Reviews\*\* | [0-9]* |/| **Reviews** | $reviews |/" "$file"
    "${SED_INPLACE[@]}" "s/| \*\*Pending Reviews\*\* | [0-9]* |/| **Pending Reviews** | $pending_reviews |/" "$file"
}

if [[ "$DRY_RUN" = true ]]; then
    echo "DRY RUN - Changes that would be made:"
    for f in "$TEMP_DIR"/*; do
        [[ -f "$f" ]] || continue
        echo
        echo "$(basename "$f"):"
        cat "$f"
    done
else
    months=()
    while IFS= read -r m; do months+=("$m"); done < <(printf '%s\n' "${temp_files[@]}" | xargs -n1 basename | sed -E 's/\.(prs|updates|reviews|pending)$//' | sort -u)

    for month_file in "${months[@]}"; do
        full_path="$VAULT_PATH/$month_file"

        if [[ ! -f "$full_path" ]]; then
            month_name=$(echo "$month_file" | sed -E 's/^[0-9]+-//; s/\.md$//')
            echo "Creating: $month_file"
            create_month_file "$full_path" "$month_name"
        fi

        [[ -f "$TEMP_DIR/${month_file}.prs" ]]     && insert_before_section "$full_path" "## PR Updates" "$(cat "$TEMP_DIR/${month_file}.prs")"
        [[ -f "$TEMP_DIR/${month_file}.updates" ]]  && insert_before_section "$full_path" "## Code Reviews" "$(cat "$TEMP_DIR/${month_file}.updates")"
        [[ -f "$TEMP_DIR/${month_file}.reviews" ]]  && insert_before_section "$full_path" "## Pending Reviews" "$(cat "$TEMP_DIR/${month_file}.reviews")"
        [[ -f "$TEMP_DIR/${month_file}.pending" ]]  && insert_before_section "$full_path" "## Notes" "$(cat "$TEMP_DIR/${month_file}.pending")"

        update_summary "$full_path"
        echo "Updated: $month_file"
    done
fi

echo
echo "Done!"
