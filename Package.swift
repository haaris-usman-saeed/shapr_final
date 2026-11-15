// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shapr",
    platforms: [.macOS("26.0")],
    targets: [
        // Shapr Flow's core: session, permissions, memory, retrieval. Foundation only, so it
        // builds and is checked on any platform (`swift run ShaprCoreChecks`).
        .target(
            name: "ShaprCore",
            path: "Sources/ShaprCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ShaprCoreChecks",
            dependencies: ["ShaprCore"],
            path: "Sources/ShaprCoreChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Shapr",
            dependencies: ["ShaprCore"],
            path: "Sources/Shapr",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
