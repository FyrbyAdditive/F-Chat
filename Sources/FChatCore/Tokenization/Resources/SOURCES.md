# Tokenizer resource provenance

These files are bundled for offline token-count estimation. They are data tables, not
executable code.

| File | Source | License |
|---|---|---|
| `cl100k_base.tiktoken` | OpenAI tiktoken — <https://github.com/openai/tiktoken> | MIT |
| `o200k_base.tiktoken` | OpenAI tiktoken — <https://github.com/openai/tiktoken> | MIT |
| `minimax-m2.7.json` | MiniMax model tokenizer (from the MiniMax model distribution) | Used for token-count estimation only |

The `.tiktoken` files are byte-pair-encoding rank tables in OpenAI's
`base64(token_bytes) rank` line format; they are parsed by `BPETokenizer.swift`. See the
project-level [THIRD_PARTY_NOTICES.md](../../../../THIRD_PARTY_NOTICES.md) for the full
attribution list.
