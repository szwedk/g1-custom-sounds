# voice/config.example.sh — copy to voice/config.sh and edit, OR set these as env vars.
#
#   cp voice/config.sh.example voice/config.sh   # then edit
#   # voice/config.sh is git-ignored so your API key never gets committed.
#
# Both generate_voices.sh and deploy_g1_voice.sh source voice/config.sh if it exists.

# --- ElevenLabs (voice generation) ----------------------------------------

# Your ElevenLabs API key. REQUIRED to generate audio. Keep it secret.
# Get one at https://elevenlabs.io/  ->  Profile  ->  API Keys.
export ELEVENLABS_API_KEY=""

# Default voice used for any prompt row that leaves the voice_id column blank.
# JBFqnCBsd6RMkjVDRZzb = "George"  (British male, warm/narration)
# pFZP5JQG7iQjIQuC4Bku = "Lily"    (British female, warm/narration)
export EL_VOICE_ID="JBFqnCBsd6RMkjVDRZzb"

# eleven_multilingual_v2 = best quality (1 credit/char)
# eleven_flash_v2_5      = ~half the cost, faster (0.5 credit/char)
export EL_MODEL="eleven_multilingual_v2"

# Voice character. 0.0-1.0 each. Defaults are sane for short prompts.
export EL_STABILITY="0.5"
export EL_SIMILARITY="0.75"
export EL_STYLE="0"

# --- Robot (deployment) ----------------------------------------------------

# The G1's IP on the network you share with it, and the network interface on
# THIS machine that reaches the robot's DDS network (find with: ip -br addr).
# Leave blank to require them on the command line instead.
export G1_ROBOT_IP=""
export G1_IFACE=""

# Speaker volume to set on deploy (0-100). Blank = leave the robot's volume as-is.
export G1_VOLUME="85"
