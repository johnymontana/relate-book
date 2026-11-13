#!/usr/bin/env bash
# Re-copies the graph store exported by wishlist-to-graph into the app's resources.
# Usage: scripts/refresh_store.sh [path/to/books.rl]   (default: ../books.rl, the repo root export)
set -euo pipefail
ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$ios_dir/../books.rl}"
dst="$ios_dir/RelateBooks/Resources/books.rl"
[[ -f "$src" ]] || { echo "refresh_store: $src not found" >&2; exit 1; }
mkdir -p "$(dirname "$dst")"
cp "$src" "$dst.tmp" && mv "$dst.tmp" "$dst"
# The relate CLI: $RELATE_BIN, else `relate` on PATH; the count is skipped without one.
relate_bin="${RELATE_BIN:-$(command -v relate || true)}"
if [[ -n "$relate_bin" && -x "$relate_bin" ]]; then
  # --read-only never writes to the bundle (verified: checksum unchanged)
  echo "refresh_store: $("$relate_bin" query --read-only -d "$dst" --json 'MATCH (b:Book) RETURN count(b) AS books')"
fi
echo "refresh_store: copied $src -> $dst ($(stat -f%z "$dst") bytes)"
