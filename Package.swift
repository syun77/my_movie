// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MVStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MVStudio", targets: ["MVStudio"])],
    targets: [
        .target(name: "SpineRuntime", path: "ThirdParty/spine-cpp", exclude: ["LICENSE", "README.md"], sources: ["src"], publicHeadersPath: "include"),
        .target(name: "SpineBridge", dependencies: ["SpineRuntime"]),
        .executableTarget(name: "MVStudio", dependencies: ["SpineBridge"], resources: [.copy("Shaders")]),
        .testTarget(name: "MVStudioTests", dependencies: ["MVStudio"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
