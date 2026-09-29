#!/usr/bin/env bash
# Phase 35 — verify the rebuilt macOS environment with evidence. Read-only.
# Output: ~/AI-RESTORE-LOGS/MACOS-RESTORE-REPORT-<ts>.md (+ .json) — use the .json as evidence for
# MACOS_RESTORE_VERIFIED in attestations.json on the notebook.
# Usage: ./verify-environment-macos.sh [~/Projects] [~/Mosses-AI-Migration]
set -uo pipefail
PROJECTS="${1:-$HOME/Projects}"
BACKUP="${2:-$HOME/Mosses-AI-Migration}"
DIR="$HOME/AI-RESTORE-LOGS"; mkdir -p "$DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
MD="$DIR/MACOS-RESTORE-REPORT-$STAMP.md"; JSON="$DIR/MACOS-RESTORE-REPORT-$STAMP.json"
ROWS=(); FAILS=0; PARTS=0
add() { ROWS+=("$1|$2|$3"); [[ "$2" == FAIL ]] && FAILS=$((FAILS+1)); [[ "$2" == PARTIAL ]] && PARTS=$((PARTS+1)); return 0; }

for t in git gh node npm python3 uv code claude tailscale 7zz sqlite3; do
  if command -v "$t" >/dev/null 2>&1; then
    v="$("$t" --version 2>/dev/null | head -1 | tr '|' '/')"; [[ "$t" == 7zz ]] && v=present
    add "tool: $t" PASS "${v:-present}"
  else
    add "tool: $t" FAIL "not on PATH"
  fi
done
command -v tailscale >/dev/null 2>&1 && { tailscale status >/dev/null 2>&1 && add "tailscale connected" PASS "status ok" || add "tailscale connected" FAIL "not connected"; }
command -v gh >/dev/null 2>&1 && { gh auth status >/dev/null 2>&1 && add "gh authenticated" PASS "gh auth status ok (output not logged)" || add "gh authenticated" FAIL "run gh auth login"; }
skills=$(find "$HOME/.claude/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
(( skills > 0 )) && add "Claude skills" PASS "SKILL.md count=$skills" || add "Claude skills" PARTIAL "none restored"
agents=$(find "$HOME/.claude/agents" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
(( agents > 0 )) && add "Claude agents" PASS "agents=$agents" || add "Claude agents" PARTIAL "none restored"
if command -v claude >/dev/null 2>&1; then
  claude mcp list 2>/dev/null | grep -qi connected && add "Claude MCP" PASS "at least one server connected" || add "Claude MCP" PARTIAL "no connected servers yet (re-add from MCP-INVENTORY.md)"
fi
if [[ -d "$HOME/.claude" ]]; then
  hits=$(grep -rIlE '[A-Za-z]:\\|%USERPROFILE%|\.exe([^A-Za-z]|$)' "$HOME/.claude/settings.json" "$HOME/.claude/hooks" 2>/dev/null | wc -l | tr -d ' ')
  (( hits == 0 )) && add "Claude config free of Windows paths" PASS "0 files" || add "Claude config free of Windows paths" FAIL "$hits file(s) — run scan-windows-dependencies.sh"
fi
repos=0
while IFS= read -r -d '' g; do
  r="$(dirname "$g")"; repos=$((repos+1))
  if git -c safe.directory='*' -C "$r" fsck --connectivity-only --no-dangling >/dev/null 2>&1; then add "git fsck: ${r#"$PROJECTS"/}" PASS ok; else add "git fsck: ${r#"$PROJECTS"/}" FAIL "fsck failed"; fi
done < <(find "$PROJECTS" -maxdepth 4 -type d -name .git -print0 2>/dev/null)
(( repos > 0 )) && add "repos under $PROJECTS" PASS "$repos" || add "repos under $PROJECTS" FAIL "none found"
if [[ -d "$BACKUP/11_DATABASES" ]] && command -v sqlite3 >/dev/null 2>&1; then
  while IFS= read -r -d '' db; do
    res="$(sqlite3 "file:$db?mode=ro" 'PRAGMA integrity_check;' 2>&1 | head -1)"
    [[ "$res" == ok ]] && add "db: $(basename "$db")" PASS "integrity ok" || add "db: $(basename "$db")" FAIL "$res"
  done < <(find "$BACKUP/11_DATABASES" -type f -print0)
fi
ls "$BACKUP"/99_ENCRYPTED_SECRETS/*.7z >/dev/null 2>&1 && add "encrypted secrets archive on Mac" PASS "present (open-test: 7zz t -p <archive>)" || add "encrypted secrets archive on Mac" FAIL "missing"
if command -v docker >/dev/null 2>&1; then docker info >/dev/null 2>&1 && add "docker engine" PASS ok || add "docker engine" PARTIAL "start Docker Desktop"; fi

if (( FAILS )); then OVERALL=FAIL; elif (( PARTS )); then OVERALL=PARTIAL; else OVERALL=PASS; fi
{
  echo "# MACOS RESTORE REPORT — $(hostname -s) ($STAMP)"; echo
  echo "Architecture: $(uname -m) · macOS $(sw_vers -productVersion 2>/dev/null)"; echo
  echo "**Overall: $OVERALL** (fail=$FAILS partial=$PARTS)"; echo
  echo "| Check | Status | Evidence |"; echo "|---|---|---|"
  for r in "${ROWS[@]}"; do IFS='|' read -r c s e <<<"$r"; echo "| $c | $s | $e |"; done
} > "$MD"
printf '{"phase":"phase35-macos-restore","status":"%s","host":"%s","timestamp":"%s","fail":%d,"partial":%d,"report":"%s"}\n' \
  "$OVERALL" "$(hostname -s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FAILS" "$PARTS" "$MD" > "$JSON"
echo "macOS restore verification: $OVERALL — $MD"
