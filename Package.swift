// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "crane-postgres-nio",
    platforms: [
        .macOS(.v10_15)
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
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
