#!/usr/bin/env bash
# scan_sound_references.sh — read-only search for code that plays or names sounds
#
# Greps shell scripts, Python, C/C++, configs, launch files, and systemd units
# for keywords that indicate audio playback or references to sound assets.
#
# Run on the G1 over SSH. Read-only.
#
# Usage:
#   ./scan_sound_references.sh                # default roots
#   ./scan_sound_references.sh /opt /unitree  # custom roots

set -u
set -o pipefail

DEFAULT_ROOTS=(
  /unitree
  /opt
  /usr/local
  /etc/systemd
  /lib/systemd
  /home
  /root
)

# Keywords. Two groups: playback commands, and semantic words.
PLAYBACK_CMDS=(
  'aplay' 'paplay' 'ffplay' 'mpg123' 'mpv' 'ogg123' 'play\b' 'sox\b'
  'pw-play' 'pacat' 'gst-launch' 'speaker-test'
  'PlaySound' 'play_sound' 'playSound' 'playAudio' 'play_audio'
  'snd_pcm_open' 'snd_pcm_writei'
)

SEMANTIC=(
  'voice' 'prompt' 'tts' 'sound' 'audio' 'speech' 'speaker'
  'startup\s*sound' 'error\s*sound' 'battery' 'chime' 'beep'
  'app\s*connect' 'low\s*power' 'damping' 'emergency'
  '提示' '语音' '声音'      # zh: "prompt", "voice", "sound"
)

EXTENSIONS=(wav mp3 ogg flac pcm raw aac m4a opus)

PRUNE_PATHS=( /proc /sys /dev /run /snap /tmp /var/cache /var/log )

# --- Setup ---------------------------------------------------------------

ROOTS=("${@:-${DEFAULT_ROOTS[@]}}")
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname)"
OUTDIR="./scan-results"
mkdir -p "$OUTDIR"

PLAYBACK_HITS="$OUTDIR/refs-playback-${HOST}-${TS}.txt"
SEMANTIC_HITS="$OUTDIR/refs-semantic-${HOST}-${TS}.txt"
EXT_HITS="$OUTDIR/refs-extensions-${HOST}-${TS}.txt"
SUMMARY="$OUTDIR/refs-${HOST}-${TS}.summary.txt"

EXISTING_ROOTS=()
for r in "${ROOTS[@]}"; do [ -e "$r" ] && EXISTING_ROOTS+=( "$r" ); done
if [ ${#EXISTING_ROOTS[@]} -eq 0 ]; then
  echo "No requested roots exist on this host." | tee "$SUMMARY"
  exit 0
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo"; fi
fi

# Build prune args for find
prune_expr=()
for p in "${PRUNE_PATHS[@]}"; do prune_expr+=( -path "$p" -prune -o ); done

# Use ripgrep if present, else grep -rIn.
if command -v rg >/dev/null 2>&1; then
  RG=(rg --no-messages --hidden --line-number --with-filename
      --type-add 'unit:*.service' --type-add 'unit:*.timer'
      --type-add 'launch:*.launch' --type-add 'launch:*.launch.py'
      -t sh -t py -t c -t cpp -t yaml -t json -t toml -t conf -t cfg -t ini
      -t md -t unit -t launch)
  use_rg=1
else
  use_rg=0
fi

run_grep() {
  local pattern="$1" outfile="$2"
  if [ $use_rg -eq 1 ]; then
    $SUDO "${RG[@]}" -e "$pattern" "${EXISTING_ROOTS[@]}" 2>/dev/null >> "$outfile" || true
  else
    $SUDO grep -RInE --binary-files=without-match \
      --include='*.sh' --include='*.py' --include='*.c' --include='*.cc' \
      --include='*.cpp' --include='*.h' --include='*.hpp' \
      --include='*.yaml' --include='*.yml' --include='*.json' --include='*.toml' \
      --include='*.conf' --include='*.cfg' --include='*.ini' --include='*.md' \
      --include='*.service' --include='*.timer' --include='*.launch' --include='*.launch.py' \
      --exclude-dir=.git --exclude-dir=node_modules \
      -e "$pattern" "${EXISTING_ROOTS[@]}" 2>/dev/null >> "$outfile" || true
  fi
}

echo "# scan_sound_references.sh"
echo "# host=$HOST  user=$(whoami)  started=$(date -Iseconds)"
echo "# roots: ${EXISTING_ROOTS[*]}"
echo

: > "$PLAYBACK_HITS"
: > "$SEMANTIC_HITS"
: > "$EXT_HITS"

echo "[1/3] playback command references..."
for kw in "${PLAYBACK_CMDS[@]}"; do
  echo "## pattern: $kw" >> "$PLAYBACK_HITS"
  run_grep "$kw" "$PLAYBACK_HITS"
  echo >> "$PLAYBACK_HITS"
done

echo "[2/3] semantic keyword references..."
for kw in "${SEMANTIC[@]}"; do
  echo "## pattern: $kw" >> "$SEMANTIC_HITS"
  run_grep "$kw" "$SEMANTIC_HITS"
  echo >> "$SEMANTIC_HITS"
done

echo "[3/3] inline audio-filename references..."
for ext in "${EXTENSIONS[@]}"; do
  echo "## pattern: \\.${ext}" >> "$EXT_HITS"
  run_grep "\\.${ext}\b" "$EXT_HITS"
  echo >> "$EXT_HITS"
done

# --- Summary -------------------------------------------------------------

{
  echo "Reference scan summary"
  echo "======================"
  echo "Host:    $HOST"
  echo "User:    $(whoami)"
  echo "Started: $(date -Iseconds)"
  echo "Roots:   ${EXISTING_ROOTS[*]}"
  echo
  echo "Files with playback-command hits (unique):"
  grep -vE '^(##|$)' "$PLAYBACK_HITS" | cut -d: -f1 | sort -u | tee >(wc -l | xargs -I{} echo "  total: {}" >&2)
  echo
  echo "Files with semantic-keyword hits (unique):"
  grep -vE '^(##|$)' "$SEMANTIC_HITS" | cut -d: -f1 | sort -u
  echo
  echo "Files with inline audio-filename hits (unique):"
  grep -vE '^(##|$)' "$EXT_HITS" | cut -d: -f1 | sort -u
} > "$SUMMARY" 2>/dev/null

echo "Done."
echo "Playback refs:  $PLAYBACK_HITS"
echo "Semantic refs:  $SEMANTIC_HITS"
echo "Extension refs: $EXT_HITS"
echo "Summary:        $SUMMARY"
