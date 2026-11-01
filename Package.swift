// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "deskkontrol",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "deskkontrol",
            path: "Sources/deskkontrol",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
