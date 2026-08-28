# Rollback Plan

There are three rollback levels. Use the smallest one that fixes the problem.

---

## Level 1 — single file (most common)

Use this when one specific replacement misbehaves (wrong pitch, decode error, ugly clip).

On the robot:

```bash
ORIG=/unitree/audio/<filename>
BAK=~/g1-restore/backups/<host>-<ts>/files/unitree/audio/<filename>

# Sanity-check the backup is intact
sha256sum "$BAK"
grep -F "$ORIG" ~/g1-restore/backups/<host>-<ts>/manifest.tsv

# Restore, preserving everything
sudo cp -a --preserve=all "$BAK" "${ORIG}.restore"
sudo mv -f "${ORIG}.restore" "$ORIG"

# Confirm the restored file matches the original hash
EXPECTED=$(awk -F'\t' -v p="$ORIG" '$1==p {print $7}' ~/g1-restore/backups/<host>-<ts>/manifest.tsv)
ACTUAL=$(sudo sha256sum "$ORIG" | awk '{print $1}')
[ "$EXPECTED" = "$ACTUAL" ] && echo "RESTORE VERIFIED" || echo "MISMATCH — investigate"
```

Then re-trigger the event that plays this file and confirm the original Chinese audio is back.

---

## Level 2 — every file in a single backup set

Use this when several replacements went in together and you want to roll the whole batch back.

The backup script generates `restore.sh` inside each backup directory. It does a sha256-verified restore of every file in that backup's `manifest.tsv`.

```bash
# Dry run first — shows what would happen, makes no changes
~/g1-restore/backups/<host>-<ts>/restore.sh

# Apply
~/g1-restore/backups/<host>-<ts>/restore.sh --apply
```

The script:
1. Reads `manifest.tsv`.
2. For each entry, verifies the backup file's sha256 still matches what we recorded.
3. Copies the backup back to the original path with `cp -a --preserve=all`.
4. Re-hashes the restored file and confirms it matches the recorded hash.

If any verification fails, that line is printed loudly and the others continue.

---

## Level 3 — restore from your workstation's copy

Use this if the backup *on the robot* has been damaged, the robot's disk is full, or you replaced files without going through the backup script.

You should have copied each backup directory off the robot with:

```bash
scp -r unitree@<G1_IP>:~/g1-restore/backups/<host>-<ts>/ ./
```

To restore from there:

```bash
# From your workstation
scp -r ./<host>-<ts>/ unitree@<G1_IP>:~/g1-restore/backups/

# On the robot
~/g1-restore/backups/<host>-<ts>/restore.sh --apply
```

---

## Level 4 — no backup available (emergency only)

If, for some reason, neither the robot-local nor workstation-local backup exists, **do not attempt to fabricate or substitute files**. Options, in preference order:

1. Reflash the Unitree-provided system image for the G1 firmware version that was on the robot. The Chinese prompts are part of the stock image.
2. Contact Unitree support for the original audio asset bundle.
3. Leave the file missing. Most playback code will log an error and continue. Better silent than corrupted.

This is why **step 1 of any change session is always to verify a fresh, verified backup exists in two places.**

---

## Post-rollback checklist

After any rollback:

- [ ] Re-trigger the affected event. The original sound should play.
- [ ] `journalctl -b --since "5 min ago"` — no new errors related to audio?
- [ ] Record the rollback outcome and reset the file's status to `backed-up`.

---

## When to escalate

Stop and contact a human (or Unitree support) if:

- The robot enters a fault state on its own after a rollback.
- A service that worked before the change won't start after the rollback.
- A backup file fails sha256 verification (something corrupted it).
- The robot is unresponsive over SSH after a change.
