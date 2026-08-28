#!/usr/bin/env bash
# generate_voices.sh — render each prompt in voice/prompts.tsv to a robot-ready WAV
# using the ElevenLabs text-to-speech API.
#
# Output: voice/generated/<id>.wav  (16 kHz, mono, 16-bit PCM — exactly what the
# G1 AudioClient.PlayStream expects), lightly loudness-normalized.
#
# Idempotent: a row whose <id>.wav already exists is skipped (use --force to redo).
# Safe to re-run; only missing/failed clips are (re)generated.
#
# Runs on your workstation (not the robot). Needs: curl, jq, ffmpeg, and an
# ELEVENLABS_API_KEY (see voice/config.example.sh).
#
# Usage:
#   ./scripts/generate_voices.sh                 # generate all missing clips
#   ./scripts/generate_voices.sh --dry-run       # show what would happen + cost estimate
#   ./scripts/generate_voices.sh --only P08       # just one prompt id
#   ./scripts/generate_voices.sh --force          # regenerate even if the WAV exists
#   ./scripts/generate_voices.sh path/to/other.tsv

set -euo pipefail

# --- locate repo + config -------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/voice/config.sh" ] && . "$ROOT/voice/config.sh"

# --- defaults (overridable via env / config.sh) ---------------------------
EL_API="${ELEVENLABS_API_KEY:-}"
EL_VOICE_ID="${EL_VOICE_ID:-JBFqnCBsd6RMkjVDRZzb}"   # George (British male)
EL_MODEL="${EL_MODEL:-eleven_multilingual_v2}"
EL_STABILITY="${EL_STABILITY:-0.5}"
EL_SIMILARITY="${EL_SIMILARITY:-0.75}"
EL_STYLE="${EL_STYLE:-0}"
OUTDIR="$ROOT/voice/generated"

# --- args -----------------------------------------------------------------
DRY=0; FORCE=0; ONLY=""; TSV="$ROOT/voice/prompts.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --only)    [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --only needs a prompt id" >&2; exit 2; }; ONLY="$2"; shift 2; continue ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *.tsv)     TSV="$1" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$TSV" ] || { echo "error: prompts file not found: $TSV" >&2; exit 2; }

# --- dependency check -----------------------------------------------------
for dep in curl jq ffmpeg; do
  command -v "$dep" >/dev/null || { echo "error: '$dep' is required but not installed." >&2; exit 2; }
done

# credit cost per character depends on the model
case "$EL_MODEL" in
  *flash*|*turbo*) PER_CHAR="0.5" ;;
  *)               PER_CHAR="1"   ;;
esac

# The voice-setting knobs go into the JSON body via jq --argjson, which aborts the
# whole run on a non-numeric value (blank, locale comma, stray text). Validate them
# up front with a clear message instead of a cryptic jq stack trace mid-loop.
for pair in "EL_STABILITY=$EL_STABILITY" "EL_SIMILARITY=$EL_SIMILARITY" "EL_STYLE=$EL_STYLE"; do
  name="${pair%%=*}"; val="${pair#*=}"
  case "$val" in
    ''|*[!0-9.]*) echo "error: $name must be a number like 0.5 (got '$val'). Check voice/config.sh" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUTDIR"

echo "prompts:   $TSV"
echo "model:     $EL_MODEL   (~$PER_CHAR credit/char)"
echo "voice:     $EL_VOICE_ID (default; per-row override wins)"
echo "out:       $OUTDIR"
[ "$DRY" -eq 1 ] && echo "MODE:      dry-run (no API calls, no files written)"
echo

# --- iterate --------------------------------------------------------------
total_chars=0; n_make=0; n_skip=0; n_fail=0

# Read TSV; skip header. read assigns the row by tab. Strip any CR.
{
  read -r _hdr  # discard header line
  while IFS=$'\t' read -r id event risk text voice_id || [ -n "${id:-}" ]; do
    id="${id%$'\r'}"; voice_id="${voice_id%$'\r'}"; text="${text%$'\r'}"
    [ -z "${id:-}" ] && continue
    [ -n "$ONLY" ] && [ "$id" != "$ONLY" ] && continue

    vid="${voice_id:-$EL_VOICE_ID}"
    out="$OUTDIR/${id}.wav"
    chars=${#text}
    total_chars=$((total_chars + chars))

    if [ -f "$out" ] && [ "$FORCE" -ne 1 ]; then
      printf 'skip   %-4s %-18s (exists)\n' "$id" "$event"
      n_skip=$((n_skip + 1))
      continue
    fi

    if [ "$DRY" -eq 1 ]; then
      printf 'would  %-4s %-18s [%s] %3d chars  "%s"\n' "$id" "$event" "$risk" "$chars" "$text"
      n_make=$((n_make + 1))
      continue
    fi

    if [ -z "$EL_API" ]; then
      echo "error: ELEVENLABS_API_KEY is not set (needed to generate). See voice/config.example.sh" >&2
      exit 2
    fi

    printf 'build  %-4s %-18s [%s] voice=%s\n' "$id" "$event" "$risk" "$vid"

    raw="$(mktemp)"; tmpwav="${out}.tmp"
    body="$(jq -Rn --arg t "$text" --arg m "$EL_MODEL" \
            --argjson st "$EL_STABILITY" --argjson sb "$EL_SIMILARITY" --argjson sy "$EL_STYLE" \
            '{text:$t, model_id:$m,
              voice_settings:{stability:$st, similarity_boost:$sb, style:$sy, use_speaker_boost:true}}')"

    http="$(curl -sS -w '%{http_code}' -o "$raw" -X POST \
      "https://api.elevenlabs.io/v1/text-to-speech/${vid}?output_format=pcm_16000" \
      -H "xi-api-key: $EL_API" -H "Content-Type: application/json" \
      --data "$body" || echo "000")"

    if [ "$http" != "200" ]; then
      echo "  FAILED ($id): HTTP $http — $(head -c 300 "$raw" 2>/dev/null)" >&2
      rm -f "$raw"; n_fail=$((n_fail + 1)); continue
    fi

    # Wrap raw 16k mono S16LE PCM into a WAV + light EBU R128 loudness normalize.
    # Write to .tmp then atomic-rename so a crash never leaves a half file that
    # would wrongly satisfy the skip-if-exists check on the next run.
    if ffmpeg -hide_banner -loglevel error -y \
         -f s16le -ar 16000 -ac 1 -i "$raw" \
         -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
         -ar 16000 -ac 1 -c:a pcm_s16le "$tmpwav"; then
      mv -f "$tmpwav" "$out"
      printf '  ok -> %s\n' "${out#$ROOT/}"
      n_make=$((n_make + 1))
    else
      echo "  FAILED ($id): ffmpeg wrap error" >&2
      rm -f "$tmpwav"; n_fail=$((n_fail + 1))
    fi
    rm -f "$raw"
  done
} < "$TSV"

echo
echo "summary: made=$n_make skipped=$n_skip failed=$n_fail"
if [ "$DRY" -eq 1 ]; then
  est=$(awk -v c="$total_chars" -v p="$PER_CHAR" 'BEGIN{printf "%.0f", c*p}')
  echo "estimate: $total_chars characters total  ~= $est ElevenLabs credits at this model"
fi
[ "$n_fail" -eq 0 ]
