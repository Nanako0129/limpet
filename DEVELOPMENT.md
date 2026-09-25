# SyncTray Development Guide

## Prerequisites

- macOS 13+ (Ventura or later)
- Xcode 15+
- [rclone](https://rclone.org/) installed (`brew install rclone`)

## Build & Run

```bash
# Build
xcodebuild -scheme SyncTray -destination 'platform=macOS' build

# Build with pretty output
xcodebuild -scheme SyncTray -destination 'platform=macOS' build 2>&1 | xcbeautify

# Run
open ~/Library/Developer/Xcode/DerivedData/SyncTray-*/Build/Products/Debug/SyncTray.app
```

## Project Structure

```
SyncTray/
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Assets.xcassets/  # App icons and images
└── SyncTrayApp.swift # App entry point and AppDelegate
```

See [CLAUDE.md](CLAUDE.md) for full architecture documentation.

## Debugging

### Enable Debug Logging

Toggle **Debug Logging** in Settings to enable verbose output in sync log files.

### Inspect launchd Agents

```bash
launchctl list | grep synctray
launchctl print gui/$(id -u)/com.synctray.sync.{shortId}
cat ~/Library/LaunchAgents/com.synctray.sync.*.plist
```

### View Sync Logs

```bash
tail -f ~/.local/log/synctray-sync-{shortId}.log
```

### Lock Files

```bash
ls -la /tmp/synctray-sync-*.lock
```

Stale locks are cleaned on app startup.
