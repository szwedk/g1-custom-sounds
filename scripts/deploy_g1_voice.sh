#!/usr/bin/env bash
# deploy_g1_voice.sh — connect to one Unitree G1 and apply the custom English voice.
#
# THE ONE COMMAND. Point it at a robot and it plays each prompt in voice/prompts.tsv
# through the robot's speaker via the unitree_sdk2 AudioClient (PlayStream of your
# pre-rendered WAVs, or on-robot English TTS with --tts).
#
# It does NOT modify any files on the robot. There is nothing to roll back: stop
# running this and the robot keeps its factory voice. Re-runnable and idempotent.
#
# Usage:
#   ./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0
#   ./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0 --only P01     # test ONE first
#   ./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0 --dry-run      # plan only
#   ./scripts/deploy_g1_voice.sh --simulate                             # no robot/SDK at all
#   ./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0 --tts          # use robot TTS, no WAVs
#   ./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0 --include-safety
#
# Prereqs (non-simulate): python3 + unitree_sdk2py on THIS host, on the robot's
# network; --iface is the local NIC reaching the robot (find: ip -br addr).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/voice/config.sh" ] && . "$ROOT/voice/config.sh"

PLAYER="$ROOT/voice/lib/g1_play.py"
CLIPS="$ROOT/voice/generated"
TSV="$ROOT/voice/prompts.tsv"
LOG="$ROOT/voice/deploy-log.txt"

# --- args -----------------------------------------------------------------
ROBOT_IP="${G1_ROBOT_IP:-}"
IFACE="${G1_IFACE:-}"
VOLUME="${G1_VOLUME:-}"
ONLY=""; DRY=0; SIM=0; USE_TTS=0; INCLUDE_SAFETY=0; ASSUME_YES=0; SPEAKER=1
while [ $# -gt 0 ]; do
  case "$1" in
    --iface)          [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --iface needs a value" >&2; exit 2; }; IFACE="$2"; shift 2; continue ;;
    --only)           [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --only needs a prompt id" >&2; exit 2; }; ONLY="$2"; shift 2; continue ;;
    --volume)         [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --volume needs a value" >&2; exit 2; }; VOLUME="$2"; shift 2; continue ;;
    --speaker)        [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --speaker needs a value" >&2; exit 2; }; SPEAKER="$2"; shift 2; continue ;;
    --dry-run)        DRY=1 ;;
    --simulate)       SIM=1 ;;
    --tts)            USE_TTS=1 ;;
    --include-safety) INCLUDE_SAFETY=1 ;;
    -y|--yes)         ASSUME_YES=1 ;;
    -h|--help)        sed -n '2,24p' "$0"; exit 0 ;;
    -*)               echo "unknown flag: $1" >&2; exit 2 ;;
    *)                ROBOT_IP="$1" ;;
  esac
  shift
done

SIM_FLAG=(); [ "$SIM" -eq 1 ] && SIM_FLAG=(--simulate)

# --- preflight ------------------------------------------------------------
echo "== preflight =="
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 2; }
[ -f "$PLAYER" ] || { echo "error: missing player $PLAYER" >&2; exit 2; }
[ -f "$TSV" ]    || { echo "error: missing prompts $TSV" >&2; exit 2; }

if [ "$SIM" -eq 0 ]; then
  [ -n "$ROBOT_IP" ] || { echo "error: ROBOT_IP required (arg or G1_ROBOT_IP). Or use --simulate." >&2; exit 2; }
  [ -n "$IFACE" ]    || { echo "error: --iface required (NIC reaching the robot). Find with: ip -br addr" >&2; exit 2; }
  if python3 -c "import unitree_sdk2py" 2>/dev/null; then
    echo "  unitree_sdk2py: ok"
  else
    echo "  unitree_sdk2py: NOT importable — install it (pip install unitree_sdk2py) or run --simulate" >&2
    exit 2
  fi
  if ping -c1 -W2 "$ROBOT_IP" >/dev/null 2>&1; then echo "  ping $ROBOT_IP: ok"; else echo "  ping $ROBOT_IP: no reply (continuing; DDS may still work)"; fi
  echo "  testing AudioClient reachability..."
  if ! python3 "$PLAYER" --iface "$IFACE" ping; then
    echo "error: could not reach the G1 AudioClient on iface '$IFACE'. Check IP/interface/firmware." >&2
    exit 2
  fi
else
  echo "  MODE: simulate (no robot, no SDK)"
fi

# clips present? (only needed when NOT using --tts)
if [ "$USE_TTS" -eq 0 ] && [ "$SIM" -eq 0 ]; then
  if [ ! -d "$CLIPS" ] || [ -z "$(ls -A "$CLIPS"/*.wav 2>/dev/null || true)" ]; then
    echo "error: no generated clips in $CLIPS — run ./scripts/generate_voices.sh first (or use --tts)." >&2
    exit 2
  fi
fi

# --- confirm (real robot, real playback) ----------------------------------
if [ "$SIM" -eq 0 ] && [ "$DRY" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  echo
  echo "About to play the custom voice on the REAL robot at $ROBOT_IP."
  printf "Proceed? [y/N] "; read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted."; exit 0 ;; esac
fi

# set volume once
if [ -n "$VOLUME" ] && [ "$DRY" -eq 0 ]; then
  echo "== volume =="; python3 "$PLAYER" ${SIM_FLAG[@]+"${SIM_FLAG[@]}"} --iface "$IFACE" volume "$VOLUME" || true
fi

# --- run ------------------------------------------------------------------
echo "== applying voice =="
ts() { date -Iseconds 2>/dev/null || date; }
echo "# deploy $(ts) robot=$ROBOT_IP iface=$IFACE tts=$USE_TTS only=${ONLY:-all}" >> "$LOG"

n_ok=0; n_skip=0; n_fail=0
{
  read -r _hdr
  while IFS=$'\t' read -r id event risk text voice_id || [ -n "${id:-}" ]; do
    id="${id%$'\r'}"; risk="${risk%$'\r'}"; text="${text%$'\r'}"
    [ -z "${id:-}" ] && continue
    [ -n "$ONLY" ] && [ "$id" != "$ONLY" ] && continue

    # safety tier L3 is skipped unless explicitly included
    if [ "$risk" = "L3" ] && [ "$INCLUDE_SAFETY" -ne 1 ]; then
      printf 'skip   %-4s %-18s [L3 safety — use --include-safety]\n' "$id" "$event"
      n_skip=$((n_skip + 1)); continue
    fi

    wav="$CLIPS/${id}.wav"
    if [ "$USE_TTS" -eq 0 ] && [ ! -f "$wav" ]; then
      printf 'skip   %-4s %-18s [no WAV — run generate_voices.sh]\n' "$id" "$event"
      n_skip=$((n_skip + 1)); continue
    fi

    if [ "$DRY" -eq 1 ]; then
      if [ "$USE_TTS" -eq 1 ]; then printf 'would  %-4s %-18s TTS "%s"\n' "$id" "$event" "$text"
      else printf 'would  %-4s %-18s play %s\n' "$id" "$event" "${wav#$ROOT/}"; fi
      n_ok=$((n_ok + 1)); continue
    fi

    printf 'apply  %-4s %-18s ' "$id" "$event"
    if [ "$USE_TTS" -eq 1 ]; then
      if python3 "$PLAYER" ${SIM_FLAG[@]+"${SIM_FLAG[@]}"} --iface "$IFACE" tts "$text" --speaker "$SPEAKER" >/dev/null; then
        echo "tts ok"; echo "$(ts) $id $event tts ok" >> "$LOG"; n_ok=$((n_ok + 1))
      else echo "TTS FAILED"; echo "$(ts) $id $event tts FAIL" >> "$LOG"; n_fail=$((n_fail + 1)); fi
    else
      if python3 "$PLAYER" ${SIM_FLAG[@]+"${SIM_FLAG[@]}"} --iface "$IFACE" play "$wav" >/dev/null; then
        echo "played"; echo "$(ts) $id $event play ok" >> "$LOG"; n_ok=$((n_ok + 1))
      else echo "PLAY FAILED"; echo "$(ts) $id $event play FAIL" >> "$LOG"; n_fail=$((n_fail + 1)); fi
    fi
  done
} < "$TSV"

echo
echo "summary: ok=$n_ok skipped=$n_skip failed=$n_fail   (log: ${LOG#$ROOT/})"
[ "$n_fail" -eq 0 ]
