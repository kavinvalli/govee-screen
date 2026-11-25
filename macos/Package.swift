// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GoveeScreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GoveeScreen", path: "Sources/GoveeScreen"),
    ]
)
