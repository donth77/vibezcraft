# Bundled Fonts

## Minecraft.otf

- Source: https://github.com/IdreesInc/Minecraft-Font (release v1.0)
- Author: Idrees Hassan, 2022
- License: SIL Open Font License v1.1 (`OFL.txt`)

## ascii.png

- Source: https://github.com/InventivetalentDev/minecraft-assets (branch `1.7.10`),
  path `assets/minecraft/textures/font/ascii.png`
- Reference asset only; not currently used at runtime. Kept in case we
  build a true bitmap font later.

# Bundled Audio

## assets/audio/sfx/ — Alpha 1.2.6 sound set

- Source: Mojang's Alpha-era resources payload, extracted locally to
  `~/Library/Application Support/minecraft/resources/sound3/`. Alpha
  shipped its sounds from that server rather than from the game jar, so
  `scripts/dev/internal/extract_alpha_pack.py` (which reads the jar)
  cannot produce them and no jar mirror carries them either.
- Only the clips the decompiled source actually references are vendored.
  The zombie set drops `infect`/`remedy`/`wood*`/`metal*`; the ghast set
  drops `affectionate scream.ogg`, which `am.java` never plays.
- Vanilla filenames are kept verbatim — including `fireball4.ogg`, which
  has no 1 through 3.
- This is original Mojang audio — included here only for personal/
  non-commercial use as part of an Alpha clone study project, on the
  same footing as the GUI textures below.

# Bundled GUI Textures

## ../textures/gui/inventory.png

- Source: same repo as `ascii.png`, branch `1.7.10`, path
  `assets/minecraft/textures/gui/container/inventory.png`
- The Alpha 1.2.6 branch of that repo only mirrors launcher icons;
  the player-inventory background texture has been visually stable
  since Alpha so the 1.7.10 file is layout-identical for our purposes.
- This is original Mojang artwork — included here only for personal/
  non-commercial use as part of an Alpha clone study project.
