// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FaceUnlock", targets: ["FaceUnlockApp"])
    ],
    targets: [
        .target(name: "FaceUnlockCore"),
        .target(name: "FaceUnlockMac", dependencies: ["FaceUnlockCore"]),
        .executableTarget(
            name: "FaceUnlockApp",
            dependencies: ["FaceUnlockCore", "FaceUnlockMac"]
        ),
        .testTarget(
            name: "FaceUnlockCoreTests",
            dependencies: ["FaceUnlockCore", "FaceUnlockMac"]
        )
    ],
    swiftLanguageModes: [.v6]
)
