// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "DJIO",
  defaultLocalization: "zh-Hans",
  platforms: [
    // The local Homebrew libusb bottle is built for macOS 26. A later
    // distributable build will bundle a libusb dylib with a wider target.
    .macOS(.v26)
  ],
  products: [
    .executable(name: "DJIO", targets: ["DJIO"])
  ],
  targets: [
    .systemLibrary(
      name: "CLibusb",
      path: "Sources/CLibusb",
      pkgConfig: "libusb-1.0",
      providers: [
        .brew(["libusb", "pkgconf"])
      ]
    ),
    .target(
      name: "CModemBridge",
      dependencies: ["CLibusb"],
      path: "Sources/CModemBridge",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "DJIO",
      dependencies: ["CModemBridge"],
      path: "Sources/DJIO",
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedFramework("IOKit"),
        .linkedFramework("ImageIO"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("Vision"),
      ]
    ),
    .testTarget(
      name: "DJIOTests",
      dependencies: ["DJIO", "CModemBridge"],
      path: "Tests/DJIOTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
