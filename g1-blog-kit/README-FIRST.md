# Blog post — instructions

Unzip this, then follow the brief below. The three PNGs referenced in it are in
this same folder.

---

Write a technical blog post for my personal website about a project I built:
custom audio and English voice prompts on a Unitree G1 humanoid robot.

Deliver two files:
1. `index.html` — self-contained (inline CSS, no build step, no CDN links, no
   external fonts), responsive, readable in light and dark, max ~720px reading
   column. Restrained and technical: no gradients, no emoji, no marketing voice.
2. `post.md` — the same content as clean Markdown so I can paste it into a CMS.

The three PNGs are bundled with this file. Copy them into an `images/`
folder and reference them relatively from the HTML and Markdown.

## Audience and tone

Engineers who work with robots or audio. Assume Linux and Python knowledge, not
Unitree specifics. Tell the debugging honestly, including the wrong turns — the
value here is the process of elimination, not a victory lap. Plain declarative
sentences. Avoid "journey", "dive in", "game-changer", "unleash", "seamless".

## What the project is

A tool for playing custom audio and English voice prompts on a Unitree G1, with a
local web UI ("Voice Studio") for recording, uploading and managing clips, plus
command line tools for batch prompt generation and deployment. Everything runs on
localhost or on the robot itself; nothing on the robot's filesystem is modified.

## The technical story — the spine of the post

1. **The obvious approach is wrong.** You would expect to find the robot's prompt
   audio on disk and overwrite it. A filesystem scan turns up about 55 audio
   files, but every one is stock Ubuntu/Debian desktop audio: `alsa-utils` test
   clips, the Debian `sound-icons` set, GNOME alert sounds, `speech-dispatcher`
   fixtures — and a `COPYING.opus` which is a licence *text file*, not audio at
   all (an extension-only scan reports it as a candidate).
2. **One command settles it:** `dpkg -S <path>`. Anything owned by a distribution
   package is stock OS audio, not the robot's voice. That check invalidates the
   whole file-replacement premise. The project's scanner automates this and
   validates by MIME type rather than by file extension.
3. **The voice is synthesized at runtime** by an on-board service, so there is no
   file to replace. Audio has to go through the `unitree_sdk2` `AudioClient` API.
4. **The G1 has two computers.** The Jetson Orin NX (the development computer you
   normally log into) has no speaker amplifier — no amount of local `aplay`,
   `paplay`, or Tegra APE mixer routing will drive the chest speaker. The speaker
   belongs to the separate control computer. This explains the confusing symptom:
   the API returns success from the Jetson while the robot stays silent, because
   the RPC is answered by the other machine.
5. **The last blocker was an SDK version gap.** The SDK present on the robot
   exposed `TtsMaker`, `GetVolume` and `SetVolume` but not `PlayStream`, and its
   RPC client lacked the binary-request method that `PlayStream` needs. Vendoring
   a current `unitree_sdk2_python` fixed it, and custom 16 kHz mono PCM finally
   played through the chest speaker.
6. **Loudness.** Speech sounded quieter than downloaded sound effects even at the
   same integrated LUFS, because effects are mastered brick-wall loud while speech
   has a wide dynamic range. The fix is a compressor into `dynaudnorm` into a
   limiter, so everything lands at a comparable perceived loudness.
7. **A second output.** A USB audio device on the Jetson appears as an ordinary
   PulseAudio sink. Playing to it and the internal speaker together needs a sync
   offset, because the internal path crosses the network while USB playback is
   local.

Include a few short snippets where they earn their place — `dpkg -S`, the
`PlayStream` call, the ffmpeg filter chain. Keep them small; this is prose with
code in it, not a tutorial.

Useful technical details you may use:
- `PlayStream(app_name, stream_id, pcm)` requires 16 kHz, mono, 16-bit PCM.
- `TtsMaker(text, speaker_id)` — speaker_id 0 is Chinese, 1 is English.
- The loudness chain is roughly:
  `acompressor=threshold=0.06:ratio=4 , dynaudnorm=f=200:g=15 , alimiter=limit=0.97`
- `TtsMaker` can return success without producing audible output on some
  firmware; rendering speech to a WAV and using `PlayStream` avoids that.

## Credit — required, and be accurate

- **Author: Kamil Szwed** (GitHub: `szwedk`). The Voice Studio app, the
  scanning/backup/deployment scripts, the loudness pipeline and the dual-speaker
  sync are original work.
- **Unitree Robotics** — the robot and the SDK the project depends on:
  https://github.com/unitreerobotics/unitree_sdk2_python
  BSD 3-Clause, Copyright (c) 2016-2024 HangZhou YuShu Technology Co., Ltd.
  The `AudioClient` API (`PlayStream`, `TtsMaker`, `SetVolume`) is theirs; this
  project is a client of it. State that plainly and link it.
- **ElevenLabs** — optional text-to-speech used to render English prompts.
- Do **not** call this a fork. It is not derived from another application; it is
  built on Unitree's official SDK.
- Link the project repository: https://github.com/szwedk/g1-custom-sounds

## Images

Use the three bundled PNGs. Give each a real caption; do not invent others.

| Image | Placement |
|-------|-----------|
| `01-voice-studio.png` | Hero. The Voice Studio interface: sound library, text-to-speech, recorder, speaker control. |
| `02-architecture.png` | With the "two computers" section. Shows the path from workstation, through the Jetson, to the control computer and both speakers. |
| `03-speaker-control.png` | Inline detail near the loudness and volume section. |

I will add my own photographs later. Leave two clearly marked placeholders using
`<figure>` and `<figcaption>`: one for a photo of the G1, one for the USB speaker
connected to it.

## Repository structure to include in the post

```
g1-custom-sounds/
├── README.md
├── docs/                  audio architecture, discovery and replacement procedures
├── scripts/               scanning, backup, conversion, generation, deployment
└── voice/
    ├── prompts.tsv        event to English line catalog
    ├── app/               Voice Studio server and web UI
    ├── lib/g1_play.py     AudioClient wrapper
    └── deploy/            robot-side launcher and systemd unit
```

## Accuracy rules

- Do not invent benchmarks, latency numbers, timings or model numbers.
- Do not include IP addresses, hostnames, usernames or key paths.
- If something is uncertain, say so or leave it out.
- The project does not touch firmware, motion or safety systems. Do not overstate
  its scope.

## Title

Propose three titles at the top of `post.md` and use the strongest in the HTML.
Descriptive, not clickbait — for example, "The Unitree G1's voice isn't a file".
