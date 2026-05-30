F-Chat is free software, licensed under the GNU General Public License v3.0.

It incorporates the third-party components below, each under its own license. All are
compatible with redistribution as part of a GPLv3 work.

SWIFT PACKAGES

• EventSource — MIT — © 2025 Mattt
• GRDB.swift — MIT — © 2015–2024 Gwendal Roué
• mlx-swift, mlx-swift-lm — MIT — © Apple Inc.
• SwiftSoup — MIT — © Nabil Chatbi
• ZIPFoundation — MIT — © Thomas Zoechling
• yyjson — MIT — © YaoYuan
• swift-cmark — BSD-2-Clause — © 2014 John MacFarlane (CommonMark)
• swift-asn1, swift-atomics, swift-collections, swift-crypto, swift-nio,
  swift-numerics, swift-syntax, swift-system — Apache-2.0 — © Apple Inc. and the
  Swift project authors
• swift-markdown — Apache-2.0 — © 2021 Apple Inc. and the Swift project authors
• swift-huggingface, swift-jinja, swift-transformers — Apache-2.0 — © Hugging Face

BUNDLED EMBEDDING MODEL

• Qwen3-Embedding-4B (4-bit DWQ, MLX) — Apache-2.0 — base model © Alibaba / the Qwen
  team (Qwen/Qwen3-Embedding-4B); MLX conversion mlx-community/Qwen3-Embedding-4B-4bit-DWQ.

BUNDLED PYTHON RUNTIME

• CPython 3.12.8 via python-build-standalone (Astral) — PSF License Agreement v2
  (GPL-compatible). Bundles OpenSSL, SQLite, zlib, libffi and others, each under its
  own permissive/GPL-compatible license; their texts ship inside the bundled runtime.

VENDORED C

• sqlite-vec v0.1.9 — MIT OR Apache-2.0 — © 2024 Alex Garcia.

TOKENIZER DATA

• OpenAI tiktoken (cl100k_base, o200k_base) — MIT.
• MiniMax tokenizer — used for token-count estimation only.

Full license texts and sources are in the project's LICENSE and THIRD_PARTY_NOTICES.md.
