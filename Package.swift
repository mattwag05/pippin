// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pippin",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        // Library target — all application logic (importable by tests)
        .target(
            name: "PippinLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "pippin"
        ),
        // Executable entry point — just the @main struct
        .executableTarget(
            name: "pippin",
            dependencies: ["PippinLib"],
            path: "pippin-entry"
        ),
        // Test target
        .testTarget(
            name: "PippinTests",
            dependencies: ["PippinLib"],
            path: "Tests/PippinTests"
        ),
    ]
)
