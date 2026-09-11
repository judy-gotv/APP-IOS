// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NanoStreamClone",
    platforms: [.iOS(.v16)],
    products: [
        .executable(name: "NanoStreamClone", targets: ["NanoStreamClone"])
    ],
    targets: [
        .executableTarget(
            name: "NanoStreamClone",
            resources: [.process("Reference")]
        )
    ]
)
