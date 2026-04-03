// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Indigo3",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSyphon",
            path: "Sources/CSyphon",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("GL_SILENCE_DEPRECATION"),
                .unsafeFlags(["-fmodules", "-fcxx-modules", "-Wno-deprecated-declarations", "-include", "SyphonPrefix.h"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("OpenGL"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "CNDI",
            path: "Sources/CNDI",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/Library/NDI SDK for Apple/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/Library/NDI SDK for Apple/lib/macOS", "-lndi", "-Xlinker", "-rpath", "-Xlinker", "/Library/NDI SDK for Apple/lib/macOS"])
            ]
        ),
        .executableTarget(
            name: "Indigo3",
            dependencies: ["CSyphon", "CNDI"],
            path: "Sources/Indigo3"
        )
    ]
)
