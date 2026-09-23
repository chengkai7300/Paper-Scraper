// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperScraperCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PaperScraperCore", targets: ["PaperScraperCore"]),
    ],
    targets: [
        .target(name: "PaperScraperCore"),
        .testTarget(
            name: "PaperScraperCoreTests",
            dependencies: ["PaperScraperCore"],
            resources: [.copy("Fixtures/golden.json")]
        ),
    ]
)
