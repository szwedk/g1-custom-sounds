# Likely G1 File Paths (working hypotheses)

This list is a *starting point*, not ground truth. Confirm each path with `ls -l` over SSH before relying on it. Unitree changes directory layouts between firmware versions.

## On the Jetson / Ubuntu side

| Path                                  | What to look for                                |
|---------------------------------------|-------------------------------------------------|
| `/unitree/`                           | Top-level Unitree install (most likely)         |
| `/unitree/audio/` or `/unitree/sound/`| Bundled Chinese prompts                         |
| `/unitree/voice/`                     | TTS or voice-prompt assets                      |
| `/opt/unitree/`                       | Alternate install root                          |
| `/usr/local/unitree/`                 | Alternate install root                          |
| `/home/unitree/` and subfolders       | App data, downloaded sounds                     |
| `/etc/systemd/system/*.service`       | Auto-starting Unitree services                  |
| `/etc/systemd/user/*.service`         | Per-user auto-starting services                 |
| `/lib/systemd/system/*.service`       | Distribution-installed services                 |
| `/var/lib/<unitree-app>/`             | App state / cached audio                        |

## Audio stack

| Path                          | What to look for                            |
|-------------------------------|---------------------------------------------|
| `/dev/snd/`                   | ALSA devices                                |
| `/proc/asound/cards`          | Sound card enumeration                      |
| `/etc/asound.conf`            | System-wide ALSA config                     |
| `~/.asoundrc`                 | Per-user ALSA config                        |
| `/etc/pulse/`                 | PulseAudio configs (if pulse is installed)  |
| `/etc/pipewire/`              | PipeWire configs (if pipewire is installed) |

## Things that probably aren't where the sounds are (skip)

- `/boot`, `/lib/firmware` — kernel-side, not app audio
- Anything inside `/snap` — sandboxed, unlikely
- `/proc`, `/sys`, `/dev` — pseudo filesystems

## How to fill in actual paths

After running `scripts/scan_audio_files.sh`, replace this table with a real one based on what was found.
