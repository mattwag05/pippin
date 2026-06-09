// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pippin",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Dependency policy: `.upToNextMinor` is the declared upgrade target —
        // patch releases within the current minor are accepted automatically;
        // moving to a new minor (or major) requires an explicit PR that also
        // refreshes Package.resolved. Package.resolved is the authoritative
        // supply-chain pin (records the exact resolved version + git revision
        // SHA per the action/lockfile-pinning policy). Hold these floors until
        // a deliberate upgrade.
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            .upToNextMinor(from: "1.7.0")
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            .upToNextMinor(from: "7.10.0")
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
            dependencies: ["PippinLib", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "pippin-entry",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Embed Info.plist into the binary's __TEXT,__info_plist section so
            // the CLI has a stable TCC identity + the usage-description strings
            // macOS requires before presenting a permission prompt. Without
            // this, EventKit/Contacts requests are unreliable outside an
            // interactive terminal (the background-LaunchAgent failure behind
            // the permission-coverage work). `.unsafeFlags` is fine here: pippin
            // is an app, never consumed as a versioned library dependency.
            // The path is resolved by the linker from the package root. (pippin-1zv)
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "pippin-entry/Info.plist",
                ]),
            ]
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
