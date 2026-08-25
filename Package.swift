// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoundDeck",
    platforms: [
        // Must track MACOSX_DEPLOYMENT_TARGET in SoundDeck.xcodeproj (currently 14.6),
        // otherwise SourceKit type-checks this target against the wrong SDK floor.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SoundDeck", targets: ["SoundDeck"])
    ],
    dependencies: [],
    targets: [
        // Type-checking aid only — the shippable app is built from SoundDeck.xcodeproj,
        // which supplies entitlements, the asset catalog and the bundled sounds.
        // Sources are listed explicitly: globbing the repo root previously pulled the
        // test targets into this module.
        .executableTarget(
            name: "SoundDeck",
            dependencies: [],
            path: "SoundDeck",
            sources: [
                "SoundDeckApp.swift",
                "SoundDeckModel.swift",
                "SoundPlayer.swift",
                "ContentView.swift",
                "WaveformView.swift"
            ]
        )
    ]
)
