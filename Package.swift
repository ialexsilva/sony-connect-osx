// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonyConnect",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "SonyConnectCore",
            path: "Sources/SonyConnectCore"
        ),
        .executableTarget(
            name: "SonyConnect",
            dependencies: ["SonyConnectCore"],
            path: "Sources/SonyConnect",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "SonyConnectCoreTests",
            dependencies: ["SonyConnectCore"],
            path: "Tests/SonyConnectCoreTests"
        ),
    ]
)
