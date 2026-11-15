// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shapr",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Shapr",
            path: "Sources/Shapr",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
