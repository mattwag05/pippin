// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pippin",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "7.0.0"
        ),
    ],
    targets: [
        // Library target — all application logic (importable by tests)
        .target(
            name: "PippinLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "pippin",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Executable entry point — just the @main struct
        .executableTarget(
            name: "pippin",
            dependencies: ["PippinLib"],
            path: "pippin-entry",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Test target
        .testTarget(
            name: "PippinTests",
            dependencies: ["PippinLib", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/PippinTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
