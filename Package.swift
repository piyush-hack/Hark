// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Hark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hark", targets: ["Hark"]),
        .executable(name: "harkctl", targets: ["HarkCLI"]),
        .library(name: "HarkCore", targets: ["HarkCore"]),
    ],
    dependencies: [
        // Last FluidAudio release that builds with Swift 5.10 / Xcode 15.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.8.2"),
    ],
    targets: [
        .target(
            name: "HarkCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "Hark", dependencies: ["HarkCore"]),
        .executableTarget(name: "HarkCLI", dependencies: ["HarkCore"]),
        .testTarget(name: "HarkCoreTests", dependencies: ["HarkCore"], resources: [.copy("Fixtures")]),
    ]
)
