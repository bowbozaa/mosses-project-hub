#!/usr/bin/env bash
# Phase 34 — restore projects from the verified local backup into ~/Projects.
# NEVER overwrites (rsync --ignore-existing, no --delete). Safe to re-run.
# Windows folder names like "C_Projects" / "D_Mosses-Project-Hub" are kept as-is to avoid guessing.
# Usage: ./restore-projects-macos.sh ~/Mosses-AI-Migration [~/Projects] [--include-archive] [--dry-run]
set -euo pipefail

BACKUP="${1:?backup root (e.g. ~/Mosses-AI-Migration)}"
TARGET="${2:-$HOME/Projects}"
ARCHIVE=0; DRY=()
for a in "${@:3}"; do
  case "$a" in
    --include-archive) ARCHIVE=1 ;;
    --dry-run) DRY=(--dry-run) ;;
  esac
done
mkdir -p "$TARGET"

sets=(01_PROJECTS)
(( ARCHIVE )) && sets+=(16_ARCHIVE)
for s in "${sets[@]}"; do
  [[ -d "$BACKUP/$s" ]] || { echo "missing $BACKUP/$s"; continue; }
  dest="$TARGET"; [[ "$s" == 16_ARCHIVE ]] && dest="$TARGET/_archive"
  mkdir -p "$dest"
  echo "== $s -> $dest"
  rsync -ah --ignore-existing ${DRY[@]+"${DRY[@]}"} "$BACKUP/$s/" "$dest/"
done

# NTFS copies arrive without exec bits; restore them only for files git tracks as executable.
while IFS= read -r -d '' gitdir; do
  repo="$(dirname "$gitdir")"
  git -c safe.directory='*' -C "$repo" ls-files -s 2>/dev/null | awk '$1=="100755"{ $1=$2=$3=""; sub(/^ +/,""); print }' |
    while IFS= read -r f; do [[ -f "$repo/$f" && ${#DRY[@]} -eq 0 ]] && chmod +x "$repo/$f"; done
  # Windows checkouts may have core.autocrlf / filemode noise — report, do not change.
  n=$(git -c safe.directory='*' -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo "repo $(basename "$repo"): $n changed paths vs HEAD (line endings/filemode may cause noise: git config core.fileMode false)"
done < <(find "$TARGET" -maxdepth 4 -type d -name .git -print0)

echo
echo "Local-only commits/stashes: $BACKUP/13_GIT/bundles (git clone <file.bundle>)."
echo "Secrets: 7zz x -p \"$BACKUP/99_ENCRYPTED_SECRETS/<archive>.7z\" -o<temp dir>, then place files manually."
