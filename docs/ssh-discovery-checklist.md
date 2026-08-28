# SSH Discovery Checklist — Unitree G1

Phase 1. **Discovery only.** Read-only commands. No file modification. No service restarts. No deletions.

The G1 typically ships with two on-board computers (a Jetson Orin-class "high-level" board running Ubuntu, and a low-level real-time MCU). Audio assets and the apps that play them live on the Ubuntu side. SSH there first.

---

## 0. Pre-flight

Open **two** SSH sessions. Use one for inspection, one as a safety shell you never close until the work is done. If you lock yourself out of the first one, the second one is your rescue.

```bash
# From your workstation
ssh unitree@<G1_IP>          # default user is usually "unitree"; password is on the sticker / in Unitree docs
# Note: confirm the user, do NOT assume root.
```

Once in, set a working directory on the robot so you do not pollute `$HOME`:

```bash
mkdir -p ~/g1-audit/$(date +%Y%m%d_%H%M%S)
cd ~/g1-audit/$(date +%Y%m%d_%H%M%S)
echo "Audit started $(date -Iseconds) by $(whoami) on $(hostname)" | tee session.log
```

---

## 1. Identify the system

```bash
# OS + kernel
uname -a              | tee -a session.log
cat /etc/os-release   | tee -a session.log
lsb_release -a 2>/dev/null | tee -a session.log

# Hardware / Jetson model
cat /proc/device-tree/model 2>/dev/null; echo
cat /etc/nv_tegra_release 2>/dev/null

# Disk layout (read-only check before we write backups anywhere)
df -hT                | tee -a session.log
mount | grep -Ev '^(proc|sys|cgroup|tmpfs|devpts|securityfs|pstore|bpf|tracefs|debugfs|fusectl|configfs|mqueue)' | tee -a session.log
```

Look for: any **read-only** mounts (a squashfs or `ro` partition holding system audio is a common gotcha).

---

## 2. Identify the user, permissions, and which accounts can write to the audio dirs later

```bash
id
groups
sudo -n true 2>&1 | head -1     # are we passwordless sudo? (do NOT actually elevate yet)
getent passwd | awk -F: '$3>=1000 {print $1, $3, $6, $7}'
```

---

## 3. Identify the audio stack

```bash
# Is ALSA there? PulseAudio? PipeWire?
which aplay arecord paplay pactl pw-cli pw-play ffplay mpg123 sox play 2>/dev/null
aplay -l 2>/dev/null
aplay -L 2>/dev/null | head -50
cat /proc/asound/cards 2>/dev/null
cat /proc/asound/modules 2>/dev/null
pactl info 2>/dev/null | head -20
systemctl --user status pulseaudio 2>/dev/null | head -5
systemctl --user status pipewire 2>/dev/null | head -5
```

What you want to know:
- Which **command** the robot uses to play sound (`aplay`, `paplay`, `ffplay`, a custom binary).
- Which **device** it plays through (`hw:0,0`, `default`, a named PulseAudio sink).
- Whether audio runs as **root**, the **unitree** user, or as a **systemd --user** service.

---

## 4. Catalogue running services and processes

```bash
# Anything currently producing sound, or holding the audio device
sudo fuser -v /dev/snd/* 2>/dev/null
ps -eo pid,user,cmd | grep -Ei 'audio|sound|voice|tts|aplay|paplay|ffplay|mpg123|prompt|speech' | grep -v grep

# Systemd unit inventory
systemctl list-units --type=service --state=running --no-pager | tee services_running.txt
systemctl list-unit-files --type=service --no-pager  | tee services_all.txt

# Anything that auto-starts and mentions audio
systemctl list-unit-files --no-pager | grep -Ei 'audio|sound|voice|tts|unitree|robot|g1'
```

---

## 5. Likely Unitree-specific directories (check existence; do not modify)

These are the *first* places to look on Unitree's Ubuntu builds:

```bash
for p in \
  /unitree \
  /unitree/* \
  /unitree/audio \
  /unitree/voice \
  /unitree/sound \
  /opt/unitree \
  /opt/unitree/* \
  /usr/local/unitree \
  /home/unitree \
  /home/unitree/* \
  /root/unitree \
  /etc/unitree ; do
  [ -e "$p" ] && ls -ld "$p"
done
```

Then, if any of those exist, walk them:

```bash
# Replace <DIR> with whichever paths above existed
sudo find <DIR> -maxdepth 4 -type d | tee dirs_<tag>.txt
sudo find <DIR> -maxdepth 4 -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.ogg' \
  -o -iname '*.flac' -o -iname '*.pcm' -o -iname '*.raw' -o -iname '*.aac' -o -iname '*.m4a' \) \
  -printf '%p\t%s\t%u:%g\t%m\n' | tee audio_<tag>.tsv
```

---

## 6. Whole-system audio scan

Run the `scripts/scan_audio_files.sh` from this project. It is read-only and writes its output into the audit directory you created in step 0. See that script for details.

---

## 7. Whole-system reference scan

Run `scripts/scan_sound_references.sh` from this project. It greps scripts, configs, systemd units, and launch files for keywords like `aplay`, `play_sound`, `tts`, prompt filenames, etc.

---

## 8. Capture *what the robot is doing* while it makes sound

This is the most valuable artifact you can produce. With the second SSH session ready, do the following one at a time and note what plays.

In session A, start a watcher BEFORE triggering the sound:

```bash
# Watch the audio devices in real time
sudo inotifywait -m -r -e open,access /dev/snd 2>/dev/null &
WATCHER_PID=$!

# In parallel, see who opens which files anywhere under the unitree tree
sudo strace -f -e trace=openat -p $(pgrep -d, -f 'unitree|g1|robot') 2>&1 \
  | grep -Ei '\.wav|\.mp3|\.ogg|\.pcm|/audio/|/sound/|/voice/' \
  | tee strace_audio.log &
STRACE_PID=$!
```

In session B (or by physically interacting with the robot), trigger each sound one by one:
- Power on chime
- "App connected" prompt
- Low battery prompt
- Damping / motion start prompt
- Error / fault prompt

After each trigger, in session A:

```bash
echo "=== $(date -Iseconds) trigger: <name of sound> ===" >> trigger_log.txt
```

When done, stop the watchers:

```bash
kill $WATCHER_PID $STRACE_PID 2>/dev/null
```

You now have a mapping of trigger to filename.

---

## 9. Capture the audio format of one example file

```bash
# Replace <FILE> with one of the files you found
file <FILE>
ffprobe -v error -show_streams -show_format <FILE>
soxi <FILE> 2>/dev/null
```

Record: codec, sample rate (Hz), bit depth, channel count, duration. These are the constraints replacement files must meet.

---

## 10. Snapshot before you leave the SSH session

```bash
tar -czf ~/g1-audit/$(hostname)-audit-$(date +%Y%m%d_%H%M%S).tar.gz -C ~/g1-audit .
ls -lh ~/g1-audit/*.tar.gz
```

Pull that tarball back to your workstation:

```bash
# From your workstation
scp unitree@<G1_IP>:~/g1-audit/*-audit-*.tar.gz ./
```

Stop here. Do not modify anything yet; record the paths you confirmed first.
