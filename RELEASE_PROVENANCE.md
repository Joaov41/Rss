# RSSum iOS 1.5 App Store staging

- Source of truth: checkpoint archive `ios-pre-appstore-testflight-20260818-212118/ios-source-and-project.tar.gz`
- Checkpoint SHA-256: `323651238f4b11bf03c8579acacec5756ec1285cd917799f4bea71725b713bcf`
- Frozen source checkout HEAD: `aa709752bc0c00075964a6f291da16d3bbbc87a4`
- Lane: public App Store workflow `6B2EB829-7B0D-47A2-8C01-5756777EC2C6`
- Marketing version/build: `1.5 (69)`
- Deployment target: iOS `26.0`
- Bundle identifiers: `com.example.RSSReaderApp`, `com.example.RSSReaderApp.widget`

The source is checkpoint parity except for the documented public-SDK compatibility guard in `AppState.swift`, the Favorites section type-checking split in `ContentView.swift`, version/build settings, and relocation of local package references under `Packages/` so the forbidden nested `rss mac` directory is not required. PCC implementation remains available only under the SDK that provides it; the public lane reports the existing iOS 26 fallback message.

The commit intentionally excludes the root `rss mac` directory, `.gemini`, generated build/DerivedData/.swiftpm caches, user-state files, and unrelated local automation/docs/artifacts.
