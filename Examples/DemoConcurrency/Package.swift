// swift-tools-version:5.10
// Demo package that intentionally violates strict concurrency rules.
// Measured with -strict-concurrency=complete (Swift 5 language mode → warnings).
import PackageDescription

let package = Package(
    name: "DemoConcurrency",
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
