// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Clolid",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Clolid", targets: ["Clolid"])
    ],
    targets: [
        .target(
            name: "ClolidCore"
        ),
        .target(
            name: "ClolidRuntime",
            dependencies: ["ClolidCore"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "Clolid",
            dependencies: ["ClolidCore", "ClolidRuntime"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "ClolidCoreTests",
            dependencies: ["ClolidCore"]
        ),
        .testTarget(
            name: "ClolidRuntimeTests",
            dependencies: ["ClolidCore", "ClolidRuntime"]
        )
    ]
)
