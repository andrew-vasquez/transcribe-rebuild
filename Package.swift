// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TranscribeRebuilt",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "TranscribeRebuilt",
            path: "Sources/TranscribeRebuilt",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
