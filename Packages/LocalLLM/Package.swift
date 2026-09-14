// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalLLM",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LocalLLM", targets: ["LocalLLM"])],
    targets: [
        .target(name: "LocalLLM"),
        .testTarget(name: "LocalLLMTests", dependencies: ["LocalLLM"]),
    ],
    swiftLanguageModes: [.v6],
)
