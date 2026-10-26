// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioRecord",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioRecordCore", targets: ["AudioRecordCore"]),
        .executable(name: "audiorecord", targets: ["AudioRecordCLI"]),
        .executable(name: "AudioRecordApp", targets: ["AudioRecordApp"]),
        .executable(name: "audiorecord-selftest", targets: ["AudioRecordSelfTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(
            name: "AudioRecordCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/AudioRecordCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioRecordCLI",
            dependencies: ["AudioRecordCore"],
            path: "Sources/AudioRecordCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioRecordApp",
            dependencies: ["AudioRecordCore"],
            path: "Sources/AudioRecordApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Command Line Tools ship neither XCTest nor swift-testing, so unit tests are a plain executable.
        .executableTarget(
            name: "AudioRecordSelfTest",
            dependencies: ["AudioRecordCore"],
            path: "Sources/AudioRecordSelfTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
