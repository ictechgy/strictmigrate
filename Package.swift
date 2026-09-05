// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "strictmigrate",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "strictmigrate", targets: ["strictmigrate"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "strictmigrate",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "strictmigrateTests",
            dependencies: ["strictmigrate"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
