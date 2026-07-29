// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "CellularBridge",
  defaultLocalization: "zh-Hans",
  platforms: [
    // The local Homebrew libusb bottle is built for macOS 26. A later
    // distributable build will bundle a libusb dylib with a wider target.
    .macOS(.v26)
  ],
  products: [
    .executable(name: "CellularBridge", targets: ["CellularBridge"])
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
      name: "CellularBridge",
      dependencies: ["CModemBridge"],
      path: "Sources/CellularBridge",
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedFramework("IOKit"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("SystemConfiguration"),
      ]
    ),
    .testTarget(
      name: "CellularBridgeTests",
      dependencies: ["CellularBridge", "CModemBridge"],
      path: "Tests/CellularBridgeTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
