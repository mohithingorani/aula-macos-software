// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AulaF75Mac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AulaF75Mac", targets: ["AulaF75Mac"])],
    targets: [
        .executableTarget(name: "AulaF75Mac"),
        .testTarget(name: "AulaF75MacTests", dependencies: ["AulaF75Mac"]),
    ]
)
