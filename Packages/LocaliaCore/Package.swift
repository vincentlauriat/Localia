// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocaliaCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LocaliaCore", targets: ["LocaliaCore"])],
    targets: [
        .target(name: "LocaliaCore"),
        .testTarget(
            name: "LocaliaCoreTests",
            dependencies: ["LocaliaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
