#!/usr/bin/env bash
# backup_audio_files.sh — back up every audio file listed in a scan TSV
#
# Reads the TSV produced by scan_audio_files.sh and copies each file into a
# timestamped backup tree that PRESERVES the absolute path, ownership,
# permissions, and timestamps. Also writes a manifest with sha256 hashes so
# rollback can be verified byte-for-byte.
#
# Usage:
#   ./backup_audio_files.sh <scan-tsv>
#   ./backup_audio_files.sh ./scan-results/audio-files-host-20260529_120000.tsv
#
# Output:
#   ./backups/<host>-<timestamp>/files/<original-absolute-path-mirrored>
#   ./backups/<host>-<timestamp>/manifest.tsv
#   ./backups/<host>-<timestamp>/restore.sh    (auto-generated rollback)

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <scan-tsv-from-scan_audio_files.sh>" >&2
  exit 2
fi

TSV="$1"
if [ ! -f "$TSV" ]; then
  echo "error: scan TSV not found: $TSV" >&2
  exit 2
fi

TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname)"
BACKUP_ROOT="./backups/${HOST}-${TS}"
FILE_ROOT="${BACKUP_ROOT}/files"
MANIFEST="${BACKUP_ROOT}/manifest.tsv"
LOG="${BACKUP_ROOT}/backup.log"
RESTORE="${BACKUP_ROOT}/restore.sh"

mkdir -p "$FILE_ROOT"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO="sudo"
  else
    echo "warn: not root and no passwordless sudo; some files may not copy" | tee -a "$LOG"
  fi
fi

# Manifest header
printf 'original_path\tbackup_path\tsize_bytes\towner_group\tmode_octal\tmtime_iso\tsha256\n' > "$MANIFEST"

# Skip header row, iterate
COUNT_OK=0
COUNT_FAIL=0
tail -n +2 "$TSV" | while IFS=$'\t' read -r ORIG SIZE OWNER MODE MTIME EXT; do
  [ -z "${ORIG:-}" ] && continue
  if [ ! -e "$ORIG" ]; then
    echo "MISSING $ORIG" | tee -a "$LOG"
    COUNT_FAIL=$((COUNT_FAIL+1))
    continue
  fi
  DEST="${FILE_ROOT}${ORIG}"        # mirror full absolute path under FILE_ROOT
  DESTDIR="$(dirname "$DEST")"
  mkdir -p "$DESTDIR"
  # --archive preserves perms, owner, group, timestamps, symlinks.
  if $SUDO cp --archive --preserve=all -- "$ORIG" "$DEST" 2>>"$LOG"; then
    HASH="$($SUDO sha256sum "$DEST" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ORIG" "$DEST" "$SIZE" "$OWNER" "$MODE" "$MTIME" "$HASH" >> "$MANIFEST"
    COUNT_OK=$((COUNT_OK+1))
  else
    echo "FAILED  $ORIG" | tee -a "$LOG"
    COUNT_FAIL=$((COUNT_FAIL+1))
  fi
done

# Counts above were computed in a subshell from the pipe, so they were lost.
# Recount from the manifest (one row per successful copy) and derive failures
# by comparing against the number of non-blank source rows. Without this, a
# partial backup (some files MISSING/FAILED) looks identical to a clean run.
OK=$(($(wc -l < "$MANIFEST") - 1))
ATTEMPTED=$(tail -n +2 "$TSV" | grep -cve '^[[:space:]]*$' || true)
FAIL=$((ATTEMPTED - OK))
[ "$FAIL" -lt 0 ] && FAIL=0

# --- Generate rollback script --------------------------------------------

cat > "$RESTORE" <<'RESTORE_HEAD'
#!/usr/bin/env bash
# AUTO-GENERATED. Restores every file in this backup to its original path.
# Each restore is verified by sha256. Re-runnable.
#
# Usage:
#   ./restore.sh              # dry-run, prints what would happen
#   ./restore.sh --apply      # actually restore
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/manifest.tsv"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo"; else
    echo "error: need root or passwordless sudo to restore" >&2; exit 2
  fi
fi

OK=0; FAIL=0
tail -n +2 "$MANIFEST" | while IFS=$'\t' read -r ORIG BAK SIZE OWNER MODE MTIME HASH; do
  [ -z "${ORIG:-}" ] && continue
  # Re-root the backup onto THIS script's directory instead of trusting the
  # manifest's CWD-relative backup_path. The backup tree mirrors each file's
  # absolute path under files/, so this is relocation-proof: the restore works
  # no matter where the backup folder is moved or which CWD it is run from.
  BAK="$HERE/files${ORIG}"
  if [ ! -e "$BAK" ]; then echo "MISSING backup: $BAK" >&2; FAIL=$((FAIL+1)); continue; fi
  ACT_HASH="$($SUDO sha256sum "$BAK" | awk '{print $1}')"
  if [ "$ACT_HASH" != "$HASH" ]; then
    echo "BAD BACKUP HASH: $BAK (expected $HASH, got $ACT_HASH)" >&2
    FAIL=$((FAIL+1)); continue
  fi
  if [ "$APPLY" -eq 1 ]; then
    $SUDO cp --archive --preserve=all -- "$BAK" "$ORIG"
    NEW_HASH="$($SUDO sha256sum "$ORIG" | awk '{print $1}')"
    if [ "$NEW_HASH" = "$HASH" ]; then
      echo "RESTORED $ORIG"; OK=$((OK+1))
    else
      echo "VERIFY FAILED $ORIG" >&2; FAIL=$((FAIL+1))
    fi
  else
    echo "would restore: $BAK -> $ORIG"
  fi
done

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "Dry run only. Re-run with --apply to actually restore."
fi
RESTORE_HEAD
chmod +x "$RESTORE"

# --- Summary -------------------------------------------------------------

{
  echo "Backup complete"
  echo "==============="
  echo "Host:    $HOST"
  echo "Started: $TS"
  echo "Files backed up: $OK of $ATTEMPTED"
  if [ "$FAIL" -gt 0 ]; then
    echo "!! WARNING: $FAIL file(s) MISSING or FAILED to back up — see $LOG"
    echo "!! Do NOT overwrite originals until the backup is complete."
  fi
  echo "Backup root:     $BACKUP_ROOT"
  echo "Manifest:        $MANIFEST"
  echo "Restore script:  $RESTORE"
  echo
  echo "Next step: ALSO copy this folder off the robot."
  echo "  From your workstation:"
  echo "    scp -r unitree@<G1_IP>:\"$(realpath "$BACKUP_ROOT")\" ./"
} | tee -a "$LOG"
