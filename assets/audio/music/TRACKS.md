# Music Tracks

Place your `.mp3` (or `.ogg`) files here using the names below.
The music player picks randomly from the full pool with no category distinction.

| File | Mood match |
|---|---|
| `First-Light.mp3` | Opening piano — peaceful, hopeful |
| `Green-Distance.mp3` | Layered synths + piano, airy, warm |
| `Long-Shadow.mp3` | Bittersweet piano, emotional |
| `Hollow-Earth.mp3` | Deep, ambient, reverb-heavy |
| `Bedrock.mp3` | Dark drone + sparse piano |
| `Open-Sky.mp3` | Brighter, uplifting, synth pads |
| `Hearthstone.mp3` | Warm, cozy, gentle build |
| `Still-Water.mp3` | Ultra-minimal ambient texture |

## Audio specs

- Format: MP3 or OGG Vorbis (Godot imports both natively)
- Sample rate: 44.1 kHz
- Target loudness: -18 LUFS (sits under SFX)
- No loop points — vanilla doesn't loop individual tracks

## Normalization command

```sh
ffmpeg -i input.mp3 -filter:a loudnorm=I=-18 First-Light.mp3
```
