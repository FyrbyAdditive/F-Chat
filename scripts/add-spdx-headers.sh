#!/usr/bin/env bash
# Stamp an SPDX + copyright header onto every first-party Swift source file.
#
# Idempotent: files that already carry an SPDX-License-Identifier line are left
# untouched. Vendored third-party code (CSQLiteVec, vendor/, .build/) is excluded
# — it keeps its own upstream license and must never be stamped GPL.
#
# Usage: ./scripts/add-spdx-headers.sh [--check]
#   (no args)  stamp missing headers in place
#   --check    exit non-zero if any first-party Swift file is missing the header
set -euo pipefail

cd "$(dirname "$0")/.."

HEADER_LINE1="// SPDX-License-Identifier: GPL-3.0-or-later"
HEADER_LINE2="// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering"

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

missing=0
stamped=0
total=0

# First-party Swift only: Sources/ and Tests/, excluding vendored C package dir.
# Portable (no mapfile) for the macOS system bash 3.2.
while IFS= read -r f; do
    total=$((total+1))
    if grep -q "SPDX-License-Identifier" "$f"; then
        continue
    fi
    if $check_only; then
        echo "MISSING SPDX: $f"
        missing=$((missing+1))
        continue
    fi
    # Prepend the two-line header plus a blank line, preserving file contents.
    tmp="$(mktemp)"
    { printf '%s\n%s\n\n' "$HEADER_LINE1" "$HEADER_LINE2"; cat "$f"; } > "$tmp"
    mv "$tmp" "$f"
    stamped=$((stamped+1))
done < <(find Sources Tests -name '*.swift' -not -path 'Sources/CSQLiteVec/*' | sort)

if $check_only; then
    if [[ $missing -gt 0 ]]; then
        echo "FAIL: $missing file(s) missing SPDX header"
        exit 1
    fi
    echo "OK: all $total first-party Swift files carry an SPDX header"
else
    echo "stamped $stamped file(s); $total total first-party Swift files"
fi
