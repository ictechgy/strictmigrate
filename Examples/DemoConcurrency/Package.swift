// swift-tools-version:5.10
// Demo package that intentionally violates strict concurrency rules.
// Measured with -strict-concurrency=complete (Swift 5 language mode → warnings).
import PackageDescription

let package = Package(
    name: "DemoConcurrency",
    // An explicit floor keeps SPM's default (macOS 10.13 under swift-tools 5.10)
    // from turning Task/withTaskGroup availability errors into measurement noise.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ImagePipelineCore", targets: ["ImagePipelineCore"])
    ],
    targets: [
        .target(name: "ImagePipelineCore"),
        .executableTarget(
            name: "DemoApp",
            dependencies: ["ImagePipelineCore"]
        ),
    ]
)
