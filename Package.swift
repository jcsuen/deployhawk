// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeployHawk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DeployHawk", targets: ["DeployHawk"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DeployHawk",
            dependencies: [],
            path: "Sources"
        )
    ]
)
