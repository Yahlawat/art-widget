// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArtWidget",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ArtWidget", path: "Sources/ArtWidget")
    ],
    swiftLanguageModes: [.v5]
)
