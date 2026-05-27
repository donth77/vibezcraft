# CLAUDE.md

## Project

A from-scratch clone of MC Alpha in **Godot 4, GDScript, and C++**. Alpha-core mechanics with some modern QoL. Targeting v1.2.6's full feature set with exceptions — **multiplayer / SMP** are both out of scope. Purpose-built binary save format (not Anvil-compatible).

Gameplay and scene-graph logic is GDScript. Six performance-critical paths are native C++ via GDExtension (all in one `libmesher_native.*` dylib):
- `MesherNative.mesh_chunk_data` (`src/mesher_native.cpp`) — chunk meshing + collision face soup.
- `WorldgenNative.build_base_terrain` (`src/worldgen_native.cpp`) — heightmap + stratified layer fill (ores + trees stay in GDScript).
- `LightingNative` (`src/lighting_native.cpp`) — sky-light + block-light BFS propagation.
- `WaterFXNative` (`src/water_fx_native.cpp`) — water surface mesh + animation.
- `PathfinderNative` (`src/pathfinder_native.cpp`) — A* over the voxel grid for mob AI (~10× faster than GDScript reference).
- `VoxelColliderNative` (`src/voxel_collider_native.cpp`) — AABB-vs-voxel sweep collision for mob movement (replaces `move_and_slide` for the mob loop).

All six have pure-GDScript reference implementations that the native ports must match byte-for-byte; parity is enforced by per-native test files (`tests/test_mesher_native.gd`, `tests/test_worldgen_native.gd`, etc.). When the native library isn't built, the game falls through to GDScript — there's no hard dependency on the extension loading.

Canonical planning docs:
- `.claude/PLANNING.md` — vision, stack rationale, Alpha mechanics reference
- `.claude/implementationplan.md` — phase-by-phase execution plan (read this before starting work on a new phase)
- `.claude/alpha-mechanics.md` — reference for Alpha-faithful numbers (break times, heights, etc.)
- `.claude/optimizations.md` — catalog of higher-risk perf improvements deliberately deferred

## Current state

**Phases 1-7 shipped.** Mob lineup, dungeons, ranged combat, beds, jukeboxes, farming, fishing, minecarts, mob-vs-mob physics — all in. Active work is perf polish (mob LOD + voxel collider C++ ports landed) and audit passes against vanilla.

- **Worldgen:** 2D Perlin heightmap, stratified bedrock/stone/dirt/grass, oak trees, caves (`worldgen_caves.gd`), ore veins (coal/iron/gold/diamond). Each chunk runs 4 decoration passes (own + 3 SW neighbors) to recover vanilla's +8,+8 spillover without cross-chunk writes. Per-chunk ore yields land in [100%, 140%] of vanilla Alpha empirical numbers.
- **Dungeons:** `worldgen_dungeons.gd`. 8 attempts/chunk in Y [8, 90], variable room size (half-extents 2-3 in X/Z), 1-5 wall openings, always-2 chest loot attempts, mob spawner cage in center. Spawner pool matches vanilla `{Skeleton, Zombie, Zombie, Spider}`.
- **Blocks:** 88 block types. Full Alpha set + slabs, beds, bookshelves, jukeboxes, signs, fences/gates, rails, mob spawners, mossy cobble, wool (16 colors), iron/gold/diamond/sponge/clay blocks, slime block, plus modern-QoL deviations called out per-block in `blocks.gd`. Hardness, harvest-level, preferred-tool-type, break-time math all vanilla Alpha.
- **Items & tools:** 80+ items. Full tool tiers (pickaxe/axe/shovel/sword/hoe × wood/stone/iron/diamond/gold), armor (leather/iron/gold/diamond), bow + arrows (charge mechanic + critical bonus), buckets, flint & steel, shears, fishing rod, food (apple/bread/porkchop/fish/golden apple/mushroom stew), raw materials (coal, ingots, charcoal, flint, leather, gunpowder, redstone, bone, slimeball, snowball, feather, string, sugar, paper, book), 8 music discs, minecart family. Tool speed + tier gating on drops, durability tracked.
- **Crafting:** recipe registry (shaped + shapeless) loaded from `data/recipes.json` on boot. Live-updated craft result in `Inventory` (2×2 grid at slots 40–43). Crafting table block opens a 3×3 screen.
- **Smelting:** furnace with fuel/input/output slots (`furnace_manager.gd`), burn-time tracking, vanilla smelt times, lit/unlit block state.
- **Mobs:** 9 species (`mob_base.gd` shared). **Passive:** pig (`pig.gd`), cow (`cow.gd`, right-click milk), chicken (`chicken.gd`, lays eggs), sheep (`sheep.gd`, Beta-style shearing). **Hostile:** zombie (`zombie.gd`, 3-dmg melee + daylight burn), skeleton (`skeleton.gd`, bow charge + arrow projectile + kite at 4-10 m), spider (`spider.gd`, light-gated hostile + pounce), creeper (`creeper.gd`, 3 m fuse ignite → 1.5 s charge → power-3 explosion + flash anim + music disc drop on skeleton-arrow kill), slime (`slime.gd`, size 1/2/4, hop physics, splits on death, gated to slime-chunks below Y=40). All mobs share `mob_base.gd` for gravity, knockback, death tilt, hurt flash, drowning, fire damage, stuck-arrow visuals, 4-tier LOD (NEAR/MID/FAR/GATED), distance gate at 48 m for skipped physics, and vanilla idle-SFX roll (`roll_idle_sfx_tick` mirrors `hf.B()` per-tick `nextInt(1000) < a++` with -80 cooldown).
- **Mob movement:** `voxel_collider.gd` (+ native C++ port) — AABB-vs-voxel sweep collision REPLACES `move_and_slide` for mob bodies. Mobs no longer use Godot's physics server for terrain collision (still used for ray queries / arrow hits). Mob-vs-mob soft push (`_apply_mob_separation`) handles entity-vs-entity overlap.
- **AI pathfinding:** `pathfinder.gd` (+ native C++ port) — A* over the voxel grid, 8-way XZ moves with ±1 Y step, Euclidean heuristic, diagonal + vertical cost premium. Hot path for hostile mob chase. Shared `MobBase.pick_wander_target` for hostile-mob wander (3-6 m random target, 4 s cooldown).
- **Natural spawn:** `natural_mob_spawner.gd` — per-tick random-cell sample around player. Hostile pool `{zombie, skeleton, spider, creeper}` gated by night + light ≤ 7 + 24-128 m XZ band. Slime separate path (slime-chunk + Y ≤ 40, no light gate, no night gate). 70-mob hostile cap. `passive_spawner.gd` handles pig/cow/sheep/chicken.
- **Combat:** melee (player + zombie/spider), ranged (player bow + skeleton arrows). Arrow.gd handles physics + raycast hit + stuck visuals. Critical-hit on full-charge player shots. Player damage attribution stored on `MobBase._last_attacker` (used by creeper for music disc drop credit). Knockback impulse, armor damage reduction, fall damage, drowning, fire/lava, health regen, death screen + respawn.
- **Inventory UI:** 45-slot model (9 hotbar + 27 main + 4 armor + 4 craft grid + 1 result). Screens: full inventory, crafting table, furnace, chest, pause menu, hotbar. Pre-baked 3D isometric block icons via offscreen SubViewport (one-time cost at boot via `block_icon_renderer.gd`).
- **Day/night cycle:** `world_time.gd` autoload — vanilla 20-minute day (24000-tick cycle), sky color gradient, sun direction + energy, sky factor for light scaling.
- **Lighting:** BFS flood-fill sky light + block light propagation (`lighting.gd` + native), per-face brightness LUT in `chunk.gdshader`. Torches emit level 14, furnaces 13.
- **Fluids:** finite water/lava flow propagation (`block_fluids.gd`), water/lava shaders with UV animation, swim mechanics, bucket place/pickup.
- **Beds:** Beta 1.3 sleep mechanic (`bed_storage.gd`, `sleep_overlay.gd`). Multi-cell foot/head place + break cascade. Right-click at night → fast-forward to dawn + set spawn point.
- **Jukeboxes + 8 music discs:** Beta 1.4 mechanic. Right-click jukebox with disc → insert + start playback. Ambient music auto-pauses; resumes when disc ejects.
- **Farming:** wheat crops (`crops.gd`), hoe tilling (`farmland.gd`), tall grass seed drops. Bonemeal accelerates growth.
- **Fishing:** cast/reel mechanic via `fishing_bobber.gd`, raw + cooked fish drops (smelt raw_fish for cooked).
- **Minecarts + rails:** straight + curve rails, boost rails, 3 cart variants (passenger, chest, furnace). Furnace cart self-propels with coal fuel. Chained ramps work.
- **Storage:** per-block chest, furnace, jukebox inventories. Dedicated UI screens (`chest_screen.gd`, `furnace_screen.gd`, `jukebox_screen.gd`).
- **Held-item rendering:** `sprite_extruder.gd` voxelizes 2D item sprites into 3D meshes for FP/TP held tools (matches vanilla ItemModelGenerator). Proper handle-tip pivot for grip rotation.
- **Audio:** footstep cadence tied to horizontal movement (grass/cloth/stone/sand/gravel/slime variants), block break/place SFX by material, per-mob idle/hurt/death/step pools (zombie, skeleton, spider, creeper, slime, pig, cow, chicken, sheep), ambient sounds (`ambient_fx.gd`), music player (`music_player.gd`).
- **World save/load:** purpose-built binary format under `user://World{N}/` — region files (16×16 chunk packing, sector-aligned), `player.bin`, `entities.bin`, `world.json`. Crash-safe via `.new`/`.old` recovery in `save_load.gd`. Autosave every 5 minutes; explicit save on Pause → Save and quit. Multi-world select screen + create-new-world flow. Out-of-world Y on player.bin clamps to spawn altitude on load.
- **Creative mode:** independent of debug — toggled via `toggle_creative` (default G/F1). Enables flight (double-jump), removes fall damage, instant block break, unlocks item / mob spawner UIs. Top-right HUD shows `CREATIVE` / `DEBUG` / `DEBUG | CREATIVE` per mode combo.
- **Rebindable controls:** every gameplay action is reachable from Main Menu → Settings → Controls or in-game Pause → Options → Controls. Persists to `user://settings.cfg`. Vanilla-style conflict resolution (new bind silently clears displaced action).
- **Dev tools:** `tool_tuner.gd` (FP/TP pose sliders), `debug_stats.gd` (FPS / chunk load / LOD tier / native-status overlay), `debug_item_spawner.gd` + `debug_mob_spawner.gd` (creative-or-debug-gated grids), `MC_CLONE_RESOLUTION` env override.

## Layout

```
scripts/
  game.gd                     # autoload — warms BlockAtlas + Worldgen + Recipes + natives on main thread
  input_actions.gd            # InputMap setup
  world/
    blocks.gd                 # block IDs (0–99), hardness, tool gating, drop table, face textures
    items.gd                  # item IDs (100+), tool data (speed / harvest_level / durability)
    chunk.gd                  # pure block-data container (PackedByteArray, 16×128×16)
    chunk_node.gd             # Node3D wrapper: builds mesh + deferred trimesh collision
    chunk_manager.gd          # streams chunks around player via WorkerThreadPool
    mesher.gd                 # face-culled mesher → ArrayMesh arrays (GDScript reference)
    worldgen.gd               # heightmap + ore veins + oak trees (GDScript reference)
    worldgen_caves.gd         # cave carving pass
    worldgen_dungeons.gd      # rooms, spawners, chest loot
    block_atlas.gd            # packs per-block PNGs into one atlas, owns shared ShaderMaterial
    block_mesh.gd             # non-cube mesh builders (torch, fence, stair, door, ladder, bed, rail)
    block_fluids.gd           # water/lava finite flow propagation
    block_fire.gd             # fire spread + extinction logic
    block_fx.gd               # block break/place particle effects
    fluid_fx.gd               # water/lava visual effects
    water_fx.gd               # water surface rendering (GDScript reference)
    explosion.gd              # ray-cast blast + entity damage + chain TNT
    explosion_fx.gd           # explosion smoke + flash particles
    primed_tnt.gd             # PrimedTNT entity with fuse + chain detonation
    ambient_fx.gd             # ambient environmental effects
    sprite_extruder.gd        # 2D item sprite → voxelized 3D mesh for held tools
    world_time.gd             # day/night cycle (24000-tick day, sky factor, sun direction)
    day_night_driver.gd       # applies WorldTime to scene lighting + environment
    lighting.gd               # BFS sky light + block light flood fill (GDScript reference)
    chest_storage.gd          # per-block chest inventory persistence
    furnace_manager.gd        # furnace smelting logic (fuel, burn time, output)
    jukebox_storage.gd        # per-block jukebox state (loaded disc id + playback)
    bed_storage.gd            # per-block bed pairing (foot ↔ head) + spawn-point set
    sign_storage.gd           # per-block sign text
    mob_spawner_manager.gd    # dungeon mob spawner tick + cooldown + 6-mob cap
    natural_mob_spawner.gd    # per-tick random-cell hostile + slime spawn pass
    passive_spawner.gd        # passive pig/cow/sheep/chicken spawn pass
    falling_block.gd          # sand/gravel gravity cascade
    dropped_item.gd           # item pickup entity
    fishing_bobber.gd         # fishing rod cast/reel projectile
    leaf_decay.gd             # leaf block decay when disconnected from logs
    tick_scheduler.gd         # deferred block tick scheduling
    sky_dome.gd               # sky background rendering
    java_random.gd            # Java LCG port for vanilla-parity RNG
  crafting/
    recipes.gd                # registry: loads data/recipes.json, matches shaped + shapeless
  player/                     # player.gd, interaction.gd, inventory.gd, item_stack.gd, character_model.gd
  entities/
    mob_base.gd               # shared mob superclass — gravity, knockback, death, hurt flash,
                              #  LOD tiering, voxel-collider movement, mob-vs-mob soft push,
                              #  idle SFX roll, drowning, fire damage, stuck arrows, despawn timer
    pig.gd cow.gd chicken.gd sheep.gd  # passive mobs
    zombie.gd skeleton.gd spider.gd creeper.gd slime.gd  # hostile mobs
    mob_registry.gd           # name → script path map (used by spawner UIs + save/load)
    mob_cube.gd               # Cube unfold for mob model UV layout
    pathfinder.gd             # A* over voxel grid (GDScript reference; dispatches to native)
    voxel_collider.gd         # AABB sweep collision against voxel cells (GDScript reference)
    arrow.gd                  # gravity, drag, raycast hit, stuck embed
    snowball.gd               # throwable projectile
    chest_node.gd             # chest block Node3D + open/close animation
    primed_tnt.gd             # see scripts/world/primed_tnt.gd above (some entities cross-listed)
    boat.gd minecart.gd       # rideable entities
    painting.gd               # wall-mounted decoration
  audio/
    sfx.gd                    # block/tool/step SFX + per-mob species pools + creeper fuse
    music_player.gd           # ambient music with random gaps; pauses for disc playback
  persistence/
    save_load.gd              # region-file I/O, crash-safe .new/.old recovery, world-dir layout
    player_save.gd            # player.bin: pos + head rotation + health + 45-slot inventory + fire state
    entity_save.gd            # entities.bin: dropped items + mobs + tile-entities + signs + paintings
    world_meta.gd             # world.json: seed, spawn, last_played, play_time_seconds
  ui/                         # hotbar_ui, inventory_screen, crafting_table_screen, furnace_screen,
                              #  chest_screen, jukebox_screen, sleep_overlay, pause_menu, death_screen,
                              #  main_menu, settings_menu, in_game_options, controls_menu,
                              #  select_world_screen, create_world_screen, debug_stats, tool_tuner,
                              #  debug_item_spawner, debug_mob_spawner, item_icons,
                              #  block_icon_renderer, character_preview, hp_bar, air_bar,
                              #  damage_overlay, water_overlay, fire_overlay, durability_bar,
                              #  loading_screen, vanilla_button, minecraft_font
  dev/                        # pre-commit.sh, install-hooks.sh, extract_alpha_pack.py
scenes/                       # chunk, chunk_manager, player, ui, entities
shaders/
  chunk.gdshader              # cull_back, per-face Notch shading, atlas sampling, brightness LUT
  chunk_overlay.gdshader      # held-block variant (depth_test_disabled, draws on top)
  crack.gdshader              # block-break progress overlay
  crosshair.gdshader          # vanilla framebuffer-inversion crosshair
  held_item.gdshader          # first-person extruded tool material
  held_item_world.gdshader    # third-person extruded tool material
  water.gdshader              # animated water surface
  lava.gdshader               # animated lava surface
data/recipes.json             # 2×2 / 3×3 crafting recipes (shaped + shapeless)
tests/                        # GUT tests (test_*.gd) — including per-native parity tests
src/
  mesher_native.cpp/.h        # C++ chunk mesher (GDExtension)
  worldgen_native.cpp/.h      # C++ worldgen base terrain
  lighting_native.cpp/.h      # C++ light propagation BFS
  water_fx_native.cpp/.h      # C++ water surface mesh
  pathfinder_native.cpp/.h    # C++ A* over voxel grid for mob AI
  voxel_collider_native.cpp/.h # C++ AABB-vs-voxel sweep for mob movement
  register_types.cpp          # GDExtension class registration
assets/
  textures/packs/{pack}/          # active pack's PNGs (atlas slots + items/ + mobs/ + armor/ subdirs)
  textures/gui/                   # inventory, crafting_table, furnace, chest, widgets, logo
  textures/items/                 # default items (extruded at runtime)
  textures/mob/                   # mob species sheets (pig, cow, zombie, skeleton, …)
  textures/entities/              # bobber, paintings, etc.
  textures/particles/             # smoke, flame, water drop, etc.
  audio/sfx/                      # step, dig, place, liquid, fire, door, chest variants
  audio/sfx/mob/{species}/        # per-mob say/hurt/death/step pools
  audio/music/                    # ambient background tracks
  fonts/Minecraft.otf             # UI font
  icon/                           # window + dock icon (replaces icon.svg)
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

**Mob movement uses VoxelCollider, not move_and_slide.** Mob bodies extend `CharacterBody3D` but their `_physics_process` calls `VoxelCollider.sweep(self, velocity, delta)` instead of `move_and_slide()`. The voxel collider checks block-cell AABB overlap directly, dispatching to `VoxelColliderNative` when the extension is loaded. `move_and_slide` is still used by the player + non-mob entities (carts, boats, arrows, etc.).

**Mob LOD tiering.** `MobBase` defines 4 distance bands keyed off `_lod_tier`: `LOD_NEAR` (<24 m, full physics + AI), `LOD_MID` (24-48 m, AI ticks but no soft-push), `LOD_FAR` (48-128 m, frozen physics + AI), `LOD_GATED` (>128 m, despawn timer counting). The 48 m gate fires from `_physics_process` and short-circuits the AI tick + soft-push pass. Per-subclass `_ai_tick` callers DO check `_lod_gated` after `super._physics_process()` to skip their species AI work; preserve this.

**Idle SFX cadence.** Centralized in `MobBase.roll_idle_sfx_tick()` — vanilla `hf.B()` per-tick `nextInt(1000) < a++` with `-80` cooldown after a fire. Every species calls it from `_ai_tick`, NOT from `_process` (variable framerate would over-fire on high-fps hosts). Don't reintroduce a per-frame accumulator; the 20 Hz AI tick is the right cadence.

**Mob-vs-mob soft push.** `MobBase._apply_mob_separation` runs from `_physics_process` for NEAR/MID mobs. Symmetric per-pair impulse, vanilla `MOB_PUSH_STRENGTH = 0.05`. Without this, mobs would clip clean through each other since `VoxelCollider` only checks block cells. Skipped for FAR mobs (clipping invisible at distance) — preserves the early-out savings.

**Native extensions registered together.** All 6 native classes live in one `libmesher_native.*` library and register from `src/register_types.cpp::initialize_mesher_native_module`. Adding a new native: add the new `.cpp/.h` pair, `GDREGISTER_CLASS` it, expose `enable_native()` on its GDScript reference, and call it from `Game._ready()`.

**`_last_attacker` for damage attribution.** `MobBase.take_damage(amount, knockback_dir, knockback_strength, attacker)` latches the optional attacker Node onto `_last_attacker`. Arrow.gd passes `_shooter` so creeper kills can credit skeletons (vanilla `dq.b(lw)` music disc drop). Always validate with `is_instance_valid(_last_attacker)` before any `is X` check — the attacker may have died and queue_free'd since.

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

Read `.claude/optimizations.md` first — the high-leverage wins are already documented there with regression notes. Don't repeat the audit. Confirm whether an item moved from "deferred" to "wanted now" before implementing, since several break existing tests or shipped visual features (per-block edge outlines, exact vertex counts in test_mesher).

## Gotchas

- **`Chunk.get_block` returns `AIR` for OOB.** Mesher relies on this for the "emit face at world edge" behavior; don't change it to panic.
- **`max_y` is monotonic.** Breaking the topmost block doesn't decrease it. Acceptable cost: 1 extra layer of meshing iteration.
- **`create_trimesh_shape()` is main-thread and ~10–100 ms.** Rare today (player edits only); becomes a spike once dynamic blocks land — see `optimizations.md` §4.
- **Texture pack cell size auto-detects** from the first loaded PNG in `packs/{active}/`. All textures in a pack (stone, dirt, grass × top/side, cobble, log × top/side, planks, leaves, sand, the 4 ores, crafting_table × top/front/side) must be the same square size, or they're resized nearest-neighbor.
- **Env-var precedence** for pack selection: shell `MC_CLONE_TEXTURE_PACK` > `.env` file > `@export texture_pack` on Game autoload.
- **`MC_CLONE_RESOLUTION=WxH`** overrides the window size at boot (e.g. `MC_CLONE_RESOLUTION=2560x1440`). Useful on high-DPI displays where the default 1920×1080 looks tiny.
- **Recipe JSON is authoritative** for the crafting surface — edit `data/recipes.json`, not `recipes.gd`. Pattern strings preserve whitespace; `" S "` means "empty, stick, empty" in a 3-wide row. Names resolve through `Items.id_from_name()` (blocks + items unified).
- **Item IDs are stable too.** Like block IDs, items in `scripts/world/items.gd` are uint8 (100+); append, never renumber. They're referenced by recipe JSON and persisted in `ItemStack`.
- **InputMap action IDs are persisted.** Once a user has saved a rebind, the action string (`"move_forward"`, `"open_item_spawner"`, etc.) lives in their `settings.cfg [controls]` section. Renaming an action ID orphans the saved override and the user falls back to the default binding silently. Add new actions freely; renaming requires a migration in `InputActions.apply_saved_overrides`.
- **Mob front face is on local -Z (Godot convention).** `MobCube.build_textured_cube` puts the textured "front" UV on the +Z face, but mob locomotion rotates `rotation.y = atan2(-x, -z)` to face the target — which makes local -Z the forward direction. For mobs with face features (slime eyes, creeper face), put them on the -Z side, NOT +Z. The body cube's UV layout is symmetric enough on most species that this only matters for face details.
- **Godot 4 `node.basis = Basis(...)` wipes scale.** Setting `basis` directly replaces the entire transform including any prior `node.scale = ...`. When you need a non-identity basis WITH non-unit scale (e.g. an extruded sprite rotated into a specific pose), bake the scale into the basis column lengths instead of relying on a separate `scale` property assignment. See `skeleton._build_bow` for the canonical pattern.
- **`_last_attacker` may be a freed instance.** If a skeleton hits a creeper, then dies, then the creeper detonates — `_last_attacker` points at a freed Object. `is X` crashes on dangling refs. Always guard with `is_instance_valid(_last_attacker)` before checking the type.
- **Mob model UV (32, 0) overlay region is often empty.** Vanilla declare a "head overlay" cube at UV (32, 0) for armor/hat layers — but most species' texture sheets have ZERO pixels in that region (alpha=0). Without `TRANSPARENCY_ALPHA_SCISSOR` on the material, those cubes render as solid black. Either enable alpha-test on the overlay material OR skip building the overlay entirely (vanilla effectively renders nothing there).

## Don'ts

- Don't introduce per-chunk `ShaderMaterial` or `Shader.new()` calls.
- Don't call `load()` inside the worker thread — `ResourceLoader` is main-thread-safe only for some types. Warm resources in `Game._ready`.
- Don't mutate `Chunk.blocks` from a worker thread while the main thread may read it. Today, a chunk is owned by one thread at a time (worker during gen/mesh, main thereafter); preserve that.
- Don't add greedy meshing as a point fix — it breaks `test_mesher` assertions and the per-block edge-outline shader. Plan it alongside Phase 4+ shader work.
- Don't auto-commit. Wait for an explicit "commit" from the user.
