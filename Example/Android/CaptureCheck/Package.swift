// swift-tools-version: 6.0
// Built by run.sh, which first copies DebugSwiftCore and the Android URLSession capture into
// Sources/, so the check always runs the code in this checkout.
import PackageDescription

let package = Package(
    name: "CaptureCheck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DebugSwiftCore", path: "Sources/DebugSwiftCore"),
        .executableTarget(name: "CaptureCheck", dependencies: ["DebugSwiftCore"], path: "Sources/CaptureCheck")
    ]
)
