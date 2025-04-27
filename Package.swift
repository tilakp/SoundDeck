// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "SoundDeck",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "SoundDeck", targets: ["SoundDeck"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SoundDeck",
            dependencies: [],
            path: ".",
            exclude: ["Info.plist"]
        )
    ]
)
