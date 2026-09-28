#!/usr/bin/env bash
# Phase 32 — find Windows-specific dependencies in config/scripts before using them on macOS.
# Read-only. Writes WINDOWS-TO-MAC-COMPATIBILITY.md in the current directory (or $OUT).
# Usage: ./scan-windows-dependencies.sh <dir> [dir...]
set -uo pipefail
OUT="${OUT:-$PWD/WINDOWS-TO-MAC-COMPATIBILITY.md}"
declare -a RULES=(
  '[A-Za-z]:\\|[A-Za-z]:/Users/|drive-letter path|~/... or $HOME/...|manual|HIGH'
  '\\Users\\|Windows user path|$HOME|manual|HIGH'
  '%USERPROFILE%|%APPDATA%|%LOCALAPPDATA%|Windows env syntax|$HOME / ~/Library/Application Support|manual|MEDIUM'
  '\$env:[A-Za-z_]+|PowerShell env syntax|$VAR (zsh)|manual|MEDIUM'
  '\.exe([^A-Za-z0-9]|$)|.exe reference|native binary name (brew)|manual|HIGH'
  '[Pp]ower[Ss]hell(\.exe)?|cmd(\.exe)? /c|\.ps1([^A-Za-z0-9]|$)|\.bat([^A-Za-z0-9]|$)|PowerShell/cmd script|bash/zsh equivalent or pwsh|manual|MEDIUM'
  'npx\.cmd|node\.exe|npm\.cmd|Windows shim|npx / node|automatic|LOW'
)
{
  echo "# WINDOWS TO MAC COMPATIBILITY"
  echo
  echo "Scanned: $* — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "| File | Line | Windows dependency | macOS replacement | Automatic/manual | Risk |"
  echo "|---|---|---|---|---|---|"
} > "$OUT"
count=0
for dir in "$@"; do
  [[ -e "$dir" ]] || continue
  while IFS= read -r -d '' f; do
    for rule in "${RULES[@]}"; do
      # rule = regex|label|replacement|mode|risk  (regex itself may contain |, so split from the right)
      risk="${rule##*|}"; rest="${rule%|*}"
      mode="${rest##*|}"; rest="${rest%|*}"
      repl="${rest##*|}"; rest="${rest%|*}"
      label="${rest##*|}"; regex="${rest%|*}"
      while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        echo "| ${f//|/\\|} | $ln | $label | $repl | $mode | $risk |" >> "$OUT"
        count=$((count+1))
      done < <(grep -nEI "$regex" "$f" 2>/dev/null | head -20)
    done
  done < <(find "$dir" -type f \( -name '*.json' -o -name '*.jsonc' -o -name '*.md' -o -name '*.toml' -o -name '*.yml' -o -name '*.yaml' -o -name '*.sh' -o -name '*.ps1' -o -name '*.env.example' -o -name '*.js' -o -name '*.ts' -o -name '*.py' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -size -2M -print0 2>/dev/null)
done
echo >> "$OUT"
echo "Findings: $count" >> "$OUT"
echo "Windows-dependency findings: $count -> $OUT"
