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

- **Infinite procedural world**
- **The Nether**
- **Redstone circuits** 
- **100+ block types and states** 
- **80+ items** 
- **11 mob species**
- **Crafting & smelting**
- **Day/night cycle** 
- **Water & lava physics**
- **Combat**
- **Dungeons**
- **Beds**
- **Jukeboxes + 8 music discs** 
- **Farming + fishing**
- **Minecarts**
- **Chest, furnace, jukebox storage**
- **World save/load** 
- **Creative mode**
- **Rebindable controls**
- **In-game item + mob spawners**
- **Audio** 
- **1st and 3rd person** 


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
