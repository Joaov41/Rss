// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EventSource",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0"),
        .macCatalyst("15.0"),
        .watchOS("8.0"),
        .tvOS("15.0"),
        .visionOS("1.0"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "EventSource",
            targets: ["EventSource"]
        )
    ],
    traits: [
        .trait(name: "AsyncHTTPClient")
    ],
    dependencies: [],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "EventSource",
            dependencies: [],
            exclude: ["EventSource+AsyncHTTPClient.swift"]
        ),
    ]
)
