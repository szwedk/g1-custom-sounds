#!/usr/bin/env bash
# Launcher for Voice Studio running on the robot's development computer.
#
# PYTHONPATH points at a vendored unitree_sdk2_python that provides
# AudioClient.PlayStream. XDG_RUNTIME_DIR lets paplay/pactl reach PulseAudio
# for the optional USB output.
#
# Adjust IFACE to the DDS network interface on your robot.

IFACE="${G1_IFACE:-eth0}"

export PYTHONPATH="$HOME/g1-voice-studio/vendor/unitree_sdk2_python:$PYTHONPATH"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

cd "$HOME/g1-voice-studio"
exec python3 voice/app/server.py --on-robot --iface "$IFACE" --port 8766
