#!/usr/bin/env bash
# mcpsync installer
# Usage: curl -fsSL https://mcpsync.codegraff.com | bash
set -euo pipefail

REPO="justrach/mcpsync"
BIN_NAME="mcpsync"
INSTALL_DIR="${MCPSYNC_INSTALL_DIR:-$HOME/bin}"

# ── Detect OS + arch ──────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    case "$ARCH" in
      arm64)  ASSET="mcpsync-arm64-apple-darwin.tar.gz" ;;
      x86_64) ASSET="mcpsync-x86_64-apple-darwin.tar.gz" ;;
      *) echo "error: unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
    esac
    ;;
  Linux)
    case "$ARCH" in
      x86_64)  ASSET="mcpsync-x86_64-linux.tar.gz" ;;
      aarch64) ASSET="mcpsync-aarch64-linux.tar.gz" ;;
      *) echo "error: unsupported Linux architecture: $ARCH" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "error: unsupported OS: $OS" >&2
    exit 1
    ;;
esac

# ── Fetch latest release tag ──────────────────────────────────────────────────
echo "==> Fetching latest mcpsync release..."
LATEST_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"

if [[ -z "$LATEST_TAG" ]]; then
  echo "error: could not determine latest release tag" >&2
  exit 1
fi

echo "==> Installing mcpsync ${LATEST_TAG}..."

URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ASSET}"

# ── Download + extract ────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading ${ASSET}..."
curl -fsSL "$URL" -o "$TMP/$ASSET"

echo "==> Extracting..."
tar -xzf "$TMP/$ASSET" -C "$TMP"

# ── Install ───────────────────────────────────────────────────────────────────
# The binary inside the tarball may be named mcpsync-<arch> — find it
EXTRACTED_BIN="$(find "$TMP" -maxdepth 1 -type f -perm +111 ! -name "*.tar.gz" | head -1)"
if [[ -z "$EXTRACTED_BIN" ]]; then
  echo "error: could not find binary in archive" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$EXTRACTED_BIN" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"

echo "==> Installed to $INSTALL_DIR/$BIN_NAME"

# ── PATH hint ─────────────────────────────────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  SHELL_RC=""
  if [[ "$OS" == "Darwin" ]]; then
    SHELL_RC="$HOME/.zshrc"
    [[ -n "${BASH_VERSION:-}" && -f "$HOME/.bashrc" ]] && SHELL_RC="$HOME/.bashrc"
  else
    SHELL_RC="$HOME/.bashrc"
    [[ -n "${ZSH_VERSION:-}" ]] && SHELL_RC="$HOME/.zshrc"
  fi

  if [[ -n "$SHELL_RC" ]] && ! grep -q "$INSTALL_DIR" "$SHELL_RC" 2>/dev/null; then
    printf '\n# mcpsync\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$SHELL_RC"
    echo "==> Added $INSTALL_DIR to PATH in $SHELL_RC"
    echo "    Run: source $SHELL_RC"
  else
    echo "    Add $INSTALL_DIR to your PATH to use mcpsync"
  fi
fi

echo ""
echo "==> Done! Run: mcpsync init"
