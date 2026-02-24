// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnityMCPHubApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "UnityMCPHubApp", targets: ["UnityMCPHubApp"])
    ],
    targets: [
        .executableTarget(
            name: "UnityMCPHubApp",
            path: "Sources/UnityMCPHubApp"
        )
    ]
)
