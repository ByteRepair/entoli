// swift-tools-version: 6.0
// EntoliMLX: mlx-swift-lm behind a three-call API, built by build.sh into
// the XCFramework both Runners link. See "The MLX models" in ios/AGENTS.md.
import PackageDescription

let package = Package(
  name: "EntoliMLX",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "EntoliMLX", type: .dynamic, targets: ["EntoliMLX"]),
  ],
  dependencies: [
    // Exact pins, Package.resolved committed beside them: the macro these
    // carry is built with its validation skipped, so what runs is only ever
    // the code a person chose by bumping the number.
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"),
  ],
  targets: [
    .target(
      name: "EntoliMLX",
      dependencies: [
        .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      swiftSettings: [
        // A module interface that names nothing of MLX's, so the Runners
        // import this one module and none of the packages behind it.
        .unsafeFlags(["-enable-library-evolution", "-emit-module-interface"]),
        .swiftLanguageMode(.v5),
      ],
      linkerSettings: [
        // The framework loads on every OS the app runs on; the system
        // framework is 26's, and the model behind it 27's.
        .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
      ]),
  ]
)
