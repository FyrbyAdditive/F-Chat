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
        // On-device embeddings (Qwen3-Embedding-4B on Apple Silicon via MLX).
        // Model weights are vendored into the app bundle under
        // Sources/FChatRAG/Resources/Qwen3-Embedding-4B-4bit-DWQ — no
        // Hugging Face download at runtime. We still need swift-transformers
        // for the tokenizer loader macros (#huggingFaceTokenizerLoader).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0"),
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
                "FChatWeb",
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                // Tokenizer macros expand to Tokenizers.AutoTokenizer.from(...)
                // at the call site, so this module must be on the FChatRAG
                // dep list even though we never name it directly in code.
                .product(name: "Tokenizers", package: "swift-transformers"),
                // ZIP reader for DOCX/PPTX (Office Open XML are ZIP archives).
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            // Bundle the Qwen3-Embedding-4B-4bit-DWQ model weights so the
            // app is self-contained — no first-run Hugging Face download.
            // Adds ~2.1 GB to the app bundle. Tracked via git-lfs at the
            // repo level so checkouts pull binaries from LFS, not bloat
            // the main git history.
            resources: [
                .copy("Resources/Qwen3-Embedding-4B-4bit-DWQ"),
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
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FChatAppTests",
            dependencies: ["FChatApp"]
        ),
    ]
)
