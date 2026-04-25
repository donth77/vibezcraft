# CLAUDE.md

Guidance for Claude Code when working in this repo.

## Project

A from-scratch clone of **Minecraft Java Edition Alpha v1.2.6 (late 2010)** in **Godot 4, GDScript, and C++**. Strict Alpha-core mechanics with tasteful modern QoL. Targeting v1.2.6's full feature set with two deliberate exceptions — the **Nether** and **multiplayer / SMP** are both out of scope. Purpose-built binary save format (not Anvil-compatible).

Gameplay and scene-graph logic is GDScript. Two performance-critical paths are native C++ via GDExtension:
- `MesherNative.mesh_chunk_data` (`src/mesher_native.cpp`) — chunk meshing + collision face soup.
- `WorldgenNative.build_base_terrain` (`src/worldgen_native.cpp`) — heightmap + stratified layer fill (ores + trees stay in GDScript).

Both have pure-GDScript reference implementations (`Mesher.mesh_chunk`, `Worldgen._build_base_terrain_gdscript`) that the native ports must match byte-for-byte; parity is enforced by `tests/test_mesher_native.gd` and `tests/test_worldgen_native.gd`. When the native library isn't built, the game falls through to GDScript — there's no hard dependency on the extension loading.

Canonical planning docs:
- `.claude/PLANNING.md` — vision, stack rationale, Alpha mechanics reference
- `.claude/implementationplan.md` — phase-by-phase execution plan (read this before starting work on a new phase)
- `.claude/alpha-mechanics.md` — reference for Alpha-faithful numbers (break times, heights, etc.)
- `optimizations.md` — catalog of higher-risk perf improvements deliberately deferred

## Current state

**Phase 5 shipped:** crafting & tools.

- **Worldgen:** 2D Perlin heightmap, stratified bedrock/stone/dirt/grass, oak trees, ore veins (coal/iron/gold/diamond) via a deterministic port of vanilla `WorldGenMinable` (ellipsoid-along-line fill). Each chunk runs 4 decoration passes (own + 3 SW neighbors) to recover vanilla's +8,+8 spillover without cross-chunk writes. Per-chunk ore yields land in [100%, 140%] of vanilla Alpha empirical numbers — see `test_ore_density_matches_vanilla_alpha`.
- **Blocks:** stone-family + ores + crafting table (IDs 0–16). Hardness, harvest-level, preferred-tool-type, break-time math all vanilla Alpha.
- **Items & tools:** 11 non-block items (sticks, pickaxes/axes/shovels × wood/stone/iron/diamond, raw materials). Tool speed + tier gating on drops, durability tracked.
- **Crafting:** recipe registry (shaped + shapeless) loaded from `data/recipes.json` on boot. Live-updated craft result in `Inventory` (2×2 grid at slots 40–43). Crafting table block opens a 3×3 screen.
- **Inventory UI:** 45-slot model (9 hotbar + 27 main + 4 armor + 4 craft grid + 1 result). Screens: full inventory, crafting table, pause menu, hotbar. Pre-baked 3D isometric block icons via offscreen SubViewport (one-time cost at boot).
- **Held-item rendering:** `sprite_extruder.gd` voxelizes 2D item sprites into 3D meshes for first/third-person held tools (matches vanilla ItemModelGenerator). Proper handle-tip pivot for grip rotation.
- **Audio:** footstep cadence tied to horizontal movement (grass/cloth variants, 1.6-block interval).
- **Dev tools:** `tool_tuner.gd` (runtime FP/TP held-item pose sliders), `debug_stats.gd` (FPS / chunk load overlay), `MC_CLONE_RESOLUTION` env override.

Earlier phases: Phase 3 (infinite world with threaded chunk loading, shared-material atlas rendering, pluggable texture packs), Phase 4 (base inventory, hotbar, audio scaffolding, hold-to-break, dropped items, Steve player model).

Next: Phase 6 (day/night cycle, lighting propagation, mobs) per `implementationplan.md`.

## Layout

```
scripts/
  game.gd                     # autoload — warms BlockAtlas + Worldgen + Recipes on main thread
  input_actions.gd            # InputMap setup
  world/
    blocks.gd                 # block IDs, hardness, tool gating, drop table, face textures
    items.gd                  # item IDs (100+), tool data (speed / harvest_level / durability)
    chunk.gd                  # pure block-data container (PackedByteArray, 16×128×16)
    chunk_node.gd             # Node3D wrapper: builds mesh + trimesh collision
    chunk_manager.gd          # streams chunks around player via WorkerThreadPool
    mesher.gd                 # face-culled mesher → ArrayMesh arrays
    worldgen.gd               # heightmap + ore veins (vanilla ellipsoid) + oak trees
    block_atlas.gd            # packs per-block PNGs into one atlas, owns shared ShaderMaterial
    sprite_extruder.gd        # 2D item sprite → voxelized 3D mesh for held tools
  crafting/
    recipes.gd                # registry: loads data/recipes.json, matches shaped + shapeless
  player/                     # player.gd, interaction.gd, inventory.gd, item_stack.gd, character_model.gd
  ui/                         # hotbar_ui, inventory_screen, crafting_table_screen, pause_menu,
                              #  debug_stats, tool_tuner, item_icons, block_icon_renderer,
                              #  character_preview
  dev/                        # pre-commit.sh, install-hooks.sh
scenes/                       # chunk, chunk_manager, player, ui, entities
shaders/
  chunk.gdshader              # cull_back, per-face Notch shading, atlas sampling
  chunk_overlay.gdshader      # held-block variant (depth_test_disabled, draws on top)
  crack.gdshader              # block-break progress overlay
  held_item.gdshader          # first-person extruded tool material
  held_item_world.gdshader    # third-person extruded tool material
data/recipes.json             # 2×2 / 3×3 crafting recipes (shaped + shapeless)
tests/                        # GUT tests (test_*.gd)
assets/
  textures/blocks/packs/{pack}/   # active pack's PNGs (stone, dirt, grass_top, ores, crafting_table, …)
  textures/gui/                   # inventory, crafting_table, widgets, pause_menu, armor slot placeholders
  textures/items/                 # sticks, tools (extruded at runtime)
  audio/sfx/step/                 # footstep variants (grass, cloth)
  fonts/Minecraft.otf             # UI font
performance_plan.md           # measurement-first perf roadmap (instrumentation + milestones)
```

## Architecture invariants

**Classes vs autoloads.** Only `Game` (scripts/game.gd) is an autoload. `Blocks`, `Items`, `Chunk`, `Mesher`, `Worldgen`, `BlockAtlas`, `Recipes`, `SpriteExtruder`, `BlockIconRenderer` are `class_name` statics / `RefCounted` — call directly (`BlockAtlas.texture()`), no `get_node`.

**Threading contract.** `WorkerThreadPool` runs `_compute_chunk_data` (worldgen + meshing). The main thread owns: GPU mesh upload, scene-tree manipulation, `_pending` dict. `_ready_results` is the hand-off, guarded by `_result_mutex`. `Game._ready` warms `BlockAtlas.build()`, `Worldgen.surface_height(0,0)`, `Recipes.ensure_loaded()`, and `BlockIconRenderer.setup/render_all()` on the main thread so workers never hit lazy-init races — preserve this.

**Shared `ShaderMaterial`.** One material instance for all chunks, owned by `BlockAtlas._material`. Don't create per-chunk materials. If you need per-chunk shader parameters, push them into vertex attributes, not new materials.

**Chunk dims are fixed.** `SIZE_X=16`, `SIZE_Y=128`, `SIZE_Z=16`. Y-major indexing (`y * SIZE_X * SIZE_Z + z * SIZE_X + x`). Changing these breaks save format, mesher, tests.

**Block IDs are stable.** `scripts/world/blocks.gd` IDs are uint8 in the range 0–99; append new IDs to the end, never renumber — they're persisted in `Chunk.blocks` (`PackedByteArray`). Item IDs start at 100 (`scripts/world/items.gd`) to keep the two spaces disjoint; `Items.id_from_name()` resolves unified name → id for recipe JSON.

**Deterministic worldgen.** `Worldgen.generate_chunk(x, z)` is pure on `(WORLD_SEED, x, z)`. Don't introduce time/RNG dependencies — chunk reload must reproduce identical terrain. Ore veins use hash-derived pseudo-random floats (`_float01`) rather than `RandomNumberGenerator`, to keep the algorithm deterministic *and* chunk-isolated.

**Ore vein reconstruction.** Vanilla `WorldGenMinable` centers each vein at world `(i+8, j, k+8)`, so each chunk's pass writes into a 2×2 NE square. For deterministic chunk-isolated gen, `Worldgen._scatter_ores` runs 4 decoration passes (own + 3 SW neighbors) and clips writes to the target chunk's bounds — this covers every vein that should land in the chunk without any cross-chunk side effects. Don't collapse it back to a single-pass loop: you lose ~50% of ore that vanilla places via spillover.

**Mesher emits all 6 faces per block, with neighbor culling inside a chunk only.** Chunk boundaries emit outward faces unconditionally (known limitation — see `optimizations.md` §2). Don't "fix" this without also handling neighbor-load re-meshing.

**Face winding.** Reversed index order (`[base, base+2, base+1, base, base+3, base+2]`) so `cull_back` keeps the outward side. UVs V-flipped so textures aren't upside down. See `mesher.gd` comments.

## Commands

```sh
# Run
godot --path . main.tscn
MC_CLONE_TEXTURE_PACK=programmer_art godot --path . main.tscn

# Rebuild native extension (needed after any change under src/)
scons platform=macos target=template_debug -j8    # or linux / windows

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
- **Texture pack cell size auto-detects** from the first loaded PNG in `packs/{active}/`. All textures in a pack (stone, dirt, grass × top/side, cobble, log × top/side, planks, leaves, sand, the 4 ores, crafting_table × top/front/side) must be the same square size, or they're resized nearest-neighbor.
- **Env-var precedence** for pack selection: shell `MC_CLONE_TEXTURE_PACK` > `.env` file > `@export texture_pack` on Game autoload.
- **`MC_CLONE_RESOLUTION=WxH`** overrides the window size at boot (e.g. `MC_CLONE_RESOLUTION=2560x1440`). Useful on high-DPI displays where the default 1920×1080 looks tiny.
- **Recipe JSON is authoritative** for the crafting surface — edit `data/recipes.json`, not `recipes.gd`. Pattern strings preserve whitespace; `" S "` means "empty, stick, empty" in a 3-wide row. Names resolve through `Items.id_from_name()` (blocks + items unified).
- **Item IDs are stable too.** Like block IDs, items in `scripts/world/items.gd` are uint8 (100+); append, never renumber. They're referenced by recipe JSON and persisted in `ItemStack`.

## Don'ts

- Don't introduce per-chunk `ShaderMaterial` or `Shader.new()` calls.
- Don't call `load()` inside the worker thread — `ResourceLoader` is main-thread-safe only for some types. Warm resources in `Game._ready`.
- Don't mutate `Chunk.blocks` from a worker thread while the main thread may read it. Today, a chunk is owned by one thread at a time (worker during gen/mesh, main thereafter); preserve that.
- Don't add greedy meshing as a point fix — it breaks `test_mesher` assertions and the per-block edge-outline shader. Plan it alongside Phase 4+ shader work.
- Don't auto-commit. Wait for an explicit "commit" from the user.
