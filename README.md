<p align="center">
  <img src="assets/textures/gui/logo.png" alt="VibezCraft" width="480">
</p>

<p align="center">
  <a href="https://github.com/donth77/vibezcraft/releases/latest"><img src="https://img.shields.io/github/v/release/donth77/vibezcraft?label=release" alt="Latest release"></a>
  <a href="https://godotengine.org"><img src="https://img.shields.io/badge/Godot-4.x-478CBF?logo=godotengine&logoColor=white" alt="Godot 4.x"></a>
  <a href="https://github.com/donth77/vibezcraft"><img src="https://img.shields.io/badge/language-GDScript%20%2B%20C%2B%2B-blue" alt="GDScript + C++"></a>
  <a href="https://vibezcraft.net"><img src="https://img.shields.io/badge/website-vibezcraft.net-62b47a" alt="VibezCraft website"></a>
  <a href="https://suno.com/playlist/8ac3096a-6040-47d8-af33-cfadb9b4438c"><img src="https://img.shields.io/badge/music-Suno%20playlist-9333EA" alt="Suno playlist"></a>
</p>

A single-player clone of MC Alpha, built in **Godot 4, GDScript, and C++**.

Gameplay and scene-graph logic is GDScript. Six performance-critical paths—chunk meshing, terrain generation, lighting, water effects, pathfinding, and voxel collision—run in native C++ via GDExtension, with GDScript fallbacks.

## Download

**[Download VibezCraft v1.1.0](https://vibezcraft.net/#download)** for macOS or Windows. The universal macOS build is signed and notarized for Apple Silicon and Intel Macs; Windows is available as an installer or portable ZIP.

[Release notes](https://github.com/donth77/vibezcraft/releases/tag/v1.1.0) · [All releases](https://github.com/donth77/vibezcraft/releases)

## Features

- **Infinite procedural world** — 2D Perlin heightmap, stratified terrain layers, oak trees, caves, ore veins (coal/iron/gold/diamond)
- **The Nether** — working obsidian portals, dimension travel, lava seas, netherrack, soul sand, glowstone, ghasts, and zombie pigmen
- **Redstone circuits** — dust, torches, levers, buttons, pressure plates, doors, TNT, rails, and four-delay repeaters with directional full-strength output
- **100+ block types and states** — stone family, ores, wood, glass, sand, gravel, torches, fences, stairs, doors, chests, furnaces, flowing fluids, fire, beds, jukeboxes, slabs, plants, snow, TNT, redstone, Nether blocks, rails, signs, wool (16 colors), and metal blocks
- **80+ items** — full tool tiers (pickaxe/axe/shovel/sword/hoe × wood/stone/iron/diamond/gold), armor sets (leather/iron/gold/diamond), bow + arrows, buckets, flint & steel, shears, fishing rod, food, raw materials, redstone repeaters, glowstone dust, 8 music discs, and the minecart family
- **11 mob species** — pigs, cows, chickens, sheep, zombies, skeletons, spiders, creepers, slimes, zombie pigmen, and ghasts
- **Crafting & smelting** — recipe registry (shaped + shapeless) from `data/recipes.json`, 2×2 inventory grid + 3×3 crafting table. Furnace with fuel/input/output slots, burn-time tracking
- **Day/night cycle** — 20-minute day, sky color gradient, sun direction, dynamic lighting
- **Light propagation** — sky light + block light with BFS flood fill, per-face brightness LUT in shader
- **Water & lava physics** — finite flow propagation, swim mechanics, bucket placement/pickup
- **Combat** — melee + ranged (bow + arrows with charge mechanic + critical hits), knockback, armor damage reduction, fall damage, drowning, fire/lava, health regen, death screen with respawn
- **Dungeons** — cobble/mossy cobble rooms with mob spawner cages + chest loot
- **Beds** — Sleep mechanic, multi-cell place/break, set spawn point
- **Jukeboxes + 8 music discs** — Ambient music auto-pauses during disc playback
- **Farming + fishing** — wheat crops, hoe tilling, tall grass seed drops; cast/reel fishing with raw + cooked fish
- **Minecart family** — rails (straight + curve), standard + chest + furnace minecarts
- **Chest, furnace, jukebox storage** — per-block inventories with dedicated UI screens
- **World save/load** — purpose-built binary format under `user://World{N}/` (chunks, player position + inventory, entities, world metadata) with crash-safe `.new`/`.old` recovery; multi-world select screen
- **Creative mode** — toggleable from Pause → Options or via the hotkey; flight, no fall damage, instant block break
- **Rebindable controls** — every gameplay action mappable from Main Menu → Settings → Controls or in-game Pause → Options → Controls; persists to `user://settings.cfg`
- **In-game item + mob spawners** — grid of every block + item with quantity selector (F4) + grid of every mob species (F6); available in Creative or Debug mode
- **Audio** — footstep cadence, block break/place SFX, per-mob idle/hurt/death/step sounds, ambient sounds, music player ([Suno playlist](https://suno.com/playlist/8ac3096a-6040-47d8-af33-cfadb9b4438c))
- **Player model** — first-person and third-person with arm/leg animation, held-item rendering
- **Threaded chunk loading** — `WorkerThreadPool` for worldgen + meshing, streaming around player
- **Native C++ fast paths (6 GDExtensions)** — chunk mesher, worldgen base terrain, lighting BFS, water FX, pathfinder A*, voxel-AABB collider — all with GDScript fallback



## Build

The game loads a prebuilt native library (`bin/libmesher_native.*.dylib|so|dll`). When you first clone (or pull changes under `src/`), rebuild:

```sh
git submodule update --init --recursive              # fetch godot-cpp
scons platform=macos target=template_debug -j8       # or platform=linux / windows
```

Without the native library the game still runs — it falls through to pure-GDScript implementations and logs `[Game] using GDScript Mesher` / `[Game] using GDScript Worldgen` at startup.

## Web build

The browser build needs the GDExtension compiled to wasm with **emsdk 4.0.20** (the exact Emscripten the Godot 4.6 official templates use — other versions break the side-module ABI):

```sh
source ~/emsdk/emsdk_env.sh
scons platform=web target=template_release threads=yes -j8
godot --headless --export-release "Web" build/web/index.html
python3 scripts/dev/serve_web.py 8060      # local test server (COOP/COEP headers)
```

Hosting notes — the threaded build requires `SharedArrayBuffer`, so production hosting must:

- send `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` on every response (itch.io supports this; GitHub Pages doesn't set headers — use a [coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker) shim there);
- serve **brotli or gzip** (`.wasm` is ~40 MB raw, ~10 MB brotli) with normal long-lived cache headers — each worker thread re-fetches `index.js` if caching is disabled;
- phone browsers get tuned defaults automatically (Tiny render distance, Fast clouds, reduced 3D resolution, touch controls).

## Run

```sh
godot --path .                         # open in editor
godot --path . main.tscn               # run main scene directly
```

## Controls

All gameplay actions are configurable in **Main Menu → Settings → Controls** (or in-game **Pause → Options → Controls**). The list below is the default mapping; click any binding in the controls screen and press a key or mouse button to rebind. Overrides persist to `user://settings.cfg`.

### Gamepad

Controllers work on desktop and in the browser (press any button once so the browser exposes the pad). Bindings mirror Bedrock Edition's default layout and coexist with keyboard/mouse — both stay live:

| Control | Binding |
|---|---|
| Move / Look | Left stick / Right stick |
| Jump / Fly up | A (Cross) |
| Sneak / Dismount / Fly down | B (Circle) |
| Attack / Destroy | Right trigger |
| Place / Use | Left trigger |
| Hotbar cycle | LB / RB |
| Open inventory | Y or X (Triangle / Square) |
| Toggle perspective | D-pad up |
| Drop item | D-pad down |
| Pause | Start / Menu |

L3 (sprint) and R3 (slow-descend) are unbound — Alpha predates both mechanics. Menus and inventory screens remain pointer-driven (mouse on desktop, touch on mobile); pad bindings are fixed defaults (the rebind screen manages keyboard/mouse).

### Creative & Debug shortcuts

Creative is its own user-facing mode — no debug-toggle required. Debug mode adds a stats panel + tool-tuner / lighting / scout shortcuts, and shows debug rows in the controls screen.

| Action | Default | Mode required |
|---|---|---|
| Toggle Creative mode | **G** / **F1** | none |
| Toggle Debug mode | **`** (backtick) | none |
| Open Item spawner | **F4** | Creative or Debug |
| Open Mob spawner | **F6** | Creative or Debug |
| Toggle Stats panel | **F3** | Debug |
| Tool tuner (held-item pose) | **T** | Debug |
| Cycle lighting heatmap | **F8** | Debug |
| Dump biome scan | **B** | Debug |
| Fast day cycle (30s) | **N** | Debug |

### Configuration

All vars use precedence: **shell env > `.env` file > code default**. Copy `.env.example` to `.env` for per-developer overrides (`.env` is gitignored).

| Var | Default | Effect |
|---|---|---|
| `MC_CLONE_TEXTURE_PACK` | `pixel_perfection` | Active block texture pack (folder under `assets/textures/packs/`) |
| `MC_CLONE_DEBUG_MODE` | `false` | Start with debug mode enabled |
| `MC_CLONE_RESOLUTION` | `1920x1080` | Window size override (e.g. `2560x1440` for HiDPI) |

### Texture packs

Block textures live under `assets/textures/packs/{pack_name}/`. Cell size auto-detects from the first loaded PNG.

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
