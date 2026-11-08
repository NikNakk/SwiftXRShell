// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftXRShell",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "swiftxr-shell", targets: ["SwiftXRShell"])
    ],
    dependencies: [
        // Controller actions and pointer refresh changes are being developed
        // together with the sibling SDK checkout.
        .package(path: "../SwiftXR")
    ],
    targets: [
        .target(
            name: "CVizBridge",
            linkerSettings: [.linkedFramework("IOSurface"), .linkedLibrary("bsm")]
        ),
        .executableTarget(
            name: "SwiftXRShell",
            dependencies: [
                "CVizBridge",
                .product(name: "SwiftXR", package: "SwiftXR")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/usr/local/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/usr/local/lib",
                ], .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("GameController"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "SwiftXRShellTests",
            dependencies: ["SwiftXRShell"],
            linkerSettings: [
                .unsafeFlags([
                    "-L/usr/local/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/usr/local/lib",
                ], .when(platforms: [.macOS])),
            ]
        )
    ]
)
