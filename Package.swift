// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Macarchy",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ThemeCore", targets: ["ThemeCore"]),
    .executable(name: "macarchy", targets: ["MacarchyCLI"]),
    .executable(
      name: "theme-contract-consumer",
      targets: ["ThemeContractFixtureConsumer"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      exact: "1.8.2"
    ),
    .package(
      url: "https://github.com/dduan/TOMLDecoder",
      exact: "0.4.5"
    ),
    .package(
      url: "https://github.com/swiftlang/swift-testing",
      exact: "6.2.4"
    ),
  ],
  targets: [
    .target(
      name: "ThemeCore",
      dependencies: [
        .product(name: "TOMLDecoder", package: "TOMLDecoder")
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "MacarchyCLI",
      dependencies: [
        "ThemeCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "ThemeContractFixtureConsumer",
      path: "Tests/Fixtures/ThemeContractConsumer",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "ThemeCoreTests",
      dependencies: [
        "ThemeCore",
        .product(name: "Testing", package: "swift-testing"),
      ],
      path: "Tests/ThemeCoreTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "MacarchyCLITests",
      dependencies: [
        "MacarchyCLI",
        "ThemeCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Testing", package: "swift-testing"),
      ],
      path: "Tests/MacarchyCLITests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
