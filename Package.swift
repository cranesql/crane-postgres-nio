// swift-tools-version:6.2
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "crane-postgres-nio",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "CranePostgresNIO", targets: ["CranePostgresNIO"])
    ],
    traits: [
        .trait(name: "Configuration", description: "Swift Configuration support for CranePostgresNIO.")
    ],
    dependencies: [
        .package(url: "https://github.com/cranesql/crane.git", branch: "main"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CranePostgresNIO",
            dependencies: [
                .product(name: "Crane", package: "crane"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(
                    name: "Configuration",
                    package: "swift-configuration",
                    condition: .when(traits: ["Configuration"])
                ),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "CranePostgresNIOTests",
            dependencies: [
                .target(name: "CranePostgresNIO"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(
                    name: "Configuration",
                    package: "swift-configuration",
                    condition: .when(traits: ["Configuration"])
                ),
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
