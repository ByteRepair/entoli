// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "entoli_glass",
  platforms: [
    .iOS("17.0"),
    .macOS("14.0"),
  ],
  products: [
    .library(name: "entoli-glass", targets: ["entoli_glass"])
  ],
  dependencies: [],
  targets: [
    .target(name: "entoli_glass", dependencies: [])
  ]
)
