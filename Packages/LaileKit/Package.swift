// swift-tools-version: 6.0
// LaileKit — the iOS app, split into feature modules. The app target is a thin shell that
// imports AppShell; adding a feature = a new target here + one line in FeatureRegistry.
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LaileKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LaileKit", targets: ["AppShell"]),
    ],
    dependencies: [
        .package(path: "../LaileCore"),
    ],
    targets: [
        .target(name: "DesignSystem", dependencies: ["LaileCore"], swiftSettings: v5),
        .target(name: "AppCore", dependencies: ["LaileCore"], swiftSettings: v5),
        .target(name: "PoseKit", dependencies: ["LaileCore", "DesignSystem"], swiftSettings: v5),
        .target(name: "VoiceKit", dependencies: ["LaileCore"], swiftSettings: v5),
        .target(name: "SessionFeature", dependencies: ["LaileCore", "DesignSystem", "AppCore", "PoseKit", "VoiceKit"], swiftSettings: v5),
        .target(name: "TodayFeature", dependencies: ["LaileCore", "DesignSystem", "AppCore"], swiftSettings: v5),
        .target(name: "StreamsFeature", dependencies: ["LaileCore", "DesignSystem", "AppCore", "PoseKit", "VoiceKit"], swiftSettings: v5),
        .target(name: "ProgressFeature", dependencies: ["LaileCore", "DesignSystem", "AppCore"], swiftSettings: v5),
        .target(name: "ProfileFeature", dependencies: ["LaileCore", "DesignSystem", "AppCore"], swiftSettings: v5),
        .target(
            name: "AppShell",
            dependencies: ["LaileCore", "DesignSystem", "AppCore", "SessionFeature", "TodayFeature", "StreamsFeature", "ProgressFeature", "ProfileFeature"],
            swiftSettings: v5
        ),
    ]
)
