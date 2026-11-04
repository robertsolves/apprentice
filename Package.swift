// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "apprentice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apprentice", targets: ["apprentice"])
    ],
    targets: [
        .executableTarget(
            name: "apprentice",
            path: "Sources/apprentice",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
