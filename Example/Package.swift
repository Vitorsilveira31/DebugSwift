// swift-tools-version: 6.1
// The DebugSwift Example: one Skip (https://skip.dev) app for iOS and Android.
//
// All screens live in the `DebugSwiftExample` module and are plain SwiftUI. On iOS the module is
// compiled natively; on Android Skip Fuse compiles the same Swift for Android and renders the
// SwiftUI as Compose. `Darwin/Example.xcodeproj` is the iOS host and `Android/` the Gradle host.
import PackageDescription

let package = Package(
    name: "debugswift-example",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DebugSwiftExample", type: .dynamic, targets: ["DebugSwiftExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.9.11"),
        .package(url: "https://github.com/skiptools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.0.0"),
        .package(name: "DebugSwift", path: "..")
    ],
    targets: [
        // Only the DebugSwiftUI product: it already carries DebugSwiftCore, and DebugSwift on iOS.
        // Depending on those products as well would link a second copy of them into this module.
        .target(name: "DebugSwiftExample", dependencies: [
            .product(name: "DebugSwiftUI", package: "DebugSwift"),
            .product(name: "SkipFuse", package: "skip-fuse"),
            .product(name: "SkipFuseUI", package: "skip-fuse-ui")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
