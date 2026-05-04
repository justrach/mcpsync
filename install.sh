#!/usr/bin/env bash
# mcpsync installer
# Usage: curl -fsSL https://mcpsync.codegraff.com | bash
set -euo pipefail

REPO="justrach/mcpsync"
BIN_NAME="mcpsync"
INSTALL_DIR="${MCPSYNC_INSTALL_DIR:-$HOME/bin}"

# ── Colors (only if stdout is a tty) ─────────────────────────────────────────
if [ -t 1 ]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  CYAN="\033[36m"
  GREEN="\033[32m"
  MAGENTA="\033[35m"
  YELLOW="\033[33m"
  RED="\033[31m"
  RESET="\033[0m"
else
  BOLD="" DIM="" CYAN="" GREEN="" MAGENTA="" YELLOW="" RED="" RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { printf "${BOLD}${CYAN} ❯${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN} ✓${RESET} %s\n" "$*"; }
info()  { printf "${DIM}   %s${RESET}\n" "$*"; }
warn()  { printf "${YELLOW} ⚠${RESET} %s\n" "$*"; }
die()   { printf "${RED} ✗ error:${RESET} %s\n" "$*" >&2; exit 1; }

# Spinner — runs in bg, killed when caller calls stop_spinner
_SPINNER_PID=""
start_spinner() {
  local msg="$1"
  if [ -t 1 ]; then
    (
      local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
      local i=0
      while true; do
        printf "\r${CYAN}  ${frames[$i]}${RESET}  ${DIM}%s${RESET}" "$msg"
        i=$(( (i+1) % ${#frames[@]} ))
        sleep 0.08
      done
    ) &
    _SPINNER_PID=$!
  else
    printf "   %s...\n" "$msg"
  fi
}
stop_spinner() {
  if [ -n "$_SPINNER_PID" ]; then
    kill "$_SPINNER_PID" 2>/dev/null && wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
    printf "\r\033[2K"   # clear spinner line
  fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${CYAN}  mcpsync${RESET}  ${DIM}· one config. every AI tool. always in sync.${RESET}\n"
printf "${DIM}  a codegraff product${RESET}\n\n"

# ── Detect OS + arch ──────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    case "$ARCH" in
      arm64)  ASSET="mcpsync-arm64-apple-darwin.tar.gz" ;;
      x86_64) ASSET="mcpsync-x86_64-apple-darwin.tar.gz" ;;
      *) die "unsupported macOS architecture: $ARCH" ;;
    esac
    ;;
  Linux)
    case "$ARCH" in
      x86_64)  ASSET="mcpsync-x86_64-linux.tar.gz" ;;
      aarch64) ASSET="mcpsync-aarch64-linux.tar.gz" ;;
      *) die "unsupported Linux architecture: $ARCH" ;;
    esac
    ;;
  *) die "unsupported OS: $OS" ;;
esac

info "platform: $OS/$ARCH"

# ── Fetch latest release tag ──────────────────────────────────────────────────
start_spinner "Fetching latest release"
LATEST_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
stop_spinner

[[ -z "$LATEST_TAG" ]] && die "could not determine latest release tag"
ok "Latest release: ${BOLD}${LATEST_TAG}${RESET}"

URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ASSET}"

# ── Download ──────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

start_spinner "Downloading $ASSET"
curl -fsSL "$URL" -o "$TMP/$ASSET"
stop_spinner
ok "Downloaded"

# ── Extract ───────────────────────────────────────────────────────────────────
start_spinner "Extracting"
tar -xzf "$TMP/$ASSET" -C "$TMP"
stop_spinner

EXTRACTED_BIN="$(find "$TMP" -maxdepth 1 -type f -perm +111 ! -name "*.tar.gz" | head -1)"
[[ -z "$EXTRACTED_BIN" ]] && die "could not find binary in archive"
ok "Extracted"

# ── Install ───────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cp "$EXTRACTED_BIN" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"
ok "Installed  ${DIM}→ $INSTALL_DIR/$BIN_NAME${RESET}"

# ── PATH hint ─────────────────────────────────────────────────────────────────
PATH_OK=false
if echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  PATH_OK=true
fi

if ! $PATH_OK; then
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
    ok "Added $INSTALL_DIR to PATH in ${DIM}$(basename "$SHELL_RC")${RESET}"
    warn "Reload your shell:  ${BOLD}source $SHELL_RC${RESET}"
  else
    warn "Add ${BOLD}$INSTALL_DIR${RESET} to your PATH"
  fi
fi

# ── Done animation ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  printf "\n"
  # Quick celebrate sweep
  local_frames=("  ·" "  · ·" "  · · ·" "  · · · ·" "  · · · · ·")
  for f in "${local_frames[@]}"; do
    printf "\r${MAGENTA}%s${RESET}" "$f"
    sleep 0.07
  done
  printf "\r\033[2K"
fi

printf "\n"
printf "${BOLD}${GREEN}  ✦ mcpsync ${LATEST_TAG} installed!${RESET}\n"
printf "\n"
printf "  ${DIM}Get started:${RESET}\n"
printf "  ${BOLD}${CYAN}mcpsync init${RESET}    ${DIM}# pull existing configs into ~/.mcpconfig.json${RESET}\n"
printf "  ${BOLD}${CYAN}mcpsync sync${RESET}    ${DIM}# push to every tool${RESET}\n"
printf "  ${BOLD}${CYAN}mcpsync status${RESET}  ${DIM}# see what's in sync${RESET}\n"
printf "\n"
printf "  ${DIM}docs / issues → github.com/justrach/mcpsync${RESET}\n"
printf "\n"
