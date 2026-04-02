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
    dependencies: [
        .package(url: "https://github.com/cranesql/crane.git", branch: "main"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "CranePostgresNIO",
            dependencies: [
                .product(name: "Crane", package: "crane"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "CranePostgresNIOTests",
            dependencies: [
                .target(name: "CranePostgresNIO"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
