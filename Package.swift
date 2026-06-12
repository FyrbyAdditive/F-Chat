// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FyxLocal",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FyxLocal", targets: ["FyxLocalApp"]),
        .library(name: "FyxLocalCore", targets: ["FyxLocalCore"]),
        .library(name: "FyxLocalProviders", targets: ["FyxLocalProviders"]),
        .library(name: "FyxLocalWeb", targets: ["FyxLocalWeb"]),
        .library(name: "FyxLocalTools", targets: ["FyxLocalTools"]),
        .library(name: "FyxLocalMCP", targets: ["FyxLocalMCP"]),
        .library(name: "FyxLocalRAG", targets: ["FyxLocalRAG"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // On-device embeddings + reranking (Qwen3 0.6B models on Apple Silicon
        // via MLX). Model weights are vendored into the app bundle under
        // Sources/FyxLocalRAG/Resources/ — no Hugging Face download at runtime.
        // We still need swift-transformers for the tokenizer loader macros
        // (#huggingFaceTokenizerLoader).
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
            name: "FyxLocalCore",
            dependencies: [
                // ZIP reader for importing `.zip`-packaged Agent Skills.
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                // CommonMark+GFM parser for the high-fidelity .docx export
                // (markdown → real Word formatting). Same package the app
                // target already pins for transcript rendering.
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [
                .copy("Tokenization/Resources/cl100k_base.tiktoken"),
                .copy("Tokenization/Resources/o200k_base.tiktoken"),
                .copy("Tokenization/Resources/minimax-m2.7.json"),
                // Model-facing prompt strings (system prompt, tool descriptions,
                // temporal text) in en/sv/da. `.process` compiles the catalog to
                // per-locale .lproj/.strings so PromptStrings can resolve them.
                .process("Resources/Prompts.xcstrings"),
            ]
        ),
        .target(
            name: "FyxLocalProviders",
            dependencies: ["FyxLocalCore"]
        ),
        .target(
            name: "FyxLocalWeb",
            dependencies: [
                "FyxLocalCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [.copy("Resources/Readability.js")]
        ),
        .target(
            name: "FyxLocalTools",
            dependencies: ["FyxLocalCore", "FyxLocalProviders", "FyxLocalWeb"]
        ),
        .target(
            name: "FyxLocalMCP",
            dependencies: ["FyxLocalCore", "FyxLocalProviders", "FyxLocalTools"]
        ),
        .target(
            name: "FyxLocalRAG",
            dependencies: [
                "FyxLocalCore",
                "FyxLocalProviders",
                "FyxLocalTools",
                "FyxLocalWeb",
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                // Causal-LM path for the reranker: Qwen3-Reranker is a
                // Qwen3ForCausalLM scored by the yes/no token logits.
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // Tokenizer macros expand to Tokenizers.AutoTokenizer.from(...)
                // at the call site, so this module must be on the FyxLocalRAG
                // dep list even though we never name it directly in code.
                .product(name: "Tokenizers", package: "swift-transformers"),
                // ZIP reader for DOCX/PPTX (Office Open XML are ZIP archives).
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            // Bundle the Qwen3-Embedding-0.6B-MLX-8bit embedder (~633 MB) and the
            // Qwen3-Reranker-0.6B-mxfp8 reranker (~614 MB) so the app is
            // self-contained — no first-run Hugging Face download. Tracked via
            // git-lfs so checkouts pull binaries from LFS, not the main history.
            resources: [
                .copy("Resources/Qwen3-Embedding-0.6B-MLX-8bit"),
                .copy("Resources/Qwen3-Reranker-0.6B-mxfp8"),
            ]
        ),
        .executableTarget(
            name: "FyxLocalApp",
            dependencies: [
                "FyxLocalCore",
                "FyxLocalProviders",
                "FyxLocalWeb",
                "FyxLocalTools",
                "FyxLocalMCP",
                "FyxLocalRAG",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FyxLocalCoreTests",
            dependencies: [
                "FyxLocalCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "FyxLocalProvidersTests",
            dependencies: ["FyxLocalProviders"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FyxLocalWebTests",
            dependencies: ["FyxLocalWeb"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FyxLocalToolsTests",
            dependencies: ["FyxLocalTools"]
        ),
        .testTarget(
            name: "FyxLocalMCPTests",
            dependencies: ["FyxLocalMCP"]
        ),
        .testTarget(
            name: "FyxLocalRAGTests",
            dependencies: [
                "FyxLocalRAG",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FyxLocalAppTests",
            dependencies: ["FyxLocalApp"]
        ),
    ]
)
