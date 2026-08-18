# RSSum iOS App Store staging

- Source of truth: `/Volumes/screen/rss latest ios27` at `aa709752bc0c00075964a6f291da16d3bbbc87a4`
- Base release lane: `codex/appstore-ios-latest-20260816` at `e94a9f8d8eb5128d85d9a48c52db20dec66b7ccf`
- Lane: stable/public App Store workflow using the supported iOS 26 SDK
- Marketing version: `1.5`
- App and widget build: `60`
- Deployment target: iOS `26.0`
- Bundle mapping: `com.example.RSSReaderApp` and `com.example.RSSReaderApp.widget`
- Release entitlement: Private Cloud Compute enabled; App Store kvstore/application-group mapping retained

The current iOS Swift source was overlaid from the source-of-truth checkout. The macOS target and macOS-only files were not used to define this lane. This directory is isolated staging; the source-of-truth checkout was not modified.
