// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sapling",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sapling", targets: ["sapling"]),
        .executable(name: "SaplingMenuBar", targets: ["SaplingMenuBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "SaplingCore", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .target(
            name: "SaplingDB",
            dependencies: [
                "SaplingCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]),
        .target(name: "SaplingAgent", dependencies: ["SaplingCore", "SaplingDB"]),
        .target(
            name: "SaplingAPI",
            dependencies: [
                "SaplingCore", "SaplingDB", "SaplingAgent",
                .product(name: "Vapor", package: "vapor"),
            ]),
        .target(name: "SaplingInstall", dependencies: ["SaplingCore", "SaplingAgent"]),
        .executableTarget(
            name: "sapling",
            dependencies: [
                "SaplingCore", "SaplingDB", "SaplingAgent", "SaplingAPI", "SaplingInstall",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(name: "SaplingMenuBar", dependencies: ["SaplingCore"]),
        .testTarget(
            name: "SaplingTests",
            dependencies: ["SaplingCore", "SaplingDB", "SaplingAgent", "SaplingAPI", "SaplingInstall"]),
    ]
)
