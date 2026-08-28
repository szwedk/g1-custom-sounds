#!/usr/bin/env bash
# test_playback.sh — safe local playback probe for a single audio file
#
# Plays a file through the robot's default audio device using whichever tool
# is available. Does NOT change any system files. Does NOT touch services.
#
# Usage:
#   ./test_playback.sh <audio-file> [device]
#
#   ./test_playback.sh ./replacement-audio/converted/low_battery.wav
#   ./test_playback.sh ./replacement-audio/converted/low_battery.wav hw:0,0

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <audio-file> [alsa-device]" >&2
  exit 2
fi

FILE="$1"
DEV="${2:-}"
[ -f "$FILE" ] || { echo "error: file not found: $FILE" >&2; exit 2; }

echo "== probing file =="
file "$FILE"
ffprobe -v error -show_streams -show_format "$FILE" 2>/dev/null \
  | grep -E '^(codec_name|sample_rate|bits_per_sample|channels|duration|format_name)='

echo
echo "== choosing player =="
PLAYER=""
for p in aplay paplay ffplay mpg123 pw-play; do
  if command -v "$p" >/dev/null 2>&1; then PLAYER="$p"; break; fi
done
if [ -z "$PLAYER" ]; then
  echo "no audio player found (tried aplay paplay ffplay mpg123 pw-play)" >&2
  exit 3
fi
echo "using: $PLAYER"

echo
echo "== playing =="
case "$PLAYER" in
  aplay)
    if [ -n "$DEV" ]; then aplay -D "$DEV" -q "$FILE"
    else aplay -q "$FILE"
    fi
    ;;
  paplay)
    paplay "$FILE"
    ;;
  ffplay)
    ffplay -nodisp -autoexit -loglevel error "$FILE"
    ;;
  mpg123)
    mpg123 -q "$FILE"
    ;;
  pw-play)
    pw-play "$FILE"
    ;;
esac

echo
echo "done."
echo "If you heard nothing:"
echo "  - check volume:    amixer -c 0 sget Master  (or pactl list sinks)"
echo "  - check device:    aplay -l   (then re-run with the right -D hw:X,Y)"
echo "  - check who holds the device:  sudo fuser -v /dev/snd/*"
