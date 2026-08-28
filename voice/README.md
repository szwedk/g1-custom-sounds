# voice

Voice Studio and the prompt catalog. Audio is played through the `unitree_sdk2`
`AudioClient`; nothing on the robot's filesystem is modified. See
[`../docs/audio-architecture.md`](../docs/audio-architecture.md) for background,
and [`deploy/`](deploy) for running this on the robot itself.

## Layout

```
prompts.tsv          event -> English line catalog
config.example.sh    copy to config.sh (ElevenLabs key, robot IP, interface)
generated/           rendered 16 kHz mono WAVs, one per prompt id (ignored by git)
library/             uploaded, recorded and generated clips (ignored by git)
app/server.py        Voice Studio server (standard library only, binds localhost)
app/static/          Voice Studio UI
lib/g1_play.py       AudioClient wrapper: ping / volume / tts / play
deploy/              robot-side launcher and systemd unit
```

## Voice Studio

```bash
./scripts/voice_studio.sh --simulate               # no robot required
./scripts/voice_studio.sh <ROBOT_IP> --iface eth0
```

- **Sound library** — upload mp3/m4a/wav/ogg; clips are converted to 16 kHz mono
  16-bit, previewable in the browser and playable on the robot.
- **Record** — capture from the microphone with a level meter.
- **Text to speech** — speak a line on the robot, or render it with ElevenLabs
  (requires `ELEVENLABS_API_KEY`) and keep it in the library.
- **Speaker** — volume with a software boost range above the hardware maximum,
  plus a test tone. When a USB audio device is present, playback goes to both
  outputs with an adjustable sync offset.
- **Save to robot** — copies clips to `~/g1_custom_sounds/` on the robot so they
  survive reboots. Running off-robot uses SSH and needs key authentication.

## Prompt catalog

```bash
./scripts/generate_voices.sh --dry-run    # preview, with a character-cost estimate
./scripts/generate_voices.sh              # render to generated/
./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0 --only P01
./scripts/deploy_g1_voice.sh <ROBOT_IP> --iface eth0
```

`prompts.tsv` is tab-separated:

| Column | Meaning |
|--------|---------|
| `id` | Stable key, and the generated filename (`P08` to `generated/P08.wav`) |
| `event` | The robot event the line corresponds to |
| `risk` | `L1` cosmetic, `L2` informational, `L3` safety-related |
| `text` | The line to speak |
| `voice_id` | Optional ElevenLabs voice override; blank uses `EL_VOICE_ID` |

`L3` entries are skipped unless `--include-safety` is passed. After editing the
text, re-run `generate_voices.sh`; only missing or changed ids are rendered
(`--force` re-renders regardless).
