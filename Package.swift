// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "F-Chat",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FChat", targets: ["FChatApp"]),
        .library(name: "FChatCore", targets: ["FChatCore"]),
        .library(name: "FChatProviders", targets: ["FChatProviders"]),
        .library(name: "FChatWeb", targets: ["FChatWeb"]),
        .library(name: "FChatTools", targets: ["FChatTools"]),
        .library(name: "FChatMCP", targets: ["FChatMCP"]),
        .library(name: "FChatRAG", targets: ["FChatRAG"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "FChatCore",
            resources: [
                .copy("Tokenization/Resources/cl100k_base.tiktoken"),
                .copy("Tokenization/Resources/o200k_base.tiktoken"),
                .copy("Tokenization/Resources/minimax-m2.7.json"),
            ]
        ),
        .target(
            name: "FChatProviders",
            dependencies: ["FChatCore"]
        ),
        .target(
            name: "FChatWeb",
            dependencies: [
                "FChatCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [.copy("Resources/Readability.js")]
        ),
        .target(
            name: "FChatTools",
            dependencies: ["FChatCore", "FChatProviders", "FChatWeb"]
        ),
        .target(
            name: "FChatMCP",
            dependencies: ["FChatCore", "FChatProviders", "FChatTools"]
        ),
        .target(
            name: "FChatRAG",
            dependencies: ["FChatCore", "FChatProviders", "FChatTools"]
        ),
        .executableTarget(
            name: "FChatApp",
            dependencies: [
                "FChatCore",
                "FChatProviders",
                "FChatWeb",
                "FChatTools",
                "FChatMCP",
                "FChatRAG",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FChatCoreTests",
            dependencies: ["FChatCore"]
        ),
        .testTarget(
            name: "FChatProvidersTests",
            dependencies: ["FChatProviders"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FChatWebTests",
            dependencies: ["FChatWeb"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FChatToolsTests",
            dependencies: ["FChatTools"]
        ),
        .testTarget(
            name: "FChatMCPTests",
            dependencies: ["FChatMCP"]
        ),
        .testTarget(
            name: "FChatRAGTests",
            dependencies: ["FChatRAG"],
            resources: [.process("Fixtures")]
        ),
    ]
)
