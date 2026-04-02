// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcualr",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "xcualr", targets: ["XCUALR"])
    ],
    targets: [
        .executableTarget(
            name: "XCUALR",
            path: "Sources/XCUALR"
        )
    ]
)
