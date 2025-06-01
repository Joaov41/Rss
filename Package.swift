// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "RSSReaderApp",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "RSSReaderApp",
            dependencies: ["Kingfisher"]),
    ]
)
