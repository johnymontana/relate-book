// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelateBooks",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "RelateBooksCore", targets: ["RelateBooksCore"]),
    ],
    dependencies: [
        // The published Relate release: SwiftPM downloads its RelateFFI.xcframework (checksum-pinned).
        .package(url: "https://github.com/relatedb/relate", exact: "1.0.1"),
    ],
    targets: [
        // Everything under RelateBooks/ except the SwiftUI app, the UI-only Features/ views and the bundled store.
        // Embedding/Model (the pre-compiled Core ML model + vocab) is a copied resource: SwiftPM does not
        // compile .mlpackage files, so one pre-compiled .mlmodelc serves both this package and the app.
        .target(
            name: "RelateBooksCore",
            dependencies: [.product(name: "Relate", package: "relate")],
            path: "RelateBooks",
            exclude: ["App", "Features", "Resources"],
            resources: [.copy("Embedding/Model")]
        ),
        .testTarget(
            name: "RelateBooksCoreTests",
            dependencies: [
                "RelateBooksCore",
                .product(name: "Relate", package: "relate"),
            ],
            path: "Tests/RelateBooksCoreTests",
            // Read through #filePath (FixtureFiles), like PerfTests reads books.rl.
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
