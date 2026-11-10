// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FaceUnlock", targets: ["FaceUnlockApp"]),
        .executable(name: "FaceUnlockDiagnostics", targets: ["FaceUnlockDiagnostics"]),
        .executable(name: "FaceRecognitionDiagnostics", targets: ["FaceRecognitionDiagnostics"])
    ],
    targets: [
        .target(name: "FaceUnlockCore"),
        .target(name: "FaceUnlockMac", dependencies: ["FaceUnlockCore"]),
        .target(name: "FaceUnlockRecognition", dependencies: ["FaceUnlockCore"]),
        .executableTarget(
            name: "FaceUnlockApp",
            dependencies: ["FaceUnlockCore", "FaceUnlockMac", "FaceUnlockRecognition"]
        ),
        .executableTarget(
            name: "FaceUnlockDiagnostics",
            dependencies: ["FaceUnlockCore", "FaceUnlockMac"]
        ),
        .executableTarget(name: "FaceRecognitionDiagnostics", dependencies: ["FaceUnlockRecognition"]),
        .testTarget(
            name: "FaceUnlockCoreTests",
            dependencies: ["FaceUnlockCore", "FaceUnlockMac", "FaceUnlockRecognition", "FaceUnlockApp"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
