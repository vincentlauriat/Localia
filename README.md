# Localia

A macOS menu-bar app that recommends, downloads and runs local LLMs, and launches Claude Code on them.

Status: work in progress (v1 under development).

## Build

```
xcodegen
xcodebuild -project Localia.xcodeproj -scheme Localia -configuration Debug build
cd Packages/LocaliaCore && swift test
```

## Licence

MIT, see `LICENSE`.
