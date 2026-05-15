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
        .executableTarget(
            name: "Clolid",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
