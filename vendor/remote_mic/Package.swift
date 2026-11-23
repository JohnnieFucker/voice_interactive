// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteVibe",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AudioExceptionGuard", publicHeadersPath: "include"),
        .executableTarget(name: "RemoteVibe", dependencies: ["AudioExceptionGuard"]),
        .testTarget(name: "RemoteVibeTests", dependencies: ["RemoteVibe"])
    ]
)
