# CLAUDE.md

Guidance for Claude Code when working in this repo.

## Project

A from-scratch clone of **Minecraft Java Edition Alpha v1.2.0 (2010)** in **Godot 4 + GDScript**. Strict Alpha-core mechanics with tasteful modern QoL. Overworld only, no Nether. Purpose-built binary save format (not Anvil-compatible).

Canonical planning docs:
- `.claude/PLANNING.md` — vision, stack rationale, Alpha mechanics reference
- `.claude/implementationplan.md` — phase-by-phase execution plan (read this before starting work on a new phase)
- `.claude/alpha-mechanics.md` — reference for Alpha-faithful numbers (break times, heights, etc.)
- `optimizations.md` — catalog of higher-risk perf improvements deliberately deferred

## Current state

**Phase 3 shipped:** infinite world with threaded chunk loading, 2D Perlin worldgen, naive face-culled meshing, shared-material atlas rendering, per-block edge outlines via shader, pluggable texture packs.

Next: Phase 4 (inventory & hotbar) per `implementationplan.md`.

## Layout

```
scripts/
  game.gd                     # autoload — warms BlockAtlas + Worldgen on main thread
  input_actions.gd            # InputMap setup
  world/
    blocks.gd                 # block IDs, break times, drop table, face textures
    chunk.gd                  # pure block-data container (PackedByteArray, 16×128×16)
    chunk_node.gd             # Node3D wrapper: builds mesh + trimesh collision
    chunk_manager.gd          # streams chunks around player via WorkerThreadPool
    mesher.gd                 # face-culled mesher → ArrayMesh arrays
    worldgen.gd               # FastNoiseLite 2D Perlin heightmap
    block_atlas.gd            # packs per-block PNGs into one atlas, owns shared ShaderMaterial
  player/                     # player.gd, interaction.gd, inventory.gd, item_stack.gd, character_model.gd
  ui/                         # hotbar_ui.gd, item_icons.gd
  dev/                        # pre-commit.sh, install-hooks.sh
scenes/                       # chunk.tscn, chunk_manager.tscn, player, ui, entities
shaders/chunk.gdshader        # cull_back, per-face Notch shading, atlas sampling
tests/                        # GUT tests (test_*.gd)
assets/textures/blocks/
  packs/{pack_name}/          # active pack's 11 PNGs (stone, dirt, grass_top, …)
  raw/                        # legacy originals; packs/ is the source of truth
```

## Architecture invariants

**Classes vs autoloads.** Only `Game` (scripts/game.gd) is an autoload. `Blocks`, `Chunk`, `Mesher`, `Worldgen`, `BlockAtlas` are `class_name` statics / `RefCounted` — call directly (`BlockAtlas.texture()`), no `get_node`.

**Threading contract.** `WorkerThreadPool` runs `_compute_chunk_data` (worldgen + meshing). The main thread owns: GPU mesh upload, scene-tree manipulation, `_pending` dict. `_ready_results` is the hand-off, guarded by `_result_mutex`. `Game._ready` warms `BlockAtlas.build()` and `Worldgen.surface_height(0,0)` on the main thread so workers never hit lazy-init races — preserve this.

**Shared `ShaderMaterial`.** One material instance for all chunks, owned by `BlockAtlas._material`. Don't create per-chunk materials. If you need per-chunk shader parameters, push them into vertex attributes, not new materials.

**Chunk dims are fixed.** `SIZE_X=16`, `SIZE_Y=128`, `SIZE_Z=16`. Y-major indexing (`y * SIZE_X * SIZE_Z + z * SIZE_X + x`). Changing these breaks save format, mesher, tests.

**Block IDs are stable.** `scripts/world/blocks.gd` IDs are uint8; append new IDs to the end, never renumber — they're persisted in `Chunk.blocks` (`PackedByteArray`).

**Deterministic worldgen.** `Worldgen.generate_chunk(x, z)` is pure on `(WORLD_SEED, x, z)`. Don't introduce time/RNG dependencies — chunk reload must reproduce identical terrain.

**Mesher emits all 6 faces per block, with neighbor culling inside a chunk only.** Chunk boundaries emit outward faces unconditionally (known limitation — see `optimizations.md` §2). Don't "fix" this without also handling neighbor-load re-meshing.

**Face winding.** Reversed index order (`[base, base+2, base+1, base, base+3, base+2]`) so `cull_back` keeps the outward side. UVs V-flipped so textures aren't upside down. See `mesher.gd` comments.

## Commands

```sh
# Run
godot --path . main.tscn
MC_CLONE_TEXTURE_PACK=programmer_art godot --path . main.tscn

# Tests (GUT)
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -ginclude_subdirs -gexit

# Format + lint (pre-commit runs these)
gdformat --check scripts/ tests/
gdformat scripts/ tests/
gdlint scripts/ tests/
```

## Working agreement (from implementationplan.md)

Each phase ends in: green test suite, working build, git commit. Don't start the next phase until the previous is demoable.

## Conventions

- **Tabs for indentation** in `.gd` (enforced by gdformat).
- **Snake_case** for files, vars, funcs; **PascalCase** for `class_name`; **SCREAMING_SNAKE** for consts.
- **Private members** prefixed with `_`.
- **Type everything.** `var foo: int`, `func bar(x: int) -> void`. Untyped GDScript is slower and errors surface later.
- **`@export`** for values a designer might tweak; keep export hints on numerics (`@export_range`).
- **Comments explain *why*, not *what*.** Existing code follows this — match the tone (e.g. chunk_manager.gd's comments on the threading contract, mesher.gd's note on winding).
- **Tests are GUT.** `extends GutTest`, `test_*` functions, `before_each` for setup. `BlockAtlas.reset()` before any test that touches rendering.
- **Pre-commit hook** runs gdformat + gdlint + `godot --headless --check-only`. Don't skip with `--no-verify`.

## When asked to optimize

Read `optimizations.md` first — the high-leverage wins are already documented there with regression notes. Don't repeat the audit. Confirm whether an item moved from "deferred" to "wanted now" before implementing, since several break existing tests or shipped visual features (per-block edge outlines, exact vertex counts in test_mesher).

## Gotchas

- **`Chunk.get_block` returns `AIR` for OOB.** Mesher relies on this for the "emit face at world edge" behavior; don't change it to panic.
- **`max_y` is monotonic.** Breaking the topmost block doesn't decrease it. Acceptable cost: 1 extra layer of meshing iteration.
- **`create_trimesh_shape()` is main-thread and ~10–100 ms.** Rare today (player edits only); becomes a spike once dynamic blocks land — see `optimizations.md` §4.
- **Texture pack cell size auto-detects** from the first loaded PNG in `packs/{active}/`. All 11 textures in a pack must be the same square size, or they're resized nearest-neighbor.
- **Env-var precedence** for pack selection: shell `MC_CLONE_TEXTURE_PACK` > `.env` file > `@export texture_pack` on Game autoload.

## Don'ts

- Don't introduce per-chunk `ShaderMaterial` or `Shader.new()` calls.
- Don't call `load()` inside the worker thread — `ResourceLoader` is main-thread-safe only for some types. Warm resources in `Game._ready`.
- Don't mutate `Chunk.blocks` from a worker thread while the main thread may read it. Today, a chunk is owned by one thread at a time (worker during gen/mesh, main thereafter); preserve that.
- Don't add greedy meshing as a point fix — it breaks `test_mesher` assertions and the per-block edge-outline shader. Plan it alongside Phase 4+ shader work.
- Don't auto-commit. Wait for an explicit "commit" from the user.
