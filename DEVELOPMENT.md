# limpet Development Guide

## Prerequisites

- macOS 13+ (Ventura or later)
- Xcode 15+
- [rclone](https://rclone.org/) installed (`brew install rclone`)

## Build & Run

```bash
# Build
xcodebuild -scheme limpet -destination 'platform=macOS' build

# Build with pretty output
xcodebuild -scheme limpet -destination 'platform=macOS' build 2>&1 | xcbeautify

# Run
open ~/Library/Developer/Xcode/DerivedData/limpet-*/Build/Products/Debug/limpet.app
```

## Project Structure

```
limpet/
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Assets.xcassets/  # App icons and images
└── LimpetApp.swift # App entry point and AppDelegate
```

See [CLAUDE.md](CLAUDE.md) for full architecture documentation.

## Debugging

### Enable Debug Logging

Toggle **Debug Logging** in Settings to enable verbose output in sync log files.

### Inspect launchd Agents

```bash
launchctl list | grep limpet
launchctl print gui/$(id -u)/com.nanako.limpet.watch.{shortId}
cat ~/Library/LaunchAgents/com.nanako.limpet.watch.*.plist
```

### View Sync Logs

```bash
tail -f ~/.local/log/limpet-sync-{shortId}.log
```

### Lock Files

```bash
ls -la /tmp/limpet-sync-*.lock
```

Stale locks are cleaned on app startup.
