// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lento",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Lento",
            path: "Sources/Lento",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
