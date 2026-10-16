// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cubby",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cubby", path: "Sources/Cubby")
    ],
    swiftLanguageModes: [.v5]
)
