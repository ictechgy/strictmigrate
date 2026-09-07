// swift-tools-version:5.10
// KMP boundary demo: an iOS app (simulated by KmpDemoApp) consuming a shared
// Kotlin module's surface (simulated by SharedKit; in a real repo this comes
// from the Kotlin/Native framework export of shared/).
import PackageDescription

let package = Package(
    name: "KmpBoundary",
    // Explicit floor — see DemoConcurrency/Package.swift.
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SharedKit"),
        .executableTarget(
            name: "KmpDemoApp",
            dependencies: ["SharedKit"]
        ),
    ]
)
