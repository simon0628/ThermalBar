// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThermalBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ThermalBar",
            path: "Sources/ThermalBar",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
