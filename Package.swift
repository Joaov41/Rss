// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RSSReaderApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher", from: "8.0.0"),
        .package(url: "https://github.com/nmdias/FeedKit", from: "9.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.0.0"),
        // MLX Swift packages for local model inference
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.30.3")
    ]
)
