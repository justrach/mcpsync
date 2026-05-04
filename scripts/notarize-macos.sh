#!/usr/bin/env bash
# Codesign + notarize a macOS mcpsync binary locally using a notarytool keychain
# profile. Produces a signed binary, a notarized tar.gz, and a .sha256 sidecar.
#
# Usage:
#   scripts/notarize-macos.sh <path-to-mcpsync-binary> [arch-tag]
#
# arch-tag: arm64 | x86_64 (inferred via `file` if omitted)
#
# Prereqs (one-time):
#   xcrun notarytool store-credentials notary-local \
#     --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
#     --password "$APPLE_APP_SPECIFIC_PASSWORD"

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "notarize-macos.sh: this script only runs on macOS" >&2
  exit 1
fi

BIN="${1:-}"
if [[ -z "$BIN" || ! -f "$BIN" ]]; then
  echo "usage: $0 <path-to-mcpsync-binary> [arch-tag]" >&2
  exit 1
fi

ARCH_TAG="${2:-}"
if [[ -z "$ARCH_TAG" ]]; then
  case "$(file -b "$BIN")" in
    *arm64*)  ARCH_TAG="arm64"  ;;
    *x86_64*) ARCH_TAG="x86_64" ;;
    *)
      echo "notarize-macos.sh: cannot infer arch from '$BIN'; pass arch-tag explicitly" >&2
      exit 1
      ;;
  esac
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES=()
  while IFS= read -r found_identity; do
    IDENTITIES+=("$found_identity")
  done < <(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/{print $2}')

  if [[ "${#IDENTITIES[@]}" -eq 1 ]]; then
    IDENTITY="${IDENTITIES[0]}"
  else
    echo "notarize-macos.sh: set CODESIGN_IDENTITY to your Developer ID Application certificate" >&2
    echo "notarize-macos.sh: found ${#IDENTITIES[@]} Developer ID Application identities" >&2
    exit 1
  fi
fi

PROFILE="${NOTARY_PROFILE:-notary-local}"

OUT_DIR="$(cd "$(dirname "$BIN")" && pwd)"
TARBALL="$OUT_DIR/mcpsync-${ARCH_TAG}-apple-darwin.tar.gz"
SHAFILE="$TARBALL.sha256"
ZIPFILE="$OUT_DIR/mcpsync-${ARCH_TAG}-apple-darwin-notarize.zip"

echo "==> codesign ($IDENTITY)"
codesign --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --force \
  "$BIN"
codesign --verify --deep --strict "$BIN"

echo "==> notarize via profile '$PROFILE'"
rm -f "$ZIPFILE"
ditto -c -k --keepParent "$BIN" "$ZIPFILE"
xcrun notarytool submit "$ZIPFILE" --keychain-profile "$PROFILE" --wait
rm -f "$ZIPFILE"

echo "==> verify signature fields"
CS_OUT="$(codesign -dv --verbose=4 "$BIN" 2>&1 || true)"
echo "$CS_OUT" | grep -E '^(Authority|TeamIdentifier|CodeDirectory v=|flags=)' || true
if ! echo "$CS_OUT" | grep -q "Authority=Developer ID Application"; then
  echo "notarize-macos.sh: binary is not signed with a Developer ID authority" >&2
  exit 1
fi
if ! echo "$CS_OUT" | grep -q "flags=0x10000(runtime)"; then
  echo "notarize-macos.sh: binary is missing the hardened runtime flag" >&2
  exit 1
fi

if [[ "$ARCH_TAG" == "x86_64" ]]; then
  MINOS="$(otool -l "$BIN" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
    in_build && $1 == "minos" { print $2; exit }
  ')"
  case "$MINOS" in
    10.*|11.*|12.*) ;;
    *)
      echo "notarize-macos.sh: x86_64 binary must target macOS 12.x or older; got minos '${MINOS:-unknown}'" >&2
      echo "notarize-macos.sh: rebuild with: zig build -Dtarget=x86_64-macos.12.0 -Doptimize=ReleaseFast" >&2
      exit 1
      ;;
  esac
fi

echo "==> smoke test signed binary"
# For x86_64 cross-compiled on arm64, executing under Rosetta fails after notarytool
# sets an immutable com.apple.provenance xattr. Use codesign --verify as the smoke test
# instead of execution — Apple already accepted the submission above.
if [[ "$ARCH_TAG" == "x86_64" && "$(uname -m)" == "arm64" ]]; then
  if ! codesign --verify --deep --strict "$BIN" 2>&1; then
    echo "notarize-macos.sh: codesign --verify failed on x86_64 binary" >&2
    exit 1
  fi
  echo "  (skipped execution smoke test for x86_64-on-arm64; codesign verified)"
else
  set +e
  SMOKE_OUT="$("$BIN" 2>&1)"
  SMOKE_STATUS=$?
  set -e
  case "$SMOKE_STATUS" in
    0|1) ;;
    *)
      echo "notarize-macos.sh: signed binary smoke test exited $SMOKE_STATUS" >&2
      echo "$SMOKE_OUT" >&2
      exit 1
      ;;
  esac
  if ! grep -qi "mcpsync\|mcp\|sync" <<<"$SMOKE_OUT"; then
    echo "notarize-macos.sh: signed binary smoke test did not print expected output" >&2
    echo "$SMOKE_OUT" >&2
    exit 1
  fi
fi

echo "==> package $TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$BIN")" "$(basename "$BIN")"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$SHAFILE")")

echo ""
echo "done:"
echo "  signed+notarized: $BIN"
echo "  tarball:          $TARBALL"
echo "  sha256:           $SHAFILE"
