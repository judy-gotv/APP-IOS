// swift-tools-version: 5.9
// NOTE: This Package.swift is NOT the app build path and cannot produce an
// installable iOS app (SPM executable targets are command-line tools, not
// SwiftUI apps). The authoritative build path is project.yml (XcodeGen) +
// .github/workflows/build-ipa.yml. This file is NOT a type-check path
// either: its executable target compiles the whole Sources tree —
// including SwiftUI/AVKit/KSPlayer UI code, not "pure-logic sources" —
// and therefore requires the Apple SDKs, so `swift build` fails on Linux
// and proves nothing there. It exists only to keep the KSPlayer version
// (2.3.4) visible next to project.yml; do not cite it as a build or
// check step.
import PackageDescription

let package = Package(
    name: "NanoStreamClone",
    platforms: [.iOS(.v16)],
    products: [
        .executable(name: "NanoStreamClone", targets: ["NanoStreamClone"])
    ],
    dependencies: [
        .package(url: "https://github.com/kingslay/KSPlayer.git", from: "2.3.4")
    ],
    targets: [
        .executableTarget(
            name: "NanoStreamClone",
            dependencies: [.product(name: "KSPlayer", package: "KSPlayer")]
        )
    ]
)
