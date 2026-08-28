# Replacement Rules

Every replacement file must match the original on the dimensions listed below. Mismatches don't just sound bad — they can cause the playback process to error out, fall back to silence, or in the worst case, fail in a tight loop.

## Match exactly

| Attribute        | Why                                                                                           |
|------------------|-----------------------------------------------------------------------------------------------|
| **Filename**     | The robot calls the file by literal name. Renaming breaks the trigger.                        |
| **Path**         | Same directory. Don't reorganize.                                                             |
| **File format / codec** | If the original is `pcm_s16le` WAV, the replacement must be `pcm_s16le` WAV. Use `ffprobe`. |
| **Sample rate (Hz)** | Wrong sample rate plays at wrong pitch/speed or fails to decode.                               |
| **Bit depth**    | Same.                                                                                              |
| **Channel count** | Mono → mono, stereo → stereo.                                                                     |
| **Owner:Group**  | Match the original `chown`. The playback process may run as a specific user.                  |
| **Permissions**  | Match the original octal mode (usually `0644`).                                               |

## Match closely (within a tolerance)

| Attribute       | Rule                                                                                                      |
|-----------------|--------------------------------------------------------------------------------------------------------   |
| **Duration**    | Aim for the original ± 30%. Some triggers wait for playback to finish; a 10× longer clip may stall a UI.  |
| **Peak loudness** | Normalize to roughly -1.5 dBTP, -16 LUFS integrated. `convert_audio_files.sh` does this for you.        |
| **DC offset**   | Should be near zero. ffmpeg will fix this in re-encoding.                                                 |

## You can ignore

- Embedded metadata tags (artist, album). Trim or leave; nothing reads them.
- Container-internal timestamps.

## Recording guidance for the English source files

- Record in a quiet room at 48 kHz, 24-bit WAV. Downsampling later is lossless enough; upsampling is not.
- One sentence per file. Keep prompts short — under ~3 seconds where possible.
- Leave 100–200 ms of silence at the start and end. The robot's playback path sometimes clips the very first frames.
- Voice should match the *purpose*, not the original speaker. A friendly tone for "app connected"; a firmer, lower tone for warnings.
- Don't add music beds or sound effects unless the original had them.

## Pre-flight checklist for every replacement file

```bash
ffprobe -v error -show_streams -show_format <replacement> | grep -E \
  '^(codec_name|sample_rate|bits_per_sample|channels|duration|format_name)='
```

Compare line-by-line with the same probe of the original. They should match on everything except `duration`.

## Per-file replacement record

For every file you replace, capture:

```
file:            /unitree/audio/<filename>
original sha256: ...
new sha256:      ...
owner:           root:root
mode:            0644
trigger event:   ...
test result:     pass / fail / partial
notes:           ...
```
