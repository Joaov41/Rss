# RSSum iOS SDK27 TestFlight staging

- Source of truth: `/Volumes/screen/rss latest ios27` at `aa709752bc0c00075964a6f291da16d3bbbc87a4`
- Base TestFlight lane: `codex/testflight-ios27-webai-20260816` at `d9bda79f3d8f07f2686f41d83059365ed56f27c4`
- Lane: SDK27 TestFlight-only workflow using the Xcode 27 beta toolchain
- Marketing version: `1.4`
- App and widget build: `61`
- Deployment target: iOS `26.0`
- Bundle mapping: `com.example.RSSReaderApp` and `com.example.RSSReaderApp.widget`
- Release entitlement: Private Cloud Compute enabled; App Store kvstore/application-group mapping retained

The current iOS Swift source was overlaid from the source-of-truth checkout. This lane is intentionally separate from the App Store lane and is not for App Store submission. The source-of-truth checkout was not modified.
