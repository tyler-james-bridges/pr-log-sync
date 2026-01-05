# PR Log Sync

Sync your GitHub pull requests and code reviews to Obsidian markdown files. Generates monthly PR log files perfect for tracking your contributions, performance reviews, and work documentation.

## Features

- Fetches PRs you authored (merged and closed)
- Fetches PRs you reviewed
- Creates monthly markdown files with tables
- Skips duplicates automatically
- Supports date range filtering
- Dry-run mode for previewing changes
- Cross-platform (macOS and Linux)

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`) - authenticated
- [jq](https://jqlang.github.io/jq/) - JSON processor
- Bash 4.0+

## Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/pr-log-sync.git

# Make the script executable
chmod +x pr-log-sync/pr-log-sync.sh

# Optionally, add to your PATH
cp pr-log-sync/pr-log-sync.sh ~/bin/
```

## Usage

```bash
# Basic usage - sync last 7 days
pr-log-sync.sh --org mycompany

# Specify date range
pr-log-sync.sh --org mycompany --from 2026-01-01 --to 2026-01-31

# Preview changes without writing
pr-log-sync.sh --org mycompany --dry-run

# Custom vault path
pr-log-sync.sh --org mycompany --vault ~/Documents/MyVault/PR-Logs
```

### Options

| Option | Description |
|--------|-------------|
| `--org ORG` | GitHub organization name (required) |
| `--vault PATH` | Obsidian vault path (default: `~/Documents/Obsidian Vault/YEAR/PR Log`) |
| `--from DATE` | Start date in YYYY-MM-DD format (default: 7 days ago) |
| `--to DATE` | End date in YYYY-MM-DD format (default: today) |
| `--dry-run` | Preview changes without writing files |
| `-h, --help` | Show help message |

### Environment Variables

You can also configure via environment variables:

```bash
export GITHUB_ORG=mycompany
export VAULT_PATH=~/Documents/MyVault/PR-Logs

pr-log-sync.sh  # Uses env vars
```

## Output Format

The script creates monthly files (e.g., `01-January.md`) with this structure:

```markdown
# January 2026 - PR Log

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
| 2026-01-15 | my-repo | [Add new feature](https://github.com/...) | merged |

## Code Reviews

| Date | Repo | Title | Author |
|------|------|-------|--------|
| 2026-01-14 | other-repo | [Fix bug](https://github.com/...) | @teammate |
```

## Automation

### Cron Job

Run daily to keep your logs up to date:

```bash
# Edit crontab
crontab -e

# Add daily sync at 9 AM
0 9 * * * GITHUB_ORG=mycompany /path/to/pr-log-sync.sh >> /tmp/pr-log-sync.log 2>&1
```

### GitHub Actions

You can also run this as a GitHub Action to sync to a separate repository.

## License

MIT License - see [LICENSE](LICENSE)
