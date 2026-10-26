// swift-tools-version:5.9
import PackageDescription

// SweepCore is plain Foundation so it can be built and unit-tested anywhere.
// The SwiftUI app target only exists on macOS.
var products: [Product] = []
var targets: [Target] = [
    .target(name: "SweepCore", path: "Sources/SweepCore"),
    .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"], path: "Tests/SweepCoreTests"),
]

#if os(macOS)
products.append(.executable(name: "MacSweep", targets: ["MacSweep"]))
targets.append(.executableTarget(name: "MacSweep", dependencies: ["SweepCore"], path: "Sources/MacSweep"))
#endif

let package = Package(
    name: "MacSweep",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
