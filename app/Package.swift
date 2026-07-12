// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SKNoteTaker",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "SKNoteCore", targets: ["SKNoteCore"]),
        .executable(name: "SKNoteTaker", targets: ["SKNoteTakerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        .target(
            name: "SKNoteCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "SKNoteTakerApp",
            dependencies: ["SKNoteCore"]
        ),
        .testTarget(
            name: "SKNoteCoreTests",
            dependencies: ["SKNoteCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
