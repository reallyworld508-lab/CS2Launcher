// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CS2Launcher",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CS2LauncherCore", targets: ["CS2LauncherCore"]),
        .executable(name: "CS2Launcher", targets: ["CS2Launcher"]),
    ],
    targets: [
        .target(name: "CS2LauncherCore",
                resources: [.copy("Resources/steamwebhelper-wrapper.exe")]),
        .executableTarget(name: "CS2Launcher", dependencies: ["CS2LauncherCore"]),
        .testTarget(name: "CoreTests", dependencies: ["CS2LauncherCore"]),
    ],
    swiftLanguageModes: [.v5]
)
