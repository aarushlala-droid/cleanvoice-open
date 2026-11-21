// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CleanVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CleanVoice", path: "Sources/CleanVoice")
    ]
)
