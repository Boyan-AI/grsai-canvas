// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "GrsaiCanvas",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GrsaiCanvasApp", targets: ["GrsaiCanvasApp"])
    ],
    targets: [
        .executableTarget(
            name: "GrsaiCanvasApp",
            path: "Sources/GrsaiCanvasApp"
        ),
        .testTarget(
            name: "GrsaiCanvasTests",
            dependencies: ["GrsaiCanvasApp"],
            path: "Tests/GrsaiCanvasTests"
        )
    ]
)
