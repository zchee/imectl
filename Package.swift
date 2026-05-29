// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "imectl",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "imectl",
            dependencies: ["IMECore"],
            path: "Sources/imectl"
        ),
        .target(
            name: "IMECore",
            path: "Sources/IMECore",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "IMECoreTests",
            dependencies: ["IMECore"],
            path: "Tests/IMECoreTests"
        ),
    ]
)
