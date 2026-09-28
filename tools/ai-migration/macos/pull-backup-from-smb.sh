#!/usr/bin/env bash
# Phase 31 — SECOND independent backup on the Mac: copy the verified backup from friclawd (SMB over
# Tailscale) to local disk, then verify every file against SHA256SUMS.txt.
#   * rsync WITHOUT --delete; existing local files are never overwritten (--ignore-existing).
#   * Nothing is exposed to the public internet — mount friclawd over its Tailscale IP only.
#
# Usage:
#   1. Finder > Go > Connect to Server > smb://100.127.194.73/<Share>   (mounts under /Volumes/<Share>)
#   2. ./pull-backup-from-smb.sh "/Volumes/<Share>/Mosses-AI-Migration" "$HOME/Mosses-AI-Migration"
set -euo pipefail

SRC="${1:?source backup root on the mounted share}"
DEST="${2:-$HOME/Mosses-AI-Migration}"
LOG_DIR="$HOME/AI-RESTORE-LOGS"
mkdir -p "$LOG_DIR" "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/pull-backup-$STAMP.log"

[[ -f "$SRC/00_MANIFEST/SHA256SUMS.txt" ]] || { echo "SHA256SUMS.txt not found under $SRC/00_MANIFEST — is this the verified backup root?" >&2; exit 1; }

need_kb=$(du -sk "$SRC" | awk '{print $1}')
free_kb=$(df -k "$DEST" | awk 'NR==2 {print $4}')
margin_kb=$(( need_kb * 115 / 100 ))
echo "Backup size: $((need_kb/1024/1024)) GB, free on Mac: $((free_kb/1024/1024)) GB" | tee -a "$LOG"
if (( free_kb < margin_kb )); then
  echo "INSUFFICIENT_DESTINATION_SPACE — nothing copied." | tee -a "$LOG"
  exit 2
fi

# -a archive, -h human, --partial resumable; NO --delete. --ignore-existing: never overwrite local files.
rsync -ah --partial --ignore-existing --info=stats2 "$SRC/" "$DEST/" 2>&1 | tee -a "$LOG" || {
  # macOS ships an old rsync without --info; retry with portable flags.
  rsync -ah --partial --ignore-existing --stats "$SRC/" "$DEST/" 2>&1 | tee -a "$LOG"
}

echo "Verifying SHA-256 (this reads every file)..." | tee -a "$LOG"
cd "$DEST"
if shasum -a 256 -c --quiet "00_MANIFEST/SHA256SUMS.txt" >>"$LOG" 2>&1; then
  STATUS=PASS
else
  STATUS=FAIL
fi
total=$(wc -l < "00_MANIFEST/SHA256SUMS.txt" | tr -d ' ')
failed=$(grep -c -E ': (FAILED|FAILED open or read)$' "$LOG" || true)
mkdir -p "$DEST/18_REPORTS"
REPORT="$DEST/18_REPORTS/VERIFY-$(hostname -s)-$STAMP.json"
cat > "$REPORT" <<EOF
{
  "phase": "phase31-second-backup-verify",
  "status": "$STATUS",
  "host": "$(hostname -s)",
  "root": "$DEST",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expectedFiles": $total,
  "failedOrMissing": $failed,
  "log": "$LOG"
}
EOF
echo "SECOND BACKUP VERIFY: $STATUS (expected $total, failed/missing $failed). Evidence: $REPORT" | tee -a "$LOG"
[[ "$STATUS" == PASS ]]
