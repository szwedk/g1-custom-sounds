#!/usr/bin/env bash
# scan_audio_files.sh — read-only audio discovery for the Unitree G1.
#
# Walks the filesystem for audio files and classifies each one:
#   1. validates by MIME type (file --mime-type), not just file extension;
#   2. annotates it with its owning dpkg package (or UNOWNED);
#   3. emits a candidates list = real audio not owned by any OS package.
#
# Stock distribution audio is therefore filtered out, leaving only files that are
# specific to this robot. The G1's own voice prompts are generated at runtime and
# will not appear here; see docs/audio-architecture.md.
#
# Usage:
#   ./scan_audio_files.sh                  # default roots
#   ./scan_audio_files.sh /unitree /opt    # custom roots

set -u
set -o pipefail

EXTENSIONS=(wav mp3 ogg flac pcm raw aac m4a opus wma aiff aif)
DEFAULT_ROOTS=(/unitree /opt /usr/local /usr/share /home /root /etc /var/lib /lib/firmware)
PRUNE_PATHS=(/proc /sys /dev /run /snap /var/cache /var/log /var/tmp /tmp /mnt /media /lost+found)

ROOTS=("$@"); [ ${#ROOTS[@]} -eq 0 ] && ROOTS=("${DEFAULT_ROOTS[@]}")

TS="$(date +%Y%m%d_%H%M%S)"; HOST="$(hostname)"
OUTDIR="./scan-results"; mkdir -p "$OUTDIR"
ALL="$OUTDIR/audio-all-${HOST}-${TS}.tsv"
CAND="$OUTDIR/audio-candidates-${HOST}-${TS}.tsv"
SUMMARY="$OUTDIR/audio-${HOST}-${TS}.summary.txt"

have_dpkg=0; command -v dpkg >/dev/null 2>&1 && have_dpkg=1
have_file=0; command -v file >/dev/null 2>&1 && have_file=1

SUDO=""
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then SUDO="sudo"; fi

EXISTING=(); for r in "${ROOTS[@]}"; do [ -e "$r" ] && EXISTING+=("$r"); done
[ ${#EXISTING[@]} -eq 0 ] && { echo "no roots exist" | tee "$SUMMARY"; exit 0; }

# find expr
prune=(); for p in "${PRUNE_PATHS[@]}"; do prune+=( -path "$p" -prune -o ); done
ext=( '(' ); first=1
for e in "${EXTENSIONS[@]}"; do
  if [ $first -eq 1 ]; then ext+=( -iname "*.${e}" ); first=0; else ext+=( -o -iname "*.${e}" ); fi
done; ext+=( ')' )

printf 'path\tsize\towner\tmode\tmtime\text\tmime\tdpkg_pkg\tclass\n' | tee "$ALL" >"$CAND"

$SUDO find "${EXISTING[@]}" -xdev "${prune[@]}" -type f "${ext[@]}" \
  -printf '%p\t%s\t%u:%g\t%m\t%TY-%Tm-%TdT%TH:%TM:%TS\n' 2>/dev/null |
while IFS=$'\t' read -r path size owner mode mtime; do
  e="${path##*.}"; e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"

  if [ $have_file -eq 1 ]; then
    mime="$($SUDO file --mime-type -b "$path" 2>/dev/null || echo unknown)"
  else
    mime="unchecked"
  fi
  case "$mime" in audio/*|application/ogg) is_audio=1 ;; unchecked) is_audio=1 ;; *) is_audio=0 ;; esac

  if [ $have_dpkg -eq 1 ]; then
    pkg="$($SUDO dpkg -S "$path" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -z "$pkg" ] && pkg="UNOWNED"
  else
    pkg="no-dpkg"
  fi

  if   [ "$is_audio" -eq 0 ];                       then class="NONAUDIO"
  elif [ "$pkg" != "UNOWNED" ] && [ "$pkg" != "no-dpkg" ]; then class="STOCK_PKG"
  else                                                   class="CANDIDATE"
  fi

  # Write directly with a trailing newline. (Do NOT round-trip through
  # row="$(printf ... \n)" — command substitution strips the trailing newline,
  # which would glue every record onto one line and make the counts always read 0.)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$size" "$owner" "$mode" "$mtime" "$e" "$mime" "$pkg" "$class" >>"$ALL"
  if [ "$class" = "CANDIDATE" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$path" "$size" "$owner" "$mode" "$mtime" "$e" "$mime" "$pkg" "$class" >>"$CAND"
  fi
done

{
  echo "Audio discovery v2 — $HOST $TS"
  echo "================================"
  echo "Roots: ${EXISTING[*]}"
  [ $have_file -eq 0 ] && echo "WARN: 'file' not installed — MIME not validated."
  [ $have_dpkg -eq 0 ] && echo "WARN: 'dpkg' not available — package ownership not checked."
  echo
  echo "By classification:"
  tail -n +2 "$ALL" | cut -f9 | sort | uniq -c | sort -rn
  echo
  echo "Stock noise by package:"
  tail -n +2 "$ALL" | awk -F'\t' '$9=="STOCK_PKG"{print $8}' | sort | uniq -c | sort -rn
  echo
  echo "CANDIDATES (the only list to act on — unowned, real audio):"
  tail -n +2 "$CAND" | cut -f1 || true
  cand_n=$(($(wc -l < "$CAND") - 1)); [ "$cand_n" -lt 0 ] && cand_n=0
  echo
  echo "candidate count: $cand_n"
  if [ "$cand_n" -eq 0 ]; then
    echo "=> No on-disk voice files. Expected: the G1 voice is API-driven."
    echo "   Next: confirm the voice service + AudioClient (see docs/audio-architecture.md),"
    echo "   then use scripts/deploy_g1_voice.sh."
  fi
} | tee "$SUMMARY"

echo
echo "all:        $ALL"
echo "candidates: $CAND"
echo "summary:    $SUMMARY"
