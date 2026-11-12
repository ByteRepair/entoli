// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "entoli_glass",
  platforms: [
    .iOS("18.0"),
    .macOS("15.0"),
  ],
  products: [
    .library(name: "entoli-glass", targets: ["entoli_glass"])
  ],
  dependencies: [],
  targets: [
    .target(name: "entoli_glass", dependencies: [])
  ]
)
