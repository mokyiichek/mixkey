// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MixKey",
    platforms: [.macOS(.v13)],
    targets: [
        // Platform-neutral typing engine (pinyin lattice, English detection, casing, S->T).
        .target(
            name: "MixKeyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The macOS input method (InputMethodKit app bundle).
        .executableTarget(
            name: "MixKey",
            dependencies: ["MixKeyCore"],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // Command-line tool to try the engine without installing the input method.
        .executableTarget(
            name: "mixkey-cli",
            dependencies: ["MixKeyCore"]
        ),
    ]
)
