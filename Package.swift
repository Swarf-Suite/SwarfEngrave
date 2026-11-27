// swift-tools-version: 6.2
import PackageDescription

// The engine comes from SwarfPath's `CAMCore` library product for now (roadmap Phase 1 moves it into a shared
// package). SwarfPath must be checked out beside this repo: ../SwarfPath.
let package = Package(
    name: "SwarfEngrave",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EngraveCore", targets: ["EngraveCore"]),
        .executable(name: "SwarfEngrave", targets: ["SwarfEngraveApp"]),
        .executable(name: "swarfengrave-cli", targets: ["swarfengrave-cli"]),
    ],
    dependencies: [
        .package(name: "SwarfPath", path: "../SwarfPath"),
    ],
    targets: [
        .target(
            name: "EngraveCore",
            dependencies: [.product(name: "CAMCore", package: "SwarfPath")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SwarfEngraveApp",
            dependencies: ["EngraveCore", .product(name: "CAMCore", package: "SwarfPath")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "swarfengrave-cli",
            dependencies: ["EngraveCore", .product(name: "CAMCore", package: "SwarfPath")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "EngraveCoreTests", dependencies: ["EngraveCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
