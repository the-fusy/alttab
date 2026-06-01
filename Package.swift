// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AltTab",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AltTab",
            path: "Sources/AltTab",
            // AppKit and Carbon are system frameworks auto-linked by `import`.
            // We compile in Swift 5 language mode so Swift 6 strict concurrency
            // does not turn ordinary main-thread AppKit/Carbon code into build errors.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            // SkyLight is a private system framework: not on the default search path,
            // so we add the PrivateFrameworks dir and link it explicitly.
            // This emits a real LC_LOAD_DYLIB to
            // /System/Library/PrivateFrameworks/SkyLight.framework (verified via otool -L).
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "SkyLight",
                    // Embed Info.plist into the Mach-O (__TEXT,__info_plist). Xcode does this for app
                    // targets; a plain SwiftPM executable does not, and without it LaunchServices
                    // refuses to launch the assembled .app (launchd error 125, not Gatekeeper). Path
                    // is relative to the package root (the `swift build` working directory).
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
