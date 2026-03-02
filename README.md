# PR Log Sync

Sync your GitHub pull requests and code reviews to monthly Obsidian markdown files.

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`) - authenticated
- [jq](https://jqlang.github.io/jq/)
- Bash 4.0+ (macOS ships 3.2 — install a newer version via `brew install bash`)

## Installation

```bash
git clone https://github.com/tyler-james-bridges/pr-log-sync.git
chmod +x pr-log-sync/pr-log-sync.sh

# Copy to a directory in your PATH
cp pr-log-sync/pr-log-sync.sh ~/bin/
```

> **Note:** Ensure `~/bin` is in your `$PATH`. Add `export PATH="$HOME/bin:$PATH"` to your shell profile if needed.

## Usage

```bash
pr-log-sync.sh --org mycompany
pr-log-sync.sh --org mycompany --from 2026-01-01 --to 2026-01-31
pr-log-sync.sh --org mycompany --dry-run
```

Run `pr-log-sync.sh --help` for all options and environment variables.

The generated files contain section headers (`## PRs`, `## Code Reviews`, etc.) that the script uses as anchors for inserting new data. Avoid renaming or removing these headers.

## Automation

### launchd (macOS)

Cron on macOS lacks Full Disk Access, so use a LaunchAgent instead:

```bash
cat > ~/Library/LaunchAgents/com.user.pr-log-sync.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.pr-log-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/pr-log-sync.sh</string>
        <string>--org</string>
        <string>mycompany</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
        <!-- Uncomment to override the default vault path:
        <key>VAULT_PATH</key>
        <string>/path/to/your/vault/Work/PR Log</string>
        -->
    </dict>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>StandardOutPath</key>
    <string>/tmp/pr-log-sync.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/pr-log-sync.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.user.pr-log-sync.plist
```

### Cron (Linux)

```bash
0 */4 * * * GITHUB_ORG=mycompany /path/to/pr-log-sync.sh >> /tmp/pr-log-sync.log 2>&1
```

## License

MIT
