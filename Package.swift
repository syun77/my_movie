// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MVStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MVStudio", targets: ["MVStudio"])],
    targets: [
        .executableTarget(name: "MVStudio"),
        .testTarget(name: "MVStudioTests", dependencies: ["MVStudio"])
    ],
    swiftLanguageModes: [.v5]
)
