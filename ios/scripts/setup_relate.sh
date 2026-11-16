#!/usr/bin/env bash
# Puts the Relate commit the app is pinned to in ios/Vendor/relate (git-ignored) and builds its
# RelateFFI.xcframework there. The app depends on that directory by path until a Relate release
# carries the Swift API it uses (ADR-0596); see "Requirements" in ios/README.md.
#
# Usage: scripts/setup_relate.sh [all|macos]
#   all    every slice: `swift test`, the simulator and a device (about 15 minutes, 5 GB while building)
#   macos  the macOS slice only: enough for `swift test` (a few minutes)
#
# Needs rustup. The build runs with the Rust toolchain Relate pins (rust-toolchain.toml in the
# snapshot) and names any target that toolchain is missing (`rustup target add ...`).
# Every swift and xcodebuild command afterwards needs RELATE_LOCAL_XCFRAMEWORK=1 in its environment.
#
# Env:
#   RELATE_REV                 the commit to fetch (default: the pin below)
#   RELATE_KEEP_INTERMEDIATES  set to keep cargo's per-target output (faster rebuilds, about 5 GB)
set -euo pipefail

# The pin. Change it only as a deliberate upgrade: re-run every suite (AGENTS.md).
PINNED_REV="af8c2e4b0b85a27cdaf8908fa85164ea8e5b2bd7"

rev="${RELATE_REV:-$PINNED_REV}"
slices="${1:-all}"
case "$slices" in
  all | macos) ;;
  *) echo "usage: $0 [all|macos]" >&2; exit 2 ;;
esac

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
dest="$ios_dir/Vendor/relate"
source_stamp="$dest/.relate-rev"
build_stamp="$dest/target/apple/.built"

if [[ "$(cat "$source_stamp" 2>/dev/null || true)" != "$rev" ]]; then
  echo "setup_relate: fetching relatedb/relate at $rev"
  # A source snapshot, not a clone: no nested repository, and the build needs no git metadata.
  fresh="$dest.fetching"
  rm -rf "$fresh"
  mkdir -p "$fresh"
  curl -sSfL "https://codeload.github.com/relatedb/relate/tar.gz/$rev" | tar -xz --strip-components 1 -C "$fresh"
  # Keep an existing cargo cache: it is keyed on the sources, so stale units rebuild.
  if [[ -d "$dest/target" ]]; then mv "$dest/target" "$fresh/target"; fi
  rm -rf "$dest"
  mv "$fresh" "$dest"
  rm -f "$build_stamp"
  echo "$rev" >"$source_stamp"
fi

built="$(cat "$build_stamp" 2>/dev/null || true)"
if [[ "$built" == "$rev all" || "$built" == "$rev $slices" ]]; then
  echo "setup_relate: $dest/target/apple/RelateFFI.xcframework is current ($built)"
else
  echo "setup_relate: building RelateFFI.xcframework ($slices)"
  # From inside the snapshot, so rustup picks the toolchain its rust-toolchain.toml pins.
  (cd "$dest" && scripts/build-xcframework.sh --slices "$slices")
  echo "$rev $slices" >"$build_stamp"
  if [[ -z "${RELATE_KEEP_INTERMEDIATES:-}" ]]; then
    rm -rf "$dest"/target/aarch64-apple-* "$dest"/target/x86_64-apple-* "$dest"/target/release
  fi
fi

echo "setup_relate: ready. Use RELATE_LOCAL_XCFRAMEWORK=1 with swift and xcodebuild."
