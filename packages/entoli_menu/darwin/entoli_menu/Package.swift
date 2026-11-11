// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "entoli_menu",
  platforms: [
    .iOS("17.0"),
    .macOS("14.0"),
  ],
  products: [
    .library(name: "entoli-menu", targets: ["entoli_menu"])
  ],
  dependencies: [],
  targets: [
    .target(name: "entoli_menu", dependencies: [])
  ]
)
