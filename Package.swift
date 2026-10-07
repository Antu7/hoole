// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hoole",
    platforms: [.macOS(.v14)],
    targets: [
        // Speech engine: Vendor/libneedle.dylib + Vendor/needle.h, fetched by scripts/build.sh
        .systemLibrary(name: "CEngine", path: "Sources/CEngine"),
        .executableTarget(
            name: "Hoole",
            dependencies: ["CEngine"],
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/Vendor", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
