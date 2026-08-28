#!/usr/bin/env bash
# voice_studio.sh — launch the G1 Voice Studio web GUI.
#
# A local web app (127.0.0.1) for managing the G1's custom sounds:
# record / upload / generate sounds, speak text on the robot, test the chest
# speaker with a volume knob, and save sounds permanently onto the robot's disk.
#
# Usage:
#   ./scripts/voice_studio.sh --simulate                 # no robot needed
#   ./scripts/voice_studio.sh <ROBOT_IP> --iface eth0    # live robot
#   ./scripts/voice_studio.sh                            # uses voice/config.sh values
#
# The URL is printed on startup (default http://127.0.0.1:8766).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/voice/config.sh" ] && . "$ROOT/voice/config.sh"

ROBOT_IP="${G1_ROBOT_IP:-}"
IFACE="${G1_IFACE:-}"
PORT="${PORT:-8766}"
SIM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --simulate) SIM=1 ;;
    --iface)    [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --iface needs a value" >&2; exit 2; }; IFACE="$2"; shift 2; continue ;;
    --port)     [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "error: --port needs a value" >&2; exit 2; }; PORT="$2"; shift 2; continue ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    -*)         echo "unknown flag: $1" >&2; exit 2 ;;
    *)          ROBOT_IP="$1" ;;
  esac
  shift
done

command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 2; }
command -v ffmpeg  >/dev/null || { echo "error: ffmpeg not found (needed for audio conversion)" >&2; exit 2; }

ARGS=( "--port" "$PORT" )
[ "$SIM" -eq 1 ]     && ARGS+=( "--simulate" )
[ -n "$ROBOT_IP" ]   && ARGS+=( "--robot-ip" "$ROBOT_IP" )
[ -n "$IFACE" ]      && ARGS+=( "--iface" "$IFACE" )

exec python3 "$ROOT/voice/app/server.py" "${ARGS[@]}"
