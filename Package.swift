// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GreminderKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GreminderKit", targets: ["GreminderKit"]),
        .executable(name: "GreminderDesktop", targets: ["GreminderDesktop"]),
    ],
    dependencies: [
        .package(path: "Packages/LocalLLM"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1"),
        .package(url: "https://github.com/google/google-api-objectivec-client-for-rest", exact: "5.4.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS", exact: "9.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
    ],
    targets: [
        .target(name: "GreminderKit", dependencies: [
            .product(name: "LocalLLM", package: "LocalLLM"),
            .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            .product(name: "GoogleAPIClientForREST_Tasks", package: "google-api-objectivec-client-for-rest"),
            .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS"),
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ], path: "Greminder", exclude: ["App", "Resources"], resources: [.process("Localizations")]),
        .executableTarget(name: "GreminderDesktop", dependencies: ["GreminderKit"], path: "Greminder/App"),
        .testTarget(name: "GreminderKitTests", dependencies: [
            "GreminderKit",
            .product(name: "LocalLLM", package: "LocalLLM"),
        ], path: "Tests"),
    ],
    swiftLanguageModes: [.v5],
)
