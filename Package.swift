// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoHarbor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhotoHarbor", targets: ["PhotoHarbor"])],
    targets: [
        .executableTarget(name: "PhotoHarbor", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .testTarget(name: "PhotoHarborTests", dependencies: ["PhotoHarbor"], swiftSettings: [.unsafeFlags(["-swift-version", "5"])])
    ]
)
