#!/usr/bin/env bash
# Phase 34/37 — restore PORTABLE config on macOS. Never overwrites existing files.
# Authentication is NOT restored — sign in again. Windows-only paths are reported, not copied blindly.
# Usage: ./restore-config-macos.sh ~/Mosses-AI-Migration [--install-extensions] [--pull-ollama] [--dry-run]
set -euo pipefail

BACKUP="${1:?backup root}"
PC="$BACKUP/14_CONFIG/portable-config"
EXT=0; OLL=0; DRY=()
for a in "${@:2}"; do
  case "$a" in
    --install-extensions) EXT=1 ;;
    --pull-ollama) OLL=1 ;;
    --dry-run) DRY=(--dry-run) ;;
  esac
done
[[ -d "$PC" ]] || { echo "portable-config not found: $PC" >&2; exit 1; }
copy_missing() { [[ -e "$1" ]] || return 0; mkdir -p "$(dirname "$2")"; rsync -ah --ignore-existing ${DRY[@]+"${DRY[@]}"} "$1" "$2"; echo "  $1 -> $2"; }

echo "Claude Code portable config -> ~/.claude"
for n in commands agents skills hooks output-styles memory; do copy_missing "$PC/claude/$n/" "$HOME/.claude/$n/"; done
for n in CLAUDE.md settings.json keybindings.json; do copy_missing "$PC/claude/$n" "$HOME/.claude/$n"; done

VSCODE_USER="$HOME/Library/Application Support/Code/User"
CURSOR_USER="$HOME/Library/Application Support/Cursor/User"
for pair in "vscode|$VSCODE_USER|code" "cursor|$CURSOR_USER|cursor"; do
  IFS='|' read -r name dir cli <<<"$pair"
  echo "$name settings -> $dir"
  for n in settings.json keybindings.json mcp.json; do copy_missing "$PC/$name/$n" "$dir/$n"; done
  copy_missing "$PC/$name/snippets/" "$dir/snippets/"
  list="$PC/$name-extensions.txt"
  if (( EXT )) && [[ -f "$list" ]] && command -v "$cli" >/dev/null 2>&1; then
    installed="$("$cli" --list-extensions 2>/dev/null || true)"
    tr -d '\r' < "$list" | cut -d@ -f1 | while read -r id; do
      [[ -z "$id" ]] && continue
      grep -qix "$id" <<<"$installed" && continue
      if (( ${#DRY[@]} )); then echo "  [dry-run] $cli --install-extension $id"; else "$cli" --install-extension "$id" >/dev/null 2>&1 && echo "  [ext] $id" || echo "  [ext FAILED/Windows-only?] $id"; fi
    done
  fi
done

if (( OLL )) && command -v ollama >/dev/null 2>&1; then
  om="$BACKUP/00_MANIFEST/AI-MIGRATION-WORK/01_MANIFESTS/ollama-models.json"
  if [[ -f "$om" ]]; then
    have="$(ollama list 2>/dev/null || true)"
    python3 -c 'import json,sys; [print(m["Model"]) for m in json.load(open(sys.argv[1], encoding="utf-8-sig")) if m["Classification"].startswith("DOWNLOADABLE_STANDARD")]' "$om" |
      while read -r m; do grep -qF "$m" <<<"$have" && continue; (( ${#DRY[@]} )) && echo "  [dry-run] ollama pull $m" || ollama pull "$m"; done
  fi
fi

echo
echo "Scanning restored config for Windows-only paths (see WINDOWS-TO-MAC-COMPATIBILITY.md)..."
"$(dirname "$0")/scan-windows-dependencies.sh" "$HOME/.claude" "$VSCODE_USER" "$CURSOR_USER" || true
echo "MCP: rebuild from 18_REPORTS/MCP-INVENTORY.md with macOS paths (claude mcp add ...). Never copy ~/.claude.json from Windows."
