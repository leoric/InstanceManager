// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "instance-manager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "InstanceManager", path: "Sources/InstanceManager")
    ]
)
