# Music Tracks — Vanilla Alpha 1.2.6 Mapping

Place your `.mp3` (or `.ogg`) files here using the names below.
The music player picks randomly from the full pool with no category distinction.

| File | Vanilla equivalent (C418) | Mood match |
|---|---|---|
| `First-Light.mp3` | "Minecraft" (calm1) | Opening piano — peaceful, hopeful |
| `Green-Distance.mp3` | "Clark" (calm2) | Layered synths + piano, airy, warm |
| `Long-Shadow.mp3` | "Sweden" (calm3) | Bittersweet piano, emotional |
| `Hollow-Earth.mp3` | "Subwoofer Lullaby" (hal1) | Deep, ambient, reverb-heavy |
| `Bedrock.mp3` | "Living Mice" (hal2) | Dark drone + sparse piano |
| `Open-Sky.mp3` | "Haggstrom" (hal3) | Brighter, uplifting, synth pads |
| `Hearthstone.mp3` | "Danny" (hal4) | Warm, cozy, gentle build |
| `Still-Water.mp3` | *(no vanilla equivalent)* | Ultra-minimal ambient texture |

## Audio specs

- Format: MP3 or OGG Vorbis (Godot imports both natively)
- Sample rate: 44.1 kHz
- Target loudness: -18 LUFS (sits under SFX)
- No loop points — vanilla doesn't loop individual tracks

## Normalization command

```sh
ffmpeg -i input.mp3 -filter:a loudnorm=I=-18 First-Light.mp3
```
