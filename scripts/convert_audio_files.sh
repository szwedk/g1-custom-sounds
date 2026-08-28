#!/usr/bin/env bash
# convert_audio_files.sh — convert one custom recording to match an original
#
# Reads the format of a target file (the original Chinese prompt) with ffprobe,
# then re-encodes a source recording (your English replacement) to match its
# codec / sample rate / bit depth / channel count and writes the result to the
# replacement-audio/converted/ folder.
#
# Run this on your workstation (not the robot) — ffmpeg is required.
#
# Usage:
#   ./convert_audio_files.sh <source-recording> <target-original>
#   ./convert_audio_files.sh ./replacement-audio/wav/low_battery_en.wav \
#                            ./original-backups/.../low_battery.wav

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <source-recording> <target-original-file>" >&2
  exit 2
fi

SRC="$1"
TARGET="$2"

for f in "$SRC" "$TARGET"; do
  [ -f "$f" ] || { echo "error: missing file: $f" >&2; exit 2; }
done

command -v ffmpeg  >/dev/null || { echo "ffmpeg not found"  >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "ffprobe not found" >&2; exit 2; }

# Probe the target's format. ffprobe emits fields in its own canonical order,
# so parse by key rather than by position.
CODEC=""; SR=""; BD=""; CH=""; FMT=""
while IFS='=' read -r k v; do
  case "$k" in
    codec_name)       CODEC="$v" ;;
    sample_rate)      SR="$v"    ;;
    bits_per_sample)  BD="$v"    ;;
    channels)         CH="$v"    ;;
    format_name)      FMT="$v"   ;;
  esac
done < <(ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,bits_per_sample,channels \
  -show_entries format=format_name \
  -of default=noprint_wrappers=1 "$TARGET")

CODEC="${CODEC:-pcm_s16le}"
SR="${SR:-16000}"
CH="${CH:-1}"
FMT="${FMT:-wav}"
# bits_per_sample is reported as 0 for compressed codecs (mp3/vorbis/aac);
# it is only meaningful for PCM. Default it sanely so it is never empty/0.
case "$BD" in ''|0) BD=16 ;; esac

OUTDIR="./replacement-audio/converted"
mkdir -p "$OUTDIR"
BASENAME="$(basename "$TARGET")"     # produce a file with the EXACT same name
OUT="$OUTDIR/$BASENAME"

echo "Target format probed:"
echo "  codec=$CODEC  sample_rate=$SR  bit_depth=$BD  channels=$CH  container=$FMT"
echo "Converting:"
echo "  $SRC  ->  $OUT"

# Map common codecs onto ffmpeg encoder + container choices
case "$CODEC" in
  pcm_s16le|pcm_s24le|pcm_s32le|pcm_u8|pcm_f32le)
    ENC=( -c:a "$CODEC" -ar "$SR" -ac "$CH" )
    EXT="wav"
    ;;
  mp3)
    ENC=( -c:a libmp3lame -b:a 96k -ar "$SR" -ac "$CH" )
    EXT="mp3"
    ;;
  vorbis|libvorbis)
    ENC=( -c:a libvorbis -ar "$SR" -ac "$CH" )
    EXT="ogg"
    ;;
  flac)
    ENC=( -c:a flac -ar "$SR" -ac "$CH" )
    EXT="flac"
    ;;
  aac)
    ENC=( -c:a aac -b:a 96k -ar "$SR" -ac "$CH" )
    EXT="m4a"
    ;;
  *)
    # Default to 16-bit PCM in a WAV container, matched sample rate / channels.
    echo "warn: unknown codec '$CODEC', falling back to pcm_s16le WAV" >&2
    ENC=( -c:a pcm_s16le -ar "$SR" -ac "$CH" )
    EXT="wav"
    ;;
esac

# Loudness-normalize lightly so the new voice does not blow out the speaker.
# EBU R128 target -16 LUFS. Tweak per your taste.
FILTER=( -af "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=$SR" )

ffmpeg -y -hide_banner -loglevel warning \
  -i "$SRC" "${FILTER[@]}" "${ENC[@]}" "$OUT"

echo
echo "Converted file ready: $OUT"
echo "Verifying with ffprobe:"
ffprobe -v error -show_streams -show_format "$OUT" \
  | grep -E '^(codec_name|sample_rate|bits_per_sample|channels|duration|format_name)='

# Compare durations as a sanity check
DUR_SRC=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
DUR_OUT=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
DUR_TGT=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TARGET")
echo
printf 'duration source:%s  target:%s  converted:%s (seconds)\n' "$DUR_SRC" "$DUR_TGT" "$DUR_OUT"
