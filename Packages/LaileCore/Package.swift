// swift-tools-version: 6.0
// LaileCore — platform-independent domain logic shared by the iOS app and the Vapor server.
// Pure Swift + Foundation only, so it builds on iOS, macOS and Linux.
import PackageDescription

let package = Package(
    name: "LaileCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LaileCore", targets: ["LaileCore"]),
    ],
    targets: [
        .target(name: "LaileCore"),
        .testTarget(name: "LaileCoreTests", dependencies: ["LaileCore"]),
    ]
)
