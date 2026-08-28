#!/usr/bin/env python3
"""
server.py — G1 Voice Studio: local web GUI backend for the Unitree G1 speaker.

Serves the single-page UI in static/index.html and exposes a small JSON API
that wraps the AudioClient layer in voice/lib/g1_play.py:

  GET  /api/state                     app + robot status, sound library listing
  POST /api/volume    {level}         set speaker volume (0-100)
  GET  /api/ping                      live robot check (reads volume)
  POST /api/tts       {text,speaker}  speak text on the robot (on-board TTS)
  POST /api/generate  {text,name}     ElevenLabs -> 16k mono WAV -> library
  POST /api/play      {source,name}   stream a WAV to the robot speaker
  POST /api/stop                      stop current playback
  POST /api/upload?name=X             raw audio body -> converted -> library
  POST /api/record?name=X             mic blob (webm/ogg) -> converted -> library
  POST /api/push      {items:[...]}   copy WAVs onto the robot's disk over SSH
                                      (persists across reboots in ~/g1_custom_sounds)
  POST /api/delete    {name}          remove a library sound

Run it via scripts/voice_studio.sh. Use --simulate to run with no robot and no
unitree_sdk2py installed (pushes then land in voice/app/simulated_robot/).

Nothing here modifies robot system files. "Save to G1" copies files into the
unitree user's home directory; playback goes through the AudioClient API.
Binds to 127.0.0.1 only.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

APP_DIR = os.path.dirname(os.path.abspath(__file__))
VOICE_DIR = os.path.dirname(APP_DIR)                 # .../voice
ROOT = os.path.dirname(VOICE_DIR)                    # repo root
STATIC = os.path.join(APP_DIR, "static")
LIB = os.path.join(VOICE_DIR, "library")             # user sounds (upload/record/generate)
GEN = os.path.join(VOICE_DIR, "generated")           # prompt clips from generate_voices.sh
ASSETS = os.path.join(APP_DIR, "assets")             # runtime-made test tone
STATE_DIR = os.path.join(APP_DIR, "state")
PUSHED_JSON = os.path.join(STATE_DIR, "pushed.json")
SIM_ROBOT = os.path.join(APP_DIR, "simulated_robot", "g1_custom_sounds")
ROBOT_DIR = "g1_custom_sounds"                       # under the robot user's $HOME

# Loudness chain applied to every clip: compress the dynamic range, level the
# whole clip toward full scale, then limit so the result never clips. Speech and
# mastered sound effects end up at a comparable perceived loudness.
NORMALIZE_AF = ("acompressor=threshold=0.06:ratio=4:attack=5:release=130:makeup=3,"
                "dynaudnorm=f=200:g=15:p=0.9:m=12,"
                "alimiter=level_in=1:level_out=1:limit=0.97")

sys.path.insert(0, os.path.join(VOICE_DIR, "lib"))
from g1_play import G1Audio, read_wav_pcm            # noqa: E402

ARGS = None
_audio = None
_audio_err = None            # latched init failure (DDS init must not be retried)
_audio_lock = threading.Lock()
_play_lock = threading.Lock()
_stop_event = threading.Event()

# Volume knob goes 0..VOL_MAX. 0..100 is the robot's hardware volume (SetVolume);
# 100..VOL_MAX is a software "boost" that amplifies the PCM before PlayStream.
VOL_MAX = 150
_gain = 1.0                  # current software boost factor (>=1.0)

# Second output: a USB speaker plugged into the Jetson. We play to it locally via
# paplay (PulseAudio) at the same time as the internal chest speaker's PlayStream.
USB_HINT = "usb"             # substring identifying the USB speaker's pulse sink
_usb_proc = None             # currently-playing USB subprocess chain
_usb_lock = threading.Lock()

# Sync offset between the two outputs, in milliseconds. The internal speaker is
# reached over the network and the USB speaker locally, so they need aligning. A
# positive value delays the USB side, a negative value delays the internal side.
_sync_ms = 180


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def audio():
    """Lazy singleton AudioClient. DDS initialisation may only happen once per
    process, so a failed construction is latched rather than retried."""
    global _audio, _audio_err
    with _audio_lock:
        if _audio is not None:
            return _audio
        if _audio_err is not None:
            raise RuntimeError(_audio_err)
        try:
            _audio = G1Audio(ARGS.iface, simulate=ARGS.simulate)
        except (SystemExit, Exception) as e:  # SystemExit = missing SDK
            _audio_err = str(e) or "audio init failed"
            raise RuntimeError(_audio_err) from None
        return _audio


def sanitize_name(name):
    base = os.path.splitext(os.path.basename(name or ""))[0]
    base = re.sub(r"[^A-Za-z0-9_\- ]+", "", base).strip().replace(" ", "_")
    return base[:48] or "sound"


def ffmpeg_to_robot_wav(src, dst):
    """Convert any audio input to the G1's required 16 kHz mono 16-bit WAV,
    with light loudness normalization. Atomic write."""
    tmp = dst + ".tmp"
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", src,
        "-af", NORMALIZE_AF,
        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
        "-f", "wav",   # the temporary name has no extension to infer from
        tmp,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise RuntimeError(f"ffmpeg conversion failed: {r.stderr.strip()[:300]}")
    os.replace(tmp, dst)


def wav_duration(path):
    try:
        with wave.open(path, "rb") as w:
            fr = w.getframerate()
            return round(w.getnframes() / float(fr), 2) if fr else 0.0
    except Exception:
        return 0.0


def sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_pushed():
    try:
        with open(PUSHED_JSON) as f:
            return json.load(f)
    except Exception:
        return {}


def save_pushed(d):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = PUSHED_JSON + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, PUSHED_JSON)


def ensure_test_tone():
    """A short two-note chirp for exercising the chest speaker."""
    os.makedirs(ASSETS, exist_ok=True)
    tone = os.path.join(ASSETS, "test_tone.wav")
    if not os.path.exists(tone):
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=0.35:sample_rate=16000",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=0.35:sample_rate=16000",
            "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1,volume=0.8",
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", tone,
        ]
        subprocess.run(cmd, capture_output=True)
    return tone


def ensure_click():
    """A click train (a sharp 2 kHz blip every 500 ms for a few seconds) for
    tuning dual-speaker sync by ear: when aligned you hear single tight clicks,
    when offset you hear a flam/double."""
    os.makedirs(ASSETS, exist_ok=True)
    click = os.path.join(ASSETS, "sync_click.wav")
    if not os.path.exists(click):
        # 2 kHz blip for 15 ms every 500 ms. Commas inside the expression must be
        # escaped (\\,) or ffmpeg's filter parser splits on them; use lt() not '<'.
        expr = r"0.7*sin(2*PI*2000*t)*lt(mod(t\,0.5)\,0.015)"
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "lavfi", "-i", f"aevalsrc={expr}:d=3:s=16000",
               "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", click]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(click):
            raise RuntimeError(f"could not build sync click: {r.stderr.strip()[:200]}")
    return click


def resolve_sound(source, name):
    """Map (source, name) -> absolute wav path, safely inside its folder."""
    name = os.path.basename(name)
    folders = {"library": LIB, "generated": GEN, "asset": ASSETS}
    folder = folders.get(source)
    if not folder:
        raise RuntimeError(f"unknown source '{source}'")
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        raise RuntimeError(f"not found: {source}/{name}")
    return path


def list_sounds():
    pushed = load_pushed()
    out = {"library": [], "generated": []}
    for source, folder in (("library", LIB), ("generated", GEN)):
        if not os.path.isdir(folder):
            continue
        for fn in sorted(os.listdir(folder)):
            if not fn.lower().endswith(".wav"):
                continue
            p = os.path.join(folder, fn)
            rec = pushed.get(f"{source}/{fn}")
            out[source].append({
                "name": fn,
                "duration": wav_duration(p),
                "size": os.path.getsize(p),
                "pushed": bool(rec) and rec.get("sha256") == sha256_file(p),
            })
    return out


def push_to_robot(paths):
    """Copy WAVs onto the G1's disk (persists across reboots). Uses SSH keys —
    run `ssh-copy-id unitree@<ip>` once if you get an auth error."""
    if ARGS.simulate:
        os.makedirs(SIM_ROBOT, exist_ok=True)
        for p in paths:
            shutil.copy2(p, SIM_ROBOT)
        return f"simulated push -> {SIM_ROBOT}"
    if ARGS.on_robot:
        # We ARE the robot: copy straight into the persistent dir, no SSH.
        dest = os.path.join(os.path.expanduser("~"), ROBOT_DIR)
        os.makedirs(dest, exist_ok=True)
        for p in paths:
            shutil.copy2(p, dest)
        return f"saved to ~/{ROBOT_DIR}/ ({len(paths)} file(s), persists across reboots)"
    if not ARGS.robot_ip:
        raise RuntimeError("no robot IP configured — restart with a ROBOT_IP or use --simulate")
    target = f"{ARGS.user}@{ARGS.robot_ip}"
    ssh_opts = ["-o", "ConnectTimeout=6", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new"]
    if ARGS.ssh_key:
        ssh_opts += ["-i", ARGS.ssh_key]
    r = subprocess.run(["ssh", *ssh_opts, target, f"mkdir -p ~/{ROBOT_DIR}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ssh to {target} failed: {r.stderr.strip()[:200]} "
                           f"(passwordless key needed — run: ssh-copy-id {target})")
    r = subprocess.run(["scp", *ssh_opts, *paths, f"{target}:~/{ROBOT_DIR}/"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"scp failed: {r.stderr.strip()[:200]}")
    return f"saved to {target}:~/{ROBOT_DIR}/"


def elevenlabs_generate(text, out_path):
    key = os.environ.get("ELEVENLABS_API_KEY", "")
    if not key:
        raise RuntimeError("ELEVENLABS_API_KEY is not set — add it to voice/config.sh")
    voice = os.environ.get("EL_VOICE_ID", "JBFqnCBsd6RMkjVDRZzb")   # George (British)
    model = os.environ.get("EL_MODEL", "eleven_multilingual_v2")
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=pcm_16000",
        data=json.dumps({"text": text, "model_id": model}).encode(),
        headers={"xi-api-key": key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            pcm = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read()[:200].decode("utf-8", "replace")
        raise RuntimeError(f"ElevenLabs HTTP {e.code}: {detail}")
    with tempfile.NamedTemporaryFile(suffix=".pcm", delete=False) as tf:
        tf.write(pcm)
        raw = tf.name
    try:
        tmp = out_path + ".tmp"
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", raw,
               "-af", NORMALIZE_AF,
               "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
               "-f", "wav", tmp]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"ffmpeg wrap failed: {r.stderr.strip()[:200]}")
        os.replace(tmp, out_path)
    finally:
        os.remove(raw)


# --- Second output: USB speaker on the Jetson (via PulseAudio paplay) ----------

def _pulse_env():
    env = dict(os.environ)
    env.setdefault("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    return env


def usb_sink_name():
    """Return the PulseAudio sink name of the USB speaker, or None if not present."""
    try:
        r = subprocess.run(["pactl", "list", "sinks", "short"],
                           capture_output=True, text=True, env=_pulse_env(), timeout=5)
        for line in r.stdout.splitlines():
            cols = line.split("\t")
            if len(cols) >= 2 and USB_HINT in cols[1].lower():
                return cols[1]
    except Exception:  # noqa: BLE001
        pass
    return None


def usb_set_volume(pct):
    sink = usb_sink_name()
    if not sink:
        return
    env = _pulse_env()
    for args in (["set-sink-mute", sink, "0"], ["set-sink-volume", sink, "%d%%" % pct]):
        try:
            subprocess.run(["pactl", *args], env=env, timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:  # noqa: BLE001
            pass


def stop_usb_play():
    global _usb_proc
    with _usb_lock:
        procs, _usb_proc = _usb_proc, None
    for p in (procs or []):
        try:
            p.terminate()
        except Exception:  # noqa: BLE001
            pass


def usb_play(path, gain=1.0):
    """Play a WAV on the USB speaker (paplay via PulseAudio), applying the same
    software boost. Non-blocking. Returns True if a USB speaker was found."""
    global _usb_proc
    sink = usb_sink_name()
    if not sink:
        return False
    stop_usb_play()
    env = _pulse_env()
    if gain and abs(gain - 1.0) > 0.01:
        p1 = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
             "-af", "volume=%.3f" % gain, "-f", "wav", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p2 = subprocess.Popen(["paplay", "--device", sink],
                              stdin=p1.stdout, stderr=subprocess.DEVNULL, env=env)
        p1.stdout.close()
        procs = [p1, p2]
    else:
        p2 = subprocess.Popen(["paplay", "--device", sink, path],
                              stderr=subprocess.DEVNULL, env=env)
        procs = [p2]
    with _usb_lock:
        _usb_proc = procs
    threading.Thread(target=lambda ps: ps[-1].wait(), args=(procs,), daemon=True).start()
    return True


def play_async(path):
    """Play a clip on both outputs, aligned by _sync_ms: the internal speaker via
    AudioClient PlayStream and the USB speaker via paplay."""
    read_wav_pcm(path)  # validate format up front so errors surface in the response
    a = audio()          # surface init errors synchronously (before returning ok)
    _stop_event.clear()

    delay = _sync_ms / 1000.0
    usb_delay = delay if delay > 0 else 0.0     # positive -> hold the USB (faster) side
    int_delay = -delay if delay < 0 else 0.0    # negative -> hold the internal side

    def start_usb():
        if usb_delay and _stop_event.wait(usb_delay):
            return                              # stopped during the delay
        usb_play(path, _gain)
    threading.Thread(target=start_usb, daemon=True).start()

    def run():
        if int_delay and _stop_event.wait(int_delay):
            return
        with _play_lock:
            if _stop_event.is_set():            # a stop arrived before we got the lock
                return
            try:
                a.play_wav(path, app_name="g1-voice-studio",
                           stop_event=_stop_event, gain=_gain)
            except Exception as e:  # noqa: BLE001
                print(f"play error: {e}", file=sys.stderr)

    threading.Thread(target=run, daemon=True).start()
    return wav_duration(path)


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "G1VoiceStudio/1.0"

    # -- plumbing ----------------------------------------------------------
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return self._json({"error": "not found"}, 404)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _jbody(self):
        try:
            return json.loads(self._body() or b"{}")
        except json.JSONDecodeError:
            raise RuntimeError("invalid JSON body")

    def log_message(self, fmt, *a):  # quiet default access log
        pass

    def _local_only(self):
        """Reject cross-origin and DNS-rebinding requests, so a page the user
        happens to visit cannot drive the robot through localhost."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if host and host not in ("127.0.0.1", "localhost"):
            return False
        origin = self.headers.get("Origin") or self.headers.get("Referer")
        if origin:
            h = urlparse(origin).hostname
            if h not in ("127.0.0.1", "localhost"):
                return False
        return True

    # -- routes ------------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        try:
            if not self._local_only():
                return self._json({"error": "forbidden"}, 403)
            if u.path in ("/", "/index.html"):
                return self._file(os.path.join(STATIC, "index.html"), "text/html; charset=utf-8")
            if u.path.startswith("/media/"):
                parts = u.path.split("/")  # ['', 'media', source, name]
                if len(parts) == 4:
                    return self._file(resolve_sound(parts[2], parts[3]), "audio/wav")
                return self._json({"error": "bad media path"}, 404)
            if u.path == "/api/state":
                return self._json({
                    "simulate": ARGS.simulate,
                    "on_robot": ARGS.on_robot,
                    "robot_ip": ARGS.robot_ip,
                    "iface": ARGS.iface,
                    "usb_speaker": bool(usb_sink_name()),
                    "sync_ms": _sync_ms,
                    "robot_dir": f"~/{ROBOT_DIR}",
                    "has_elevenlabs": bool(os.environ.get("ELEVENLABS_API_KEY")),
                    "sounds": list_sounds(),
                })
            if u.path == "/api/ping":
                try:
                    vol = audio().get_volume()
                except SystemExit as e:   # g1_play raises SystemExit on SDK errors
                    raise RuntimeError(str(e)) from None
                return self._json({"ok": True, "volume": vol})
            return self._json({"error": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            return self._json({"error": str(e)}, 500)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if not self._local_only():
                return self._json({"error": "forbidden"}, 403)

            if u.path == "/api/volume":
                global _gain
                level = max(0, min(VOL_MAX, int(self._jbody().get("level", 85))))
                # 0..100 -> hardware volume; 100..VOL_MAX -> hardware 100 + boost.
                hw = min(100, level)
                _gain = 1.0 + max(0, level - 100) / 50.0   # 150 -> ~2.0x
                usb_set_volume(hw)                         # USB speaker hardware volume
                code = audio().set_volume(hw)              # internal speaker volume
                if code:
                    raise RuntimeError(f"robot rejected volume (code {code})")
                return self._json({"ok": True, "level": level, "gain": round(_gain, 2)})

            if u.path == "/api/sync":
                global _sync_ms
                _sync_ms = max(-500, min(1000, int(self._jbody().get("ms", 0))))
                return self._json({"ok": True, "sync_ms": _sync_ms})

            if u.path == "/api/tts":
                d = self._jbody()
                text = (d.get("text") or "").strip()
                if not text:
                    raise RuntimeError("no text provided")
                speaker = int(d.get("speaker", 1))   # 1 = English, 0 = Chinese
                # Prefer ElevenLabs (your chosen English voice) -> PlayStream, since
                # that is the reliable, audible path. Fall back to the robot's
                # built-in TtsMaker if no API key is configured.
                if os.environ.get("ELEVENLABS_API_KEY"):
                    tmp = os.path.join(LIB, ".speak.wav")
                    elevenlabs_generate(text, tmp)
                    play_async(tmp)
                    return self._json({"ok": True})
                code = audio().tts(text, speaker)
                if code:
                    raise RuntimeError(f"robot rejected speech (code {code})")
                return self._json({"ok": True})

            if u.path == "/api/generate":
                d = self._jbody()
                text = (d.get("text") or "").strip()
                if not text:
                    raise RuntimeError("no text provided")
                name = sanitize_name(d.get("name") or text[:24]) + ".wav"
                os.makedirs(LIB, exist_ok=True)
                elevenlabs_generate(text, os.path.join(LIB, name))
                return self._json({"ok": True, "name": name})

            if u.path == "/api/play":
                d = self._jbody()
                if d.get("source") == "asset":
                    path = ensure_click() if d.get("name") == "sync_click" else ensure_test_tone()
                else:
                    path = resolve_sound(d.get("source", "library"), d.get("name", ""))
                dur = play_async(path)
                return self._json({"ok": True, "duration": dur})

            if u.path == "/api/stop":
                stop_usb_play()     # stop the USB speaker too
                _stop_event.set()   # release the playing worker's lock promptly
                a = audio()
                if not a.simulate and a.client is not None:
                    try:
                        a.client.PlayStop("g1-voice-studio")
                    except Exception:
                        pass
                return self._json({"ok": True})

            if u.path in ("/api/upload", "/api/record"):
                raw = self._body()
                if len(raw) < 64:
                    raise RuntimeError("empty audio payload")
                name = sanitize_name((q.get("name") or ["sound"])[0]) + ".wav"
                os.makedirs(LIB, exist_ok=True)
                suffix = ".webm" if u.path == "/api/record" else \
                    os.path.splitext((q.get("filename") or ["in.wav"])[0])[1] or ".bin"
                with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tf:
                    tf.write(raw)
                    src = tf.name
                try:
                    ffmpeg_to_robot_wav(src, os.path.join(LIB, name))
                finally:
                    os.remove(src)
                return self._json({"ok": True, "name": name})

            if u.path == "/api/push":
                items = self._jbody().get("items") or []
                if not items:
                    raise RuntimeError("nothing selected to push")
                paths = [resolve_sound(i.get("source", "library"), i.get("name", ""))
                         for i in items]
                msg = push_to_robot(paths)
                pushed = load_pushed()
                for i, p in zip(items, paths):
                    pushed[f"{i.get('source','library')}/{os.path.basename(p)}"] = {
                        "sha256": sha256_file(p)}
                save_pushed(pushed)
                return self._json({"ok": True, "message": msg})

            if u.path == "/api/delete":
                name = os.path.basename(self._jbody().get("name", ""))
                path = os.path.join(LIB, name)
                if not os.path.isfile(path):
                    raise RuntimeError(f"not found in library: {name}")
                os.remove(path)
                pushed = load_pushed()
                pushed.pop(f"library/{name}", None)
                save_pushed(pushed)
                return self._json({"ok": True})

            return self._json({"error": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            return self._json({"error": str(e)}, 500)


# --------------------------------------------------------------------------

def main():
    global ARGS
    p = argparse.ArgumentParser(description="G1 Voice Studio server")
    p.add_argument("--robot-ip", default=os.environ.get("G1_ROBOT_IP", ""))
    p.add_argument("--iface", default=os.environ.get("G1_IFACE", ""))
    p.add_argument("--user", default="unitree")
    p.add_argument("--ssh-key", default=os.environ.get("G1_SSH_KEY", ""),
                   help="identity file for Save-to-G1 pushes (when running off-robot)")
    p.add_argument("--on-robot", action="store_true",
                   help="the server IS running on the G1: Save-to-G1 copies locally, no SSH")
    p.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8766)))
    p.add_argument("--simulate", action="store_true",
                   help="no robot / no SDK; robot actions are logged only")
    ARGS = p.parse_args()

    for d in (LIB, STATE_DIR):
        os.makedirs(d, exist_ok=True)
    ensure_test_tone()

    if not ARGS.simulate and not ARGS.iface:
        print("warn: no --iface set; robot calls will fail until configured "
              "(or restart with --simulate)", file=sys.stderr)

    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    mode = "SIMULATE" if ARGS.simulate else f"robot={ARGS.robot_ip or '?'} iface={ARGS.iface or '?'}"
    print(f"G1 Voice Studio  http://127.0.0.1:{ARGS.port}  [{mode}]")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
