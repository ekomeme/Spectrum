// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spectrum",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Spectrum",
            path: "Sources/Spectrum",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("Accelerate"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
