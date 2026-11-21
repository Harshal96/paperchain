// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .executable(name: "chain-sim", targets: ["ChainSimulation"])
]
var targets: [Target] = [
    .target(name: "ChainCore"),
    .target(name: "Decisions"),
    .executableTarget(name: "ChainSimulation", dependencies: ["ChainCore"]),
    .executableTarget(name: "WorkspaceChecks", dependencies: ["ChainCore"], path: "Tests/WorkspaceChecks"),
    .executableTarget(name: "LayoutChecks", dependencies: ["ChainCore"], path: "Tests/LayoutChecks"),
    .executableTarget(name: "JournalChecks", dependencies: ["ChainCore"], path: "Tests/JournalChecks"),
    .executableTarget(name: "DecisionsChecks", dependencies: ["Decisions", "ChainCore"], path: "Tests/DecisionsChecks"),
]
#if os(macOS)
products.append(.executable(name: "PaperChain", targets: ["PaperChainMac"]))
targets.append(.target(name: "NativeAXMetadata"))
targets.append(.executableTarget(name: "PaperChainMac", dependencies: ["ChainCore", "Decisions", "NativeAXMetadata"]))
targets.append(.executableTarget(name: "NativeMetadataChecks", dependencies: ["NativeAXMetadata"], path: "Tests/NativeMetadataChecks"))
#endif

let package = Package(name: "PaperChain", platforms: [.macOS(.v14)], products: products, targets: targets)
