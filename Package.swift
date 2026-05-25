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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        // Vendored sqlite-vec v0.1.9 amalgamation. Built with SQLITE_CORE so
        // it uses the standard sqlite3.h (provided by GRDB / system SQLite)
        // rather than the runtime-loadable extension API.
        .target(
            name: "CSQLiteVec",
            path: "Sources/CSQLiteVec",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .headerSearchPath("include"),
                // GRDB's bundled SQLite supplies sqlite3.h via its umbrella;
                // when CSQLiteVec is linked into the same binary the symbol
                // resolution works at link time. For header lookup we point
                // at the GRDB-vended sqlite3.h via the system include path
                // the toolchain provides through the SDK.
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
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
            dependencies: [
                "FChatCore",
                "FChatProviders",
                "FChatTools",
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
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
            dependencies: [
                "FChatRAG",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FChatAppTests",
            dependencies: ["FChatApp"]
        ),
    ]
)
