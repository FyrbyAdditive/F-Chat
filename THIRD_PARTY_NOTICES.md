# Third-Party Notices

F-Chat is licensed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)).
It incorporates and/or bundles the third-party components listed below. Each is used
under its own license; those licenses are preserved here as required. All listed
licenses are compatible with redistribution as part of a GPLv3 work.

---

## Swift packages (Swift Package Manager dependencies)

Resolved versions are pinned in [`Package.resolved`](Package.resolved). Apache-2.0
packages are used under the Apache License 2.0 (some Apple packages additionally carry
the Swift runtime-library exception). MIT and BSD packages are used under their
respective licenses; the original copyright notices are preserved.

| Package | Source | Version | License |
|---|---|---|---|
| EventSource | https://github.com/mattt/EventSource | 1.4.1 | MIT — © 2025 Mattt |
| GRDB.swift | https://github.com/groue/GRDB.swift | 6.29.3 | MIT — © 2015–2024 Gwendal Roué |
| mlx-swift | https://github.com/ml-explore/mlx-swift | 0.31.3 | MIT — © Apple Inc. |
| mlx-swift-lm | https://github.com/ml-explore/mlx-swift-lm | 3.31.3 | MIT — © Apple Inc. |
| SwiftSoup | https://github.com/scinfu/SwiftSoup | 2.13.5 | MIT — © Nabil Chatbi |
| ZIPFoundation | https://github.com/weichsel/ZIPFoundation | 0.9.20 | MIT — © Thomas Zoechling |
| yyjson | https://github.com/ibireme/yyjson | 0.12.0 | MIT — © YaoYuan |
| swift-asn1 | https://github.com/apple/swift-asn1 | 1.7.0 | Apache-2.0 — © Apple Inc. and the Swift project authors |
| swift-atomics | https://github.com/apple/swift-atomics | 1.3.0 | Apache-2.0 (runtime exception) — © Apple Inc. and the Swift project authors |
| swift-cmark | https://github.com/swiftlang/swift-cmark | 0.8.0 | BSD-2-Clause — © 2014 John MacFarlane (CommonMark) |
| swift-collections | https://github.com/apple/swift-collections | 1.5.1 | Apache-2.0 (runtime exception) — © Apple Inc. and the Swift project authors |
| swift-crypto | https://github.com/apple/swift-crypto | 4.5.0 | Apache-2.0 — © Apple Inc. and the Swift project authors |
| swift-huggingface | https://github.com/huggingface/swift-huggingface | 0.9.0 | Apache-2.0 — © Hugging Face |
| swift-jinja | https://github.com/huggingface/swift-jinja | 2.3.6 | Apache-2.0 — © Hugging Face |
| swift-markdown | https://github.com/swiftlang/swift-markdown | 0.8.0 | Apache-2.0 — © 2021 Apple Inc. and the Swift project authors |
| swift-nio | https://github.com/apple/swift-nio | 2.100.0 | Apache-2.0 — © Apple Inc. and the SwiftNIO project authors |
| swift-numerics | https://github.com/apple/swift-numerics | 1.1.1 | Apache-2.0 (runtime exception) — © Apple Inc. and the Swift Numerics project authors |
| swift-syntax | https://github.com/swiftlang/swift-syntax | 600.0.1 | Apache-2.0 (runtime exception) — © Apple Inc. and the Swift project authors |
| swift-system | https://github.com/apple/swift-system | 1.6.4 | Apache-2.0 (runtime exception) — © Apple Inc. and the Swift System project authors |
| swift-transformers | https://github.com/huggingface/swift-transformers | 1.3.3 | Apache-2.0 — © Hugging Face |

The Apache License 2.0 and MIT License full texts are available at
<https://www.apache.org/licenses/LICENSE-2.0> and <https://opensource.org/licenses/MIT>.

`swift-markdown` ships a NOTICE referencing Swift Argument Parser, swift-cmark, and the
CommonMark spec; that NOTICE is preserved in the package and reproduced upstream at
<https://github.com/apple/swift-markdown/blob/main/NOTICE.txt>.

---

## Bundled embedding model

**Qwen3-Embedding-4B (4-bit DWQ, MLX conversion)** — used on-device for RAG embeddings.

- Distribution: `mlx-community/Qwen3-Embedding-4B-4bit-DWQ`
  (<https://huggingface.co/mlx-community/Qwen3-Embedding-4B-4bit-DWQ>)
- Base model: `Qwen/Qwen3-Embedding-4B` by Alibaba / the Qwen team
  (<https://huggingface.co/Qwen/Qwen3-Embedding-4B>)
- License: **Apache-2.0** (per the model card).

The model weights are vendored into this repository via Git-LFS
(`vendor/qwen3-safetensors/`) and reassembled at build time. The tokenizer and config
files ship under `Sources/FChatRAG/Resources/Qwen3-Embedding-4B-4bit-DWQ/`.

---

## Vendored runtime: CPython

A relocatable CPython is fetched at build time (not committed to this repository) and
bundled into the shipped application so Agent Skills can run Python without a system
interpreter.

- Distribution: `python-build-standalone` by Astral
  (<https://github.com/astral-sh/python-build-standalone>), CPython **3.12.8**, tag `20250115`.
- CPython license: **PSF License Agreement v2** (Python Software Foundation). The PSF
  license is GPL-compatible (the PSF license text states this explicitly).
- The standalone distribution bundles common libraries — OpenSSL, SQLite, zlib, libffi,
  bzip2, xz, ncurses, etc. — each under its own permissive/GPL-compatible license. Their
  texts are included with the CPython distribution under
  `Contents/Resources/python3/lib/python3.12/` in the built app, and upstream at the
  python-build-standalone project.

---

## Vendored C: sqlite-vec

**sqlite-vec** v0.1.9 (<https://github.com/asg017/sqlite-vec>) © 2024 Alex Garcia —
a vector-search extension to SQLite, vendored as a source amalgamation under
[`Sources/CSQLiteVec/`](Sources/CSQLiteVec/). Dual-licensed **MIT OR Apache-2.0**; both
upstream license texts are preserved in [`Sources/CSQLiteVec/LICENSE`](Sources/CSQLiteVec/LICENSE).

---

## Tokenizer data

Bundled under `Sources/FChatCore/Tokenization/Resources/` for offline token counting;
see [`Sources/FChatCore/Tokenization/Resources/SOURCES.md`](Sources/FChatCore/Tokenization/Resources/SOURCES.md).

- `cl100k_base.tiktoken`, `o200k_base.tiktoken` — OpenAI tiktoken BPE rank tables
  (<https://github.com/openai/tiktoken>), MIT.
- `minimax-m2.7.json` — MiniMax tokenizer vocabulary, from the MiniMax model
  distribution; used for token-count estimation only.

---

## Web asset: Mozilla Readability (not currently bundled)

`Sources/FChatWeb/Resources/Readability.js` is a **placeholder stub** — the real
Mozilla Readability library (<https://github.com/mozilla/readability>, Apache-2.0) is
**not shipped** with F-Chat. If it is bundled in the future, its Apache-2.0 notice must
be added here.
