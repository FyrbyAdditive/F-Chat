#!/usr/bin/env bash
# Reassembles the split Qwen3 model.safetensors from its LFS-stored parts
# at vendor/qwen3-safetensors/ into the FyxLocalRAG resource directory at
# Sources/FyxLocalRAG/Resources/Qwen3-Embedding-4B-4bit-DWQ/model.safetensors.
#
# Necessary because the model weights (~2.26 GB) exceed GitHub's 2 GiB
# per-file LFS cap and have to be split. The single assembled blob is
# treated as a build artefact (gitignored) and produced from the parts
# whenever something needs the model. Idempotent: if the assembled file
# already exists and is the expected size it does nothing.
#
# Called automatically by scripts/make-app.sh before the build, and can
# be invoked manually if you want to run `swift test` on the MLX tests
# (which look up the file from Bundle.module / source tree).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARTS_DIR="$ROOT/vendor/qwen3-safetensors"
OUT_DIR="$ROOT/Sources/FyxLocalRAG/Resources/Qwen3-Embedding-4B-4bit-DWQ"
OUT="$OUT_DIR/model.safetensors"
EXPECTED_SIZE=2262632177  # bytes; matches Qwen3-Embedding-4B-4bit-DWQ

# Skip if the file is already assembled and the right size.
if [[ -f "$OUT" ]]; then
    actual=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
    if [[ "$actual" == "$EXPECTED_SIZE" ]]; then
        exit 0
    fi
    echo "==> model.safetensors size mismatch ($actual vs $EXPECTED_SIZE); reassembling"
    rm -f "$OUT"
fi

if [[ ! -d "$PARTS_DIR" ]]; then
    echo "error: parts directory $PARTS_DIR not found." >&2
    echo "       Are LFS objects fetched? Try 'git lfs pull'." >&2
    exit 1
fi

shopt -s nullglob
parts=("$PARTS_DIR"/model.safetensors.part-*)
shopt -u nullglob
if [[ ${#parts[@]} -eq 0 ]]; then
    echo "error: no model.safetensors.part-* files in $PARTS_DIR." >&2
    echo "       Are LFS objects fetched? Try 'git lfs pull'." >&2
    exit 1
fi

# Reject LFS pointers (small text files, ~130 bytes) — they look like
# parts on disk but their content is the pointer, not the bytes.
first_size=$(stat -f%z "${parts[0]}" 2>/dev/null || stat -c%s "${parts[0]}" 2>/dev/null || echo 0)
if [[ "$first_size" -lt 1000000 ]]; then
    echo "error: ${parts[0]} is only $first_size bytes — looks like an LFS pointer." >&2
    echo "       Run 'git lfs pull' to fetch the real binaries." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
echo "==> assembling ${#parts[@]} part(s) into $OUT"
cat "${parts[@]}" >"$OUT"

actual=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
if [[ "$actual" != "$EXPECTED_SIZE" ]]; then
    echo "error: assembled file is $actual bytes; expected $EXPECTED_SIZE." >&2
    rm -f "$OUT"
    exit 1
fi
echo "==> assembled model.safetensors ($actual bytes)"
