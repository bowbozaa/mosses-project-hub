#!/usr/bin/env bash
# Phases 33-34 — idempotent macOS bootstrap (Apple Silicon first, Intel supported).
# Installs only what is missing via Homebrew. Safe to re-run. No secrets.
# Usage: ./bootstrap-macos.sh [--optional] [--dry-run]
set -euo pipefail

OPTIONAL=0; DRY=0
for a in "$@"; do
  case "$a" in
    --optional) OPTIONAL=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown arg $a" >&2; exit 64 ;;
  esac
done
LOG_DIR="$HOME/AI-RESTORE-LOGS"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap-macos-$(date +%Y%m%d-%H%M%S).log"
log() { printf '%s %s\n' "$(date +%FT%T)" "$*" | tee -a "$LOG"; }
run() { if (( DRY )); then log "[dry-run] $*"; else log "[run] $*"; "$@" >>"$LOG" 2>&1 || log "  exit $?"; fi; }

ARCH="$(uname -m)"
log "macOS $(sw_vers -productVersion) on $ARCH"
if [[ "$ARCH" == "arm64" ]]; then BREW_PREFIX=/opt/homebrew; else BREW_PREFIX=/usr/local; fi

if ! command -v brew >/dev/null 2>&1; then
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  else
    log "Homebrew is not installed. Install it yourself (interactive, needs your password):"
    log '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    log "then re-run this script."
    exit 1
  fi
fi

if ! xcode-select -p >/dev/null 2>&1; then log "Xcode Command Line Tools missing — run: xcode-select --install"; fi

FORMULAE=(git gh node python@3.12 uv sevenzip sqlite)
CASKS=(visual-studio-code tailscale)
OPT_FORMULAE=(pnpm)
OPT_CASKS=(docker cursor ollama claude powershell)

install_formula() { brew list --formula "$1" >/dev/null 2>&1 && log "[skip] $1" || run brew install "$1"; }
install_cask() { brew list --cask "$1" >/dev/null 2>&1 && log "[skip] cask $1" || run brew install --cask "$1"; }

for f in "${FORMULAE[@]}"; do install_formula "$f"; done
for c in "${CASKS[@]}"; do install_cask "$c"; done
if (( OPTIONAL )); then
  for f in "${OPT_FORMULAE[@]}"; do install_formula "$f"; done
  for c in "${OPT_CASKS[@]}"; do install_cask "$c"; done
fi

# Claude Code — official native installer; skipped if already present.
if command -v claude >/dev/null 2>&1; then
  log "[skip] Claude Code $(claude --version 2>/dev/null | head -1)"
elif (( DRY )); then
  log "[dry-run] curl -fsSL https://claude.ai/install.sh | bash"
else
  log "[install] Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash >>"$LOG" 2>&1 || log "  Claude Code installer failed — see $LOG"
fi
if command -v npm >/dev/null 2>&1 && ! command -v wrangler >/dev/null 2>&1; then run npm i -g wrangler; fi

mkdir -p "$HOME/Projects"
log "Next (manual): open Tailscale and sign in · gh auth login · claude (sign in) · wrangler login · first start of Docker Desktop."
log "Log: $LOG"
