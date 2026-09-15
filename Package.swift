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
        .package(
            url: "https://github.com/NikNakk/SwiftXR.git",
            branch: "swiftxr-video-player-poc"
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftXRShell",
            dependencies: [
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
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit")
            ]
        )
    ]
)
