<p align="center">
  <img src="assets/textures/gui/logo.png" alt="VibezCraft" width="480">
</p>

<p align="center">
  <a href="https://godotengine.org"><img src="https://img.shields.io/badge/Godot-4.x-478CBF?logo=godotengine&logoColor=white" alt="Godot 4.x"></a>
  <a href="https://github.com/donth77/vibezcraft"><img src="https://img.shields.io/badge/language-GDScript%20%2B%20C%2B%2B-blue" alt="GDScript + C++"></a>
</p>

A single-player clone of MC Alpha, built in **Godot 4, GDScript, and C++**. 

Gameplay and scene-graph logic is pure GDScript; chunk meshing and worldgen base-terrain are native C++ via GDExtension (with byte-identical GDScript fallbacks). 

## Features

- **Infinite procedural world** — 2D Perlin heightmap, stratified terrain layers, oak trees, caves, ore veins (coal/iron/gold/diamond) via a deterministic port of vanilla `WorldGenMinable`
- **36 block types** — full stone family, ores, wood, glass, sand, gravel, torches, fences, stairs, doors, chests, furnaces, ladders, flowing water & lava
- **50 items** — tools (pickaxe/axe/shovel/sword/hoe) in wood/stone/iron/diamond/gold, armor sets, buckets, flint & steel, raw materials
- **Crafting** — recipe registry (shaped + shapeless) from `data/recipes.json`, 2x2 inventory grid + 3x3 crafting table
- **Smelting** — furnace with fuel/input/output slots, burn-time tracking, vanilla smelt times
- **Day/night cycle** — vanilla 20-minute day, sky color gradient, sun direction, dynamic lighting
- **Light propagation** — sky light + block light with BFS flood fill, per-face brightness LUT in shader
- **Water & lava physics** — finite flow propagation, swim mechanics, bucket placement/pickup
- **Health & damage** — fall damage, drowning, fire/lava, health regeneration, death screen with respawn
- **Chest & furnace storage** — per-block inventories with dedicated UI screens
- **Audio** — footstep cadence, block break/place SFX, ambient sounds, C418-style music player
- **Steve player model** — first-person and third-person with arm/leg animation, held-item rendering
- **Threaded chunk loading** — `WorkerThreadPool` for worldgen + meshing, streaming around player
- **Native C++ fast paths** — chunk mesher and worldgen via GDExtension, with GDScript fallback



## Build

The game loads a prebuilt native library (`bin/libmesher_native.*.dylib|so|dll`). When you first clone (or pull changes under `src/`), rebuild:

```sh
git submodule update --init --recursive              # fetch godot-cpp
scons platform=macos target=template_debug -j8       # or platform=linux / windows
```

Without the native library the game still runs — it falls through to pure-GDScript implementations and logs `[Game] using GDScript Mesher` / `[Game] using GDScript Worldgen` at startup.

## Run

```sh
godot --path .                         # open in editor
godot --path . main.tscn               # run main scene directly
```

## Controls

| Action | Key |
|---|---|
| Move | **W A S D** |
| Look | Mouse |
| Jump | **Space** |
| Sneak | **Shift** (hold) |
| Break block | **Left mouse** (hold) |
| Place block / interact | **Right mouse** |
| Select hotbar slot | **1**–**9** |
| Open inventory | **E** |
| Drop item | **Q** |
| Third-person toggle | **V** / **F5** |
| Release mouse | **Esc** |

### Debug shortcuts

Backtick (`` ` ``) toggles debug mode. These shortcuts only work while debug mode is on:

| Action | Key |
|---|---|
| Toggle debug mode | **`** (backtick) |
| Toggle Creative mode | **G** |
| Open item spawner | **J** |
| Tool tuner (held-item pose) | **T** |
| Fast day cycle (30s) | **N** |

### Configuration

All vars use precedence: **shell env > `.env` file > code default**. Copy `.env.example` to `.env` for per-developer overrides (`.env` is gitignored).

| Var | Default | Effect |
|---|---|---|
| `MC_CLONE_TEXTURE_PACK` | `pixel_perfection` | Active block texture pack (folder under `assets/textures/blocks/packs/`) |
| `MC_CLONE_DEBUG_MODE` | `false` | Start with debug mode enabled |
| `MC_CLONE_RESOLUTION` | `1920x1080` | Window size override (e.g. `2560x1440` for HiDPI) |

### Texture packs

Block textures live under `assets/textures/blocks/packs/{pack_name}/`. Cell size auto-detects from the first loaded PNG.

```sh
MC_CLONE_TEXTURE_PACK=programmer_art godot --path . main.tscn
```

## Test

```sh
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests/ -gexit
```

## Lint & format

```sh
gdformat --check scripts/ tests/       # check formatting
gdformat scripts/ tests/               # apply formatting
gdlint scripts/ tests/                 # lint
```

## First-time setup

```sh
./scripts/dev/install-hooks.sh         # install git pre-commit hook
```
