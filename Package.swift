// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Byte",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Byte",
            path: "Sources/Byte"
        ),
        .testTarget(name: "ByteTests", dependencies: ["Byte"])
    ]
)
