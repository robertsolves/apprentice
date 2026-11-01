// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "deskkontrol",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "deskkontrol", targets: ["deskkontrol"])
    ],
    targets: [
        .executableTarget(
            name: "deskkontrol",
            path: "Sources/deskkontrol",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
            ]
        )
    ]
)
