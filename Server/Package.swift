// swift-tools-version: 6.0
// Laile API + clinician portal (Vapor). Shares all domain logic with the iOS app via LaileCore.
import PackageDescription

let package = Package(
    name: "LaileServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.4.0"),
        .package(url: "https://github.com/vapor/leaf-kit.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(path: "../Packages/LaileCore"),
    ],
    targets: [
        .executableTarget(
            name: "LaileServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "LeafKit", package: "leaf-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "LaileCore", package: "LaileCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LaileServerTests",
            dependencies: [
                .target(name: "LaileServer"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
