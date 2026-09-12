// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CutFlow",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CutFlow", targets: ["CutFlow"])],
    targets: [
        .target(name: "CutFlowCore"),
        .executableTarget(name: "CutFlow", dependencies: ["CutFlowCore"]),
        .testTarget(name: "CutFlowTests", dependencies: ["CutFlowCore", "CutFlow"])
    ]
)
