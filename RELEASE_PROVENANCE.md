# RSSum iOS 1.5 SDK27 TestFlight staging

- Source of truth: checkpoint archive `ios-pre-appstore-testflight-20260818-212118/ios-source-and-project.tar.gz`
- Checkpoint SHA-256: `323651238f4b11bf03c8579acacec5756ec1285cd917799f4bea71725b713bcf`
- Frozen source checkout HEAD: `aa709752bc0c00075964a6f291da16d3bbbc87a4`
- Lane: SDK27 TestFlight workflow `1971b56c-7660-48d8-8192-a1f0505b48bb`
- Marketing version/build: `1.5 (70)`
- Deployment target: iOS `26.0`
- Bundle identifiers: `com.example.RSSReaderApp`, `com.example.RSSReaderApp.widget`
- Selected current Xcode 27 seed: `27A5237l` (Xcode 27 beta 5 / latest beta-or-release catalog entries)

The source is checkpoint parity except for version/build settings and relocation of local package references under `Packages/` so the forbidden nested `rss mac` directory is not required. The iOS 27 Foundation Models Private Cloud Compute implementation is retained in this lane.

The commit intentionally excludes the root `rss mac` directory, `.gemini`, generated build/DerivedData/.swiftpm caches, user-state files, and unrelated local automation/docs/artifacts.
