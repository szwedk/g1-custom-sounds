#!/usr/bin/env python3
"""
g1_play.py — talk to the Unitree G1 speaker via the unitree_sdk2 AudioClient.

Commands:
  - ping     : init the AudioClient and read the volume (proves the robot is reachable)
  - volume   : set the speaker volume (0-100)
  - tts      : speak text via on-robot TTS  (speaker_id 0=Chinese, 1=English)
  - play     : stream a 16 kHz / mono / 16-bit WAV to the speaker via PlayStream

No files on the robot are modified; playback is an API call.

Requires unitree_sdk2py (import name: unitree_sdk2py) and a network interface
that reaches the robot's DDS network. Use --simulate to exercise the code paths
without the SDK or a robot.

Examples:
    python3 g1_play.py --iface eth0 ping
    python3 g1_play.py --iface eth0 volume 85
    python3 g1_play.py --iface eth0 tts "Hello, I am ready" --speaker 1
    python3 g1_play.py --iface eth0 play ../generated/P01.wav
    python3 g1_play.py --simulate play ../generated/P01.wav
"""

import argparse
import sys
import time
import wave

try:
    import audioop            # stdlib; used for the software loudness boost
except Exception:             # removed in Python 3.13
    audioop = None

# ---- robot's required audio format (AudioClient.PlayStream) ----------------
REQ_RATE = 16000
REQ_CHANNELS = 1
REQ_SAMPWIDTH = 2          # bytes -> 16-bit
CHUNK_BYTES = 32 * 1024    # PCM streamed in ~32 KB blocks


def read_wav_pcm(path):
    """Return raw little-endian 16-bit mono PCM bytes, asserting the robot format."""
    with wave.open(path, "rb") as w:
        rate, ch, width, nframes = (
            w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        )
        pcm = w.readframes(nframes)
    problems = []
    if rate != REQ_RATE:
        problems.append(f"sample rate {rate} != {REQ_RATE}")
    if ch != REQ_CHANNELS:
        problems.append(f"channels {ch} != {REQ_CHANNELS}")
    if width != REQ_SAMPWIDTH:
        problems.append(f"sample width {width*8}-bit != 16-bit")
    if problems:
        raise ValueError(
            f"{path} is not in the robot's required format: "
            + "; ".join(problems)
            + ". Re-generate it with scripts/generate_voices.sh."
        )
    dur = nframes / float(rate) if rate else 0.0
    return pcm, dur


# ---- SDK shim --------------------------------------------------------------
class G1Audio:
    """Thin wrapper over the Unitree AudioClient, or a no-op in --simulate mode."""

    def __init__(self, iface, simulate=False, timeout=10.0):
        self.simulate = simulate
        self.client = None
        if simulate:
            return
        try:
            from unitree_sdk2py.core.channel import ChannelFactoryInitialize
            from unitree_sdk2py.g1.audio.g1_audio_client import AudioClient
        except Exception as e:  # noqa: BLE001
            raise SystemExit(
                "error: unitree_sdk2py is not importable on this machine.\n"
                f"       ({e})\n"
                "       Install it (pip install unitree_sdk2py) and run on a host\n"
                "       that shares the robot's network, or use --simulate to test offline."
            )
        if not iface:
            raise SystemExit("error: --iface is required (the NIC that reaches the robot). "
                             "Find it with: ip -br addr")
        ChannelFactoryInitialize(0, iface)
        self.client = AudioClient()
        self.client.SetTimeout(timeout)
        self.client.Init()

    # -- operations ----------------------------------------------------------
    def get_volume(self):
        if self.simulate:
            print("  [sim] GetVolume() -> 85")
            return 85
        # The real AudioClient returns (code, data) where data is a dict like
        # {"volume": 85}; SetVolume/TtsMaker return a bare int code. Handle both so
        # 'ping' prints a clean integer AND surfaces a non-zero error code.
        ret = self.client.GetVolume()
        if isinstance(ret, tuple):
            code = ret[0]
            data = ret[1] if len(ret) > 1 else None
            if code != 0:
                raise SystemExit(f"GetVolume failed (code {code}) — robot reachable but errored")
            if isinstance(data, dict):
                return data.get("volume", data)
            return data
        return ret

    def set_volume(self, level):
        level = max(0, min(100, int(level)))
        if self.simulate:
            print(f"  [sim] SetVolume({level})")
            return 0
        return self.client.SetVolume(level)

    def tts(self, text, speaker_id):
        if self.simulate:
            print(f"  [sim] TtsMaker({text!r}, speaker_id={speaker_id})")
            return 0
        return self.client.TtsMaker(text, speaker_id)

    def play_wav(self, path, app_name="g1-custom-voice", stop_event=None, gain=1.0):
        pcm, dur = read_wav_pcm(path)
        # Software loudness boost: amplify the 16-bit samples before streaming.
        # audioop.mul saturates (hard-clips) at the sample limits, so it gets
        # louder without wrapping/garbling — good enough past the hardware max.
        if gain and abs(gain - 1.0) > 0.01 and audioop is not None:
            try:
                pcm = audioop.mul(pcm, REQ_SAMPWIDTH, float(gain))
            except Exception:  # noqa: BLE001
                pass
        nchunks = (len(pcm) + CHUNK_BYTES - 1) // CHUNK_BYTES
        stream_id = str(int(time.time() * 1000))        # unique per utterance
        if self.simulate:
            print(f"  [sim] PlayStream(app={app_name!r}, stream_id={stream_id}, "
                  f"{len(pcm)} bytes / {nchunks} chunks, ~{dur:.2f}s)")
            return 0
        # Send the PCM in chunks under one stream_id, then stop the stream.
        # stop_event makes playback interruptible mid-clip.
        for i in range(0, len(pcm), CHUNK_BYTES):
            if stop_event is not None and stop_event.is_set():
                break
            self.client.PlayStream(app_name, stream_id, pcm[i:i + CHUNK_BYTES])
        # wait for playback to finish, but wake immediately on stop
        if stop_event is not None:
            stop_event.wait(dur)
        else:
            time.sleep(dur)
        try:
            self.client.PlayStop(app_name)
        except Exception:                               # noqa: BLE001 - optional on some SDKs
            pass
        return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Drive the G1 speaker via AudioClient.")
    p.add_argument("--iface", default="", help="network interface that reaches the robot (e.g. eth0)")
    p.add_argument("--simulate", action="store_true", help="no SDK / no robot; print actions only")
    p.add_argument("--app-name", default="g1-custom-voice")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping")
    pv = sub.add_parser("volume"); pv.add_argument("level", type=int)
    pt = sub.add_parser("tts"); pt.add_argument("text"); pt.add_argument("--speaker", type=int, default=1)
    pp = sub.add_parser("play"); pp.add_argument("wav")
    args = p.parse_args(argv)

    # 'play' can validate the WAV without ever opening the SDK.
    if args.cmd == "play":
        try:
            _pcm, dur = read_wav_pcm(args.wav)
        except (OSError, ValueError, wave.Error) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2

    a = G1Audio(args.iface, simulate=args.simulate)

    if args.cmd == "ping":
        print(f"volume = {a.get_volume()}")
    elif args.cmd == "volume":
        a.set_volume(args.level); print(f"set volume -> {args.level}")
    elif args.cmd == "tts":
        a.tts(args.text, args.speaker); print(f"spoke (speaker_id={args.speaker}): {args.text}")
    elif args.cmd == "play":
        a.play_wav(args.wav, app_name=args.app_name); print(f"played: {args.wav} (~{dur:.2f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
