# VibezCraft v1.0

A single-player clone of MC Alpha, built in Godot 4, GDScript, and C++.

## Downloads

- **macOS** (Apple Silicon + Intel, universal binary) — `VibezCraft-macOS-universal.zip`
- **Windows** (x86_64) — `VibezCraft-Windows-x86_64.zip`

## Highlights

- **Infinite procedural world** with 88 block types, oak trees, caves, and ore veins (coal/iron/gold/diamond)
- **80+ items** — full tool tiers, armor sets, bow + arrows, buckets, flint & steel, shears, fishing rod, food, music discs
- **9 mob species** — pigs, cows, chickens, sheep (passive); zombies, skeletons, spiders, creepers, slimes (hostile)
- **Crafting & smelting** — 2×2 inventory grid, 3×3 crafting table, furnace with burn-time tracking
- **Day/night cycle** with dynamic lighting, sky light + block light BFS flood fill
- **Water & lava physics** — finite flow propagation, swim mechanics, bucket placement
- **Combat** — melee + ranged (bow charge + critical hits), knockback, armor, fall damage, drowning, fire/lava
- **Dungeons** — cobble/mossy cobble rooms with mob spawner cages + chest loot
- **Beds + sleep mechanic** — fast-forward to dawn, set spawn point
- **Jukeboxes + 8 music discs**
- **Farming + fishing**
- **Minecart family** — straight + curve rails, boost rails, passenger/chest/furnace carts
- **World save/load** — purpose-built binary format, multi-world select, crash-safe recovery
- **Creative mode** + rebindable controls
- **Native C++ fast paths** (chunk mesher, worldgen, lighting, water FX, pathfinder A*, voxel collider) with GDScript fallback

## Run

### macOS

The app is ad-hoc signed but not notarized (no Apple Developer Program). On first launch macOS will refuse to open it.

1. Unzip `VibezCraft-macOS-universal.zip`
2. **Remove quarantine** (one-time, in Terminal): `xattr -dr com.apple.quarantine /path/to/VibezCraft.app`
   - Or: right-click `VibezCraft.app` → **Open** → click **Open** in the warning dialog
3. Double-click thereafter

### Windows
1. Unzip `VibezCraft-Windows-x86_64.zip`
2. Run `VibezCraft.exe`
3. Windows SmartScreen may prompt — click **More info** → **Run anyway**

## Controls

All gameplay actions are configurable in **Main Menu → Settings → Controls**. Defaults:

- **WASD** — move, **Space** — jump, **Shift** — sneak
- **Left-click** — break, **Right-click** — place/interact
- **E** — inventory, **1-9** — hotbar
- **G** / **F1** — toggle Creative mode
- **`** (backtick) — toggle Debug mode (adds stats panel + dev shortcuts)

## Notes

- Save files live under your user app data directory (`~/Library/Application Support/Godot/app_userdata/VibezCraft/` on macOS, `%APPDATA%\Godot\app_userdata\VibezCraft\` on Windows).
- Binaries are unsigned. macOS requires right-click → Open on first launch; Windows requires SmartScreen override.
- Source: https://github.com/donth77/vibezcraft
