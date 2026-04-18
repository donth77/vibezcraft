# Minecraft Alpha Clone

A from-scratch, AI-assisted clone of Minecraft Java Edition Alpha (2010), built in Godot 4 + GDScript.

## Docs
- [`.claude/PLANNING.md`](./.claude/PLANNING.md) — vision, stack rationale, Alpha mechanics reference
- [`.claude/implementationplan.md`](./.claude/implementationplan.md) — phase-by-phase execution plan

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
| Sneak | **Shift** (hold by default; toggle via Player.sneak_toggle export) |
| Break block | **Left mouse** (hold) |
| Place block | **Right mouse** |
| Select hotbar slot | **1**–**9** |
| Release / re-capture mouse | **Esc**, then click in window |

### Debug shortcuts

Backtick (`` ` ``) toggles debug mode (top-right shows "DEBUG"). The shortcuts below only work while debug mode is on.

| Action | Key |
|---|---|
| Toggle debug mode | **`** (backtick) |
| Toggle Creative mode (instant break, ignores bedrock, no drop-table gating) | **G** *(or Fn + F1 on Mac)* |
| Fill hotbar with one stack of every block type | **H** *(or Fn + F2 on Mac)* |

### Configuration env vars

All vars use this precedence: **shell env > `.env` file > code default**. Copy `.env.example` to `.env` and edit for per-developer overrides (`.env` is gitignored).

| Var | Values | Default | Effect |
|---|---|---|---|
| `MC_CLONE_TEXTURE_PACK` | folder name under `assets/textures/blocks/packs/` | `pixel_perfection` | Active block texture pack |
| `MC_CLONE_DEBUG_MODE` | `1`/`true`/`yes`/`on` (case-insensitive) → enabled, anything else → disabled | `false` | Whether debug mode is on at launch (backtick still toggles at runtime) |

### Texture packs

Block textures live under `assets/textures/blocks/packs/{pack_name}/`. Active pack precedence:

1. `MC_CLONE_TEXTURE_PACK` shell environment variable (highest)
2. `MC_CLONE_TEXTURE_PACK=...` line in a project-root `.env` file
3. `texture_pack` `@export` on the Game autoload (set in editor)

```sh
MC_CLONE_TEXTURE_PACK=programmer_art godot --path . main.tscn
```

Or copy `.env.example` to `.env` and edit the value — useful when launching from the editor:

```sh
cp .env.example .env
# then edit .env to set your preferred pack
```

The `.env` file is gitignored.

To add a new pack, drop the 11 named PNGs (`stone`, `cobblestone`, `dirt`, `grass_top`, `grass_side`, `bedrock`, `sand`, `log_top`, `log_side`, `planks`, `leaves`) into `assets/textures/blocks/packs/{your_name}/`. Cell size auto-detects from the first texture.

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

## First-time setup (per developer)

```sh
./scripts/dev/install-hooks.sh         # install git pre-commit hook
```
