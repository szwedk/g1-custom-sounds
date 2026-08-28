# One-Sound Test Plan

Goal: replace exactly one **L1** (cosmetic) sound, end-to-end, with full reversibility, before touching anything else. Treat this as a rehearsal of the full process.

## Pick the candidate

Choose a file that:

- Is cosmetic (risk tier L1) — e.g. an "app connected" chime or a startup ding.
- Has a confirmed trigger from the strace/inotify capture (step 8 of the SSH discovery checklist).
- Is **not** referenced by safety, fault, or e-stop code paths. Grep `scan-results/refs-*.txt` for the filename — if it shows up next to keywords like `error`, `fault`, `emergency`, `estop`, `safety`, pick a different file.
- Is a `.wav` if at all possible. WAV is the simplest to re-encode and the least likely to surprise you.

Record the choice before you start.

## Steps

### 1. Snapshot the system state

On the robot:

```bash
journalctl -b --since "10 min ago" > ~/g1-audit/pre_test_journal.txt
ps -eo pid,user,cmd > ~/g1-audit/pre_test_ps.txt
systemctl list-units --state=running --no-pager > ~/g1-audit/pre_test_services.txt
```

### 2. Confirm the file is in the backup manifest

```bash
grep -F "/unitree/audio/<filename>" ./backups/<host>-<ts>/manifest.tsv
```

If it isn't there, **stop** and re-run `backup_audio_files.sh` before going further.

### 3. Build the replacement file on your workstation

```bash
./scripts/convert_audio_files.sh \
    ./replacement-audio/wav/<your_english_recording>.wav \
    ./backups/<host>-<ts>/files/unitree/audio/<filename>
```

The output appears in `./replacement-audio/converted/<filename>` with the **exact same name** as the original.

### 4. Verify the format matches

```bash
ffprobe -v error -show_streams -show_format \
    ./backups/<host>-<ts>/files/unitree/audio/<filename>

ffprobe -v error -show_streams -show_format \
    ./replacement-audio/converted/<filename>
```

Diff the relevant lines (`codec_name`, `sample_rate`, `bits_per_sample`, `channels`, `format_name`). All must match.

### 5. Copy the replacement to the robot, side by side

Do **not** overwrite yet. Land it next to the original first.

```bash
scp ./replacement-audio/converted/<filename> \
    unitree@<G1_IP>:/tmp/<filename>
```

On the robot, **dry-run** the playback against the speaker, without touching the live file:

```bash
./test_playback.sh /tmp/<filename>
```

Listen. If it sounds wrong (clipped, too quiet, distorted), iterate on the recording. Do not proceed until you hear it cleanly.

### 6. Replace, preserving owner / group / mode

```bash
# On the robot, with the live file still untouched.
ORIG=/unitree/audio/<filename>
NEW=/tmp/<filename>

# Capture current attributes
OWNER=$(stat -c '%U:%G' "$ORIG")
MODE=$(stat -c '%a' "$ORIG")

# Atomic replace via rename
sudo cp -a --preserve=all "$NEW" "${ORIG}.new"
sudo chown "$OWNER" "${ORIG}.new"
sudo chmod "$MODE"  "${ORIG}.new"
sudo mv -f "${ORIG}.new" "$ORIG"      # rename = atomic on same filesystem
```

### 7. Trigger and observe

Trigger the event that plays this sound (open the app, plug/unplug power, etc.). Watch:

```bash
journalctl -f
```

You should hear the new English audio and see no new errors. If the playback process logs a decode error, your format match was wrong — go straight to rollback.

### 8. Record the outcome

Record the outcome: the file, its checksums before and after, the trigger event,
and whether it passed.

### 9. Either keep it, or roll back

- **Keep it:** mark the file as tested.
- **Roll back:** run `./backups/<host>-<ts>/restore.sh --apply` on the robot. Re-trigger the event to confirm the original is back. Update the test log.

## Hard stops — abort immediately if any of these happen

- The robot's app disconnects unexpectedly during or after the swap.
- A service goes into restart-loop (`journalctl -u <unit> -f` shows repeated starts).
- The robot enters a fault state, damping mode, or e-stop on its own.
- The replacement plays at the wrong pitch or speed (sample rate mismatch).
- Anything related to motion or safety logs an error.

In any of those cases: roll back the single file, do not proceed to a second file, and re-examine the format match.
