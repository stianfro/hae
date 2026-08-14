// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Hae",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "HaeCore", targets: ["HaeCore"]),
    .executable(name: "HaeApplication", targets: ["HaeApplication"]),
  ],
  targets: [
    .target(
      name: "HaeCore",
      path: "Hae/Core",
      resources: [.process("Models/ModelManifest.json")],
      linkerSettings: [
        .linkedFramework("Accelerate"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("ScreenCaptureKit"),
      ]
    ),
    .testTarget(
      name: "HaeCoreTests",
      dependencies: ["HaeCore"],
      path: "Tests/Unit"
    ),
    .executableTarget(
      name: "HaeApplication",
      dependencies: ["HaeCore"],
      path: "Hae",
      exclude: [
        "Core", "Resources", "Info.plist", "Hae.entitlements",
      ],
      sources: ["App", "Features"],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
  ]
)
