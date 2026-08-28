# G1 audio architecture

Reference for how audio actually works on the Unitree G1, and why this project
drives the speaker through the SDK rather than replacing files on disk.

## The voice is not a file

The G1's spoken prompts are synthesized at runtime by an on-board service
(`voice` / `Vui_Service`). There is no directory of prompt audio to overwrite: a
filesystem scan of the development computer turns up only stock Ubuntu desktop
audio (`alsa-utils` test clips, the Debian `sound-icons` set, GNOME alert sounds,
`speech-dispatcher` fixtures), none of which the robot ever plays.

To confirm this on any given robot, classify each discovered file by package
ownership — `dpkg -S <path>`. Files owned by a distribution package are stock OS
audio and can be ignored. `scripts/scan_audio_files.sh` automates this and
additionally validates by MIME type, so non-audio files (e.g. a `COPYING.opus`
licence text) are not reported as candidates.

## Two computers, one speaker

The G1 has two on-board computers:

| Computer | Role | Audio |
|----------|------|-------|
| Jetson Orin NX | development / user code | No speaker amplifier. Local ALSA cannot drive the chest speaker. |
| RockChip control PC | robot control | Owns the chest speaker and the `voice` service. |

The chest speaker is reachable only through the `unitree_sdk2` `AudioClient`
over DDS. `aplay`, `paplay` and ALSA mixer routing on the Jetson cannot reach it.

## AudioClient API

| Call | Purpose |
|------|---------|
| `TtsMaker(text, speaker_id)` | On-board TTS. `speaker_id` 0 = Chinese, 1 = English. |
| `PlayStream(app_name, stream_id, pcm)` | Stream arbitrary PCM to the speaker. |
| `PlayStop(app_name)` | Interrupt playback. |
| `GetVolume()` / `SetVolume(0-100)` | Speaker volume. |
| `LedControl(r, g, b)` | Head LED. |

`PlayStream` requires **16 kHz, mono, 16-bit** PCM and is the mechanism this
project uses for custom audio. It is only present in current releases of
`unitree_sdk2_python`; older builds expose `TtsMaker` and the volume calls but
omit `PlayStream`, and their RPC client lacks the binary-request method it needs.
Vendor a current SDK if `AudioClient` has no `PlayStream` attribute.

`TtsMaker` may return success without producing audible output depending on
firmware. Where that is the case, render speech to a WAV (see
`scripts/generate_voices.sh`) and play it with `PlayStream` instead.

## Optional second output

A USB audio device plugged into the Jetson appears as a normal PulseAudio sink
and can be driven locally with `paplay`. Voice Studio plays to both outputs at
once and exposes a sync offset, since the network path to the control PC is
slower than local USB playback.

## Consequences

- Nothing on the robot's filesystem is modified; playback is an API call.
- There is no rollback step — stop calling the API and the robot behaves normally.
- Audio must be 16 kHz mono 16-bit; `voice/app/server.py` converts on import.
