// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ByteMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ByteMeter", path: "Sources/ByteMeter")
    ]
)
