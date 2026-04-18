# Implementation Plan

A step-by-step execution guide for building the Minecraft Alpha clone in **Godot 4 + GDScript**. This is the companion to `PLANNING.md` (which covers vision, stack rationale, and Alpha mechanics reference). PLANNING.md answers *what* and *why*. This doc answers *how*, *in what order*, and *how do we know it's done*.

> **Working agreement:** Each phase ends in a green test suite, a working build, and a git commit. Don't start the next phase until the previous is demoable.

---

## 0. Locked-In Decisions

From PLANNING.md §6, with user-confirmed answers:

| # | Question | Decision |
|---|---|---|
| 1 | Faithfulness vs. QoL | **Strict Alpha core + tasteful modern QoL** — see §11 for the curated list |
| 2 | Art assets | **AI-generated**, swap to better quality over time — see §10 for tool recommendations |
| 3 | Music | **Skip for MVP** — silent game initially |
| 4 | Public release | **Skip for MVP** — private repo, no distribution concerns |
| 5 | The Nether | **Skip for MVP** — Overworld only |
| 6 | Save format | **Purpose-built binary** — no Anvil compatibility |

---

## 1. Phase Map (at-a-glance)

| Phase | Name | Est. | Demoable when |
|---|---|---|---|
| 0 | Scaffold | ½ day | Spinning textured cube + green tests |
| 1 | Player movement | 1 day | First-person walk on a hand-built platform |
| 2 | Mine & place | 1 day | Dig a tunnel, build a wall |
| 3 | Infinite world | 3–4 days | Procedural terrain + caves at 4+ chunk render distance |
| 4 | Inventory & hotbar | 2 days | Block drops, hotbar swap, drag-drop inventory |
| 5 | Crafting & tools | 2 days | Wood → planks → wooden pickaxe → mine stone → smelt iron |
| 6 | Day/night & mobs | 3 days | Sun/moon, light propagation, hostile mobs at night |
| 7 | Persistence & polish | 2 days | Quit and resume; settings persist; F3 overlay |

**Total MVP:** ~14–16 working days.

---

## 2. Phase 0 — Project Scaffold

### 2.1 One-time environment setup
**You install (once on your machine):**
- **Godot 4.x** (latest stable, ≥ 4.3) — https://godotengine.org/download
- **gdtoolkit** for `gdformat` + `gdlint`: `pip install gdtoolkit`
- **Git** with **Git LFS**: `brew install git git-lfs && git lfs install`

### 2.2 Repo bootstrap
**Files I'll create:**
```
.gitignore                   # Godot template (.godot/, *.import, exports/)
.gitattributes               # LFS patterns: *.png, *.ogg, *.wav, *.glb
.editorconfig                # tabs for .gd, LF endings
README.md                    # links to PLANNING.md + this file
project.godot                # Godot project config (Vulkan Forward+, 1280x720, physics 60Hz)
icon.svg                     # placeholder app icon
main.tscn                    # root scene
scripts/game.gd              # autoload — empty skeleton
scripts/dev/cube_spinner.gd  # temp; deleted in Phase 1
assets/textures/_test_grass.png  # 16x16 placeholder texture
addons/gut/                  # GUT testing framework
tests/test_smoke.gd          # one passing test
scripts/.gdlintrc            # lint config
```

### 2.3 Pre-commit hook
- Runs `gdformat --check scripts/ tests/` (fails on unformatted files)
- Runs `gdlint scripts/ tests/`
- Runs `godot --headless --check-only` (catches parse errors)

### 2.4 Acceptance criteria
- [ ] `godot --headless --check-only` exits 0
- [ ] `godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=tests/` runs and passes 1 test
- [ ] Press F5 in editor → textured cube visible, spinning
- [ ] `git commit` succeeds (hooks pass)

### 2.5 Commit
`feat: phase 0 — Godot 4 project scaffold with GUT and lint hooks`

---

## 3. Phase 1 — Player Movement & Collision

### 3.1 What we build
A `CharacterBody3D` first-person controller standing on a hand-built 16×16×16 platform of placeholder blocks. Godot's built-in physics handles collision; no custom AABB yet.

### 3.2 Files
```
scenes/player/player.tscn       # CharacterBody3D + Camera3D + CapsuleCollider
scripts/player/player.gd        # WASD, mouse-look, jump, gravity, sneak
scenes/world/test_platform.tscn # 16x16x16 hand-built platform of MeshInstance3D cubes
scripts/dev/build_test_platform.gd  # programmatically populates the test platform
```
**Delete:** `scripts/dev/cube_spinner.gd` (no longer needed).

### 3.3 Input map (Project Settings → Input Map)
| Action | Default binding |
|---|---|
| `move_forward` | W |
| `move_back` | S |
| `move_left` | A |
| `move_right` | D |
| `jump` | Space |
| `sneak` | Shift (toggle in §11 QoL) |
| `interact_break` | Mouse Left |
| `interact_place` | Mouse Right |
| `inventory` | E |
| `pause` | Escape |
| `debug_overlay` | F3 |
| `hotbar_1` … `hotbar_9` | 1 … 9 |

### 3.4 Player physics constants (start values, expose as `@export`)
- Walk speed: 4.317 m/s (Minecraft canonical)
- Sprint speed: 5.612 m/s
- Sneak speed: 1.295 m/s
- Jump velocity: 8.0 m/s (gives ~1.25 block jump height)
- Gravity: -32.0 m/s² (2x Earth, matches MC feel)
- Mouse sensitivity: 0.002 rad/px (configurable in §11)

### 3.5 Tests (GUT)
- Player applies gravity when airborne
- Player stops at velocity 0 when grounded and no input
- Mouse-look stays clamped to ±90° pitch

### 3.6 Acceptance criteria
- [ ] Spawn on platform, move smoothly with WASD
- [ ] Mouse-look feels natural, no gimbal flip
- [ ] Jump lands cleanly, can't fall through floor
- [ ] Sneak halves move speed; releasing returns to walk
- [ ] Can walk off the platform edge and fall

### 3.7 Commit
`feat: phase 1 — first-person controller on test platform`

---

## 4. Phase 2 — Mine & Place

### 4.1 What we build
Replace the per-block `MeshInstance3D` test platform with a single chunk backed by `PackedByteArray` and rendered via `ArrayMesh`. Add raycast-based block break/place.

### 4.2 Files
```
scripts/world/blocks.gd          # block registry: id → name, texture rect, hardness, drops
scripts/world/chunk.gd           # PackedByteArray data + dirty flag + neighbor refs
scripts/world/mesher.gd          # face-culled naive meshing → ArrayMesh
scenes/world/chunk.tscn          # MeshInstance3D + StaticBody3D for collision
scripts/player/interaction.gd    # raycast → identify block face → break/place
scenes/ui/crosshair.tscn         # simple Control with a + sprite
shaders/chunk.gdshader           # samples atlas by UV, AO placeholder
```
**Delete:** `scenes/world/test_platform.tscn`, `scripts/dev/build_test_platform.gd`.

### 4.3 Block registry — Phase 2 minimum set
Just enough to make the world feel alive: `air`, `bedrock`, `stone`, `dirt`, `grass`, `cobblestone`, `wood_log`, `planks`, `leaves`, `sand`. (Full Alpha block set lands in Phase 4–5.)

### 4.4 Mesher algorithm (Phase 2: naive face-cull)
For each block in chunk:
- For each of 6 faces:
  - If neighbor block is opaque, skip face
  - Else emit 4 verts + 6 indices into the surface arrays
- After loop: `ArrayMesh.add_surface_from_arrays(PRIMITIVE_TRIANGLES, ...)` and update collision

**Defer to later:** greedy meshing (Phase 3 if needed for perf), ambient occlusion (Phase 6 with lighting).

### 4.5 Tests (GUT)
- `blocks.gd`: lookup by id returns expected metadata
- `chunk.gd`: setting/getting blocks at extreme coords (0,0,0), (15,127,15) works
- `chunk.gd`: setting a block flips `dirty = true`
- `mesher.gd`: a single-block chunk produces 6 faces × 4 verts = 24 verts
- `mesher.gd`: a 2×2×2 cube of blocks produces only outer faces (24 faces, not 48)

### 4.6 Acceptance criteria
- [ ] Spawn on a hand-populated single chunk of stone+grass+dirt
- [ ] LMB on a block → block disappears (instant break for now), mesh + collision regenerate within 1 frame
- [ ] RMB → places the currently-selected block in the empty space
- [ ] Crosshair visible and centered
- [ ] Cannot place a block inside the player

### 4.7 Commit
`feat: phase 2 — chunk meshing and block break/place`

---

## 5. Phase 3 — Infinite World

### 5.1 What we build
A `ChunkManager` that loads/unloads chunks around the player using procedural generation in `WorkerThreadPool`. 2D Perlin heightmap, vertical layering, simple ore distribution, 3D-noise caves.

### 5.2 Files
```
scripts/world/chunk_manager.gd       # load/unload around player, LRU eviction
scripts/world/worldgen.gd            # heightmap + caves + ore pass (runs in worker)
scripts/world/worldgen_params.gd     # Resource: seed, frequencies, octaves — @export'd for tuning
scripts/world/biomes.gd              # simple 2-biome stub (plains/forest) — placeholder for Phase 6
```

### 5.3 Worldgen pipeline (per chunk, in a worker)
1. **Heightmap** — `FastNoiseLite`, 2D Perlin, 4 octaves, freq 0.005 → height ∈ [40, 90]
2. **Vertical fill** — bedrock at y=0–4, stone up to height−4, dirt height−4 to height−1, grass at height (or sand if biome=beach)
3. **Caves** — 3D Perlin density; if `noise(x,y,z) > 0.55` and y < height−2, set air
4. **Ore pass** — coal (y < 80, rare), iron (y < 64, rarer), gold (y < 32, very rare), diamond (y < 16, ultra rare)
5. Return `PackedByteArray` to main thread, which constructs mesh in `mesher.gd`

### 5.4 Chunk lifecycle
- **Load:** `worldgen → mesher → ArrayMesh + StaticBody3D` (across multiple frames; max 2 chunks/frame to avoid stalls)
- **Active:** receives edits from player, re-meshes on dirty
- **Unload:** chunks beyond `render_distance + 2` despawned and serialized to `user://world/region/{x}_{z}.bin` (Phase 7 wires in real persistence; for now, evict + regenerate)

### 5.5 Performance budgets (target: 60 FPS at render_distance=4 = 81 chunks)
- Worldgen per chunk: < 10 ms
- Mesh build per chunk: < 5 ms
- Per-frame: ≤ 16.6 ms total

### 5.6 Tests (GUT)
- Worldgen with the same seed produces identical chunks
- Heightmap is continuous across chunk borders
- Ore density falls within expected ranges across a 100-chunk sample

### 5.7 Acceptance criteria
- [ ] Walk in any direction → terrain generates ahead, despawns behind
- [ ] No frame drops at render_distance=4 on dev machine
- [ ] Caves visible underground when you dig in
- [ ] Ores visible when caves expose them
- [ ] F3 overlay (added in §11) shows chunk coords + load count

### 5.8 Commit
`feat: phase 3 — infinite procedural world with chunked worldgen`

---

## 6. Phase 4 — Inventory & Hotbar

### 6.1 What we build
40-slot inventory (4 armor + 27 storage + 9 hotbar) with hotbar UI, inventory screen with 2×2 craft grid, block drops as physics items, drag-drop slot management.

### 6.2 Files
```
scripts/player/inventory.gd          # 40-slot data model, stack rules
scripts/player/item_stack.gd         # Resource: item_id, count
scripts/player/items.gd              # item registry (extends blocks.gd: tools, food slots later)
scenes/ui/hotbar.tscn                # 9 slot Controls + selection highlight
scripts/ui/hotbar.gd                 # 1–9 keys, scroll wheel, syncs to inventory
scenes/ui/inventory_screen.tscn      # Full inventory panel, modal overlay
scripts/ui/inventory_screen.gd       # drag-drop, split (right-click), stack merge
scenes/ui/slot.tscn                  # reusable slot Control
scenes/world/dropped_item.tscn       # RigidBody3D with floating block mesh
scripts/world/dropped_item.gd        # despawn after 5 min, magnet to nearby player
```

### 6.3 Stack rules
- Max stack: 64 (1 for tools, armor)
- Right-click in inventory: split stack in half
- Shift-click: move stack between hotbar/storage instantly
- Drag with held stack: drop one per slot per pixel-pass

### 6.4 Tests (GUT)
- Adding 64 dirt to empty inventory fills exactly 1 slot
- Adding 65 dirt fills 1 full slot + 1 with 1 item
- Picking up tool stacks them as count=1 each (no merging)
- Splitting a stack of 7 → 3 + 4

### 6.5 Acceptance criteria
- [ ] Break dirt → dropped item appears, walks toward you within 1.5m, picked up
- [ ] Hotbar shows the stack icon + count
- [ ] Press 1–9 → selection highlight moves; selected item is what gets placed/used
- [ ] Press E → inventory opens; mouse cursor visible; can drag stacks
- [ ] Press E or Esc → inventory closes; mouse re-locks

### 6.6 Commit
`feat: phase 4 — inventory, hotbar, item drops`

---

## 7. Phase 5 — Crafting & Tools

### 7.1 What we build
Recipe registry, 2×2 craft grid in inventory, 3×3 crafting table block, furnace block with smelting timer, tool tier hierarchy with break-speed multipliers.

### 7.2 Files
```
data/recipes.json                # all crafting recipes (shaped + shapeless)
data/smelting.json               # input → output + time (seconds)
data/items.json                  # all item definitions (tools, materials)
scripts/crafting/recipes.gd      # loads + indexes recipes, matches grid → output
scripts/crafting/grid.gd         # 2x2 / 3x3 input matcher
scripts/crafting/furnace.gd      # smelting timer, fuel consumption
scenes/world/crafting_table.tscn # block scene, opens 3x3 craft UI on use
scenes/world/furnace.tscn        # block scene, opens furnace UI on use
scenes/ui/crafting_screen.tscn   # 3x3 grid + result slot
scenes/ui/furnace_screen.tscn    # input + fuel + output slots, progress bar
scripts/player/tools.gd          # tier multipliers: wood 2x, stone 4x, iron 6x, diamond 8x
```

### 7.3 Recipe JSON shape
```json
{
  "id": "wooden_pickaxe",
  "type": "shaped",
  "pattern": ["PPP", " S ", " S "],
  "key": { "P": "planks", "S": "stick" },
  "result": { "id": "wooden_pickaxe", "count": 1 }
}
```

### 7.4 Phase 5 recipe scope
The full Alpha-era ~50 recipes is achievable. Prioritize the **progression chain** first:
- log → 4 planks (shapeless)
- 2 planks → 4 sticks (shaped vertical)
- 5 planks → crafting table (2×2)
- 3 planks + 2 sticks → wooden pickaxe (shaped T)
- Then stone, iron, diamond tiers (pickaxe, axe, shovel, sword, hoe)
- 8 cobblestone → furnace
- coal + iron_ore → iron_ingot (smelting)

Bow, bucket, flint & steel, minecart, boat, compass, clock, map → after MVP.

### 7.5 Break-speed math (Alpha-faithful)
- Each block has `hardness` (seconds to break by hand)
- Tool tier multiplier divides hardness
- Wrong tool tier → block breaks but drops nothing (e.g. wood pick on diamond)
- Stone needs ≥ wooden pick to drop, iron needs ≥ stone, diamond needs ≥ iron

### 7.6 Tests (GUT)
- Recipe matcher: pickaxe pattern in any of 4 grid positions all produce a pickaxe
- Recipe matcher: wrong material in pattern → no match
- Furnace: iron ore + coal → 1 iron ingot in 10 sec, consumes 1/8 of coal stack per smelt
- Tools: stone pickaxe breaks stone in (hardness ÷ 4) seconds

### 7.7 Acceptance criteria
- [ ] Punch tree → log drops; 4 planks craft from 1 log in 2×2
- [ ] Craft sticks, then wooden pickaxe
- [ ] Mine cobblestone (faster than by hand)
- [ ] Craft crafting table → place → open 3×3 grid
- [ ] Craft furnace → place → smelt iron ore with coal → iron ingot
- [ ] Craft full iron tool set

### 7.8 Commit
`feat: phase 5 — crafting recipes, tools, smelting`

---

## 8. Phase 6 — Day/Night & Mobs

### 8.1 What we build
Sky shader with sun/moon, light propagation (block + sky), mob spawning rules, the Alpha mob roster as `CharacterBody3D` scenes with shared base behavior, player health.

### 8.2 Files
```
shaders/sky.gdshader                  # day/night gradient, sun/moon discs
scripts/world/sky.gd                  # drives shader uniforms from time-of-day
scripts/world/lighting.gd             # block-light + skylight BFS flood-fill
scripts/world/spawner.gd              # mob spawning per chunk per tick
scripts/entities/mob_base.gd          # health, AI state machine, despawn rules
scenes/entities/zombie.tscn + zombie.gd
scenes/entities/skeleton.tscn + skeleton.gd
scenes/entities/creeper.tscn + creeper.gd
scenes/entities/spider.tscn + spider.gd
scenes/entities/pig.tscn + pig.gd
scenes/entities/cow.tscn + cow.gd
scenes/entities/chicken.tscn + chicken.gd
scenes/entities/sheep.tscn + sheep.gd
scenes/ui/health_bar.tscn             # 10 hearts (Alpha had 10, no hunger)
scripts/player/health.gd              # damage, respawn, death screen
```
**Note:** No squid (water mobs are Phase 6.5 if we add water sim; otherwise stub).

### 8.3 Lighting
- **Skylight:** 15 at top, decreases through transparent blocks
- **Block light:** torches emit 14, glowstone 15, lava 15
- **BFS propagation:** queue-based flood fill, runs after every block edit
- **Cross-chunk:** maintain a per-chunk "light-dirty" flag; updates propagate to neighbors over multiple frames
- Stored as 2 nibbles per block in a parallel `PackedByteArray` (one byte = (block << 4) | sky)

### 8.4 Mob behavior (Alpha-simple)
- All mobs share `mob_base.gd`: HP, take_damage, knockback, despawn-when-far
- **Wandering** (passive): pick random direction every 5–10s, walk briefly, idle
- **Approach + melee** (zombie, spider, zombie pigman): pathfind toward player within 16 blocks, swing on contact
- **Approach + ranged** (skeleton): same, but back off and shoot arrows at 8 blocks
- **Approach + explode** (creeper): silent approach, hiss + flash within 3 blocks, detonate (we'll skip terrain damage for MVP — flag it)
- **Spawning:** every 1 sec per loaded chunk, attempt 1 spawn; passive on grass in light ≥ 9; hostile in light ≤ 7

### 8.5 Pathfinding
- For MVP, use Godot's built-in `NavigationServer3D` with a navmesh baked per chunk on mesh-update
- Acceptable perf for ≤ ~30 active mobs

### 8.6 Tests (GUT)
- Lighting: a torch in an enclosed room lights all 15 surrounding blocks
- Lighting: skylight propagates down through air, blocked by stone
- Mob spawning: never spawns inside a solid block
- Damage: zombie reduces player HP by 2 per hit; player dies at 0 HP and respawns

### 8.7 Acceptance criteria
- [ ] Sun rises and sets over ~20 min real-time
- [ ] Sky color smoothly transitions; ambient light tracks
- [ ] Place torch underground → 15-block-radius sphere of light visible
- [ ] At night, hostile mobs spawn on dark surfaces; daytime, they burn (zombies, skeletons)
- [ ] Take damage from a zombie; die; respawn at world spawn
- [ ] Passive mobs spawn in grassy areas during day

### 8.8 Commit
`feat: phase 6 — day/night cycle, lighting, mobs, health`

---

## 9. Phase 7 — Persistence & Polish

### 9.1 What we build
Binary save/load for chunks + player + inventory in `user://`, full settings menu, F3 debug overlay, sound stubs, particles, title screen.

### 9.2 Files
```
scripts/persistence/save_load.gd       # FileAccess binary writer/reader
scripts/persistence/region_file.gd     # groups 32x32 chunks per file (Anvil-inspired layout, custom format)
scripts/persistence/settings.gd        # config persistence to user://settings.cfg
scenes/ui/title_screen.tscn            # New World / Continue / Settings / Quit
scenes/ui/pause_menu.tscn              # Resume / Settings / Save & Quit
scenes/ui/settings_menu.tscn           # render distance, sensitivity, FOV, keybinds
scenes/ui/debug_overlay.tscn           # F3 — FPS, coords, chunk count, looking-at block, biome
scenes/world/break_particles.tscn      # GPUParticles3D burst on block break
```

### 9.3 Save format (purpose-built binary)
- One file per **region** (32×32 chunks = 1024 chunks per file)
- Header: magic bytes `MCAC` + version u32
- Index: 1024 × {offset_u32, length_u32, last_modified_u64}
- Per chunk: zlib-compressed `{blocks: PackedByteArray, light: PackedByteArray, dirty: bool}`
- **Player save:** `user://world/player.bin` — position, velocity, HP, inventory, hotbar selection
- **World metadata:** `user://world/world.json` — seed, time-of-day, spawn point, version

### 9.4 Auto-save
- Every 5 minutes: write all dirty chunks + player state
- On graceful quit: same
- Write to temp file, fsync, rename (crash-safe)

### 9.5 Tests (GUT)
- Round-trip: write chunk, read back, byte-for-byte identical
- Round-trip: write player with full inventory, read back, equal
- Region file: writing chunk (5,5) doesn't touch chunk (10,10)'s bytes
- Settings: write, modify in memory, reload from disk, original values restored

### 9.6 Acceptance criteria
- [ ] Build a structure → quit → relaunch → continue → structure intact, in same place
- [ ] Settings (sensitivity, FOV, render distance) persist across launches
- [ ] F3 toggles debug overlay (chunk coords, FPS, mem, looking-at block)
- [ ] Particles burst on block break
- [ ] Title screen → New World prompts for seed; Continue resumes most recent

### 9.7 Commit
`feat: phase 7 — persistence, settings, title screen, polish`

---

## 10. AI Asset Pipeline

### 10.1 What we need
- ~50 block textures @ 16×16 PNG (one per Alpha-era block)
- ~30 item textures @ 16×16 PNG (tools, materials, food)
- ~10 mob textures (skin maps for the simple low-poly models)
- Eventually: a single packed atlas (built at runtime in Godot)

### 10.2 Recommended tools (2026)

**Primary — user has subscription:**
- **Pixellab.ai** — pixel-native generator with native 16×16 output, tileable mode (critical for block faces), style-reference uploads (locks consistency across all blocks), variation generation (avoids tiled-floor look on repeated blocks), sprite-sheet generation for mob animation, and an API for bulk scripting if we go that route. **This is our default for all pixel art.**

**Backup / fallback:**
- **SpriteCook** (MCP, in-session) — useful if Pixellab struggles on a specific asset or for quick one-offs I can drive directly without a handoff
- **Retro Diffusion** — SD-based pixel art with Aseprite plugin; alternative style if Pixellab's house style doesn't match

**Cleanup / packaging:**
- **Aseprite** — the standard pixel art editor; minor touch-up + tile-seam fixing
- **Godot atlas builder** — runtime atlas pack from `assets/textures/blocks/`; no TexturePacker needed

### 10.2.1 Pixellab → repo handoff workflow
Since I can't drive Pixellab from this session, the loop is:
1. I draft a prompt batch + style spec (palette, dimensions, tileable flag) in a checklist comment
2. You generate in Pixellab, save PNGs into `assets/textures/blocks/raw/{block_name}.png`
3. I run a Godot import script that validates dimensions, packs the atlas, and emits a `atlas_uvs.tres` resource
4. Style drift caught by an Aseprite-driven palette diff check (quick eyeball, not automated)

### 10.3 Workflow proposal
1. Lock in a style reference: generate 2–3 reference textures in Pixellab (e.g. stone, dirt, log) and pin them as the style anchor for all subsequent generations
2. For each new block: prompt + reference + tileable=true + dims=16×16 in Pixellab
3. Save PNG → `assets/textures/blocks/raw/{block_name}.png`
4. Optional cleanup pass in Aseprite (only if needed — Pixellab native output usually doesn't need it)
5. Move final to `assets/textures/blocks/`
6. Godot atlas builder script packs all into `atlas.png` + `atlas_uvs.tres` (UV map) at startup

### 10.4 Style guide (lock in early)
- 16×16 strict
- 8-color-per-block palette max
- No anti-aliasing
- Top face slightly brighter than sides (mimics Alpha shading cheat)
- Wood grain runs vertical on logs
- Save as PNG with no metadata, RGBA, sRGB

### 10.5 Phase rollout
- **Phase 0:** 1 placeholder grass texture
- **Phase 2:** ~10 textures (stone, dirt, grass, cobble, log, planks, leaves, sand, bedrock, glass)
- **Phase 4:** + ~15 item textures (drops, tools placeholders)
- **Phase 5:** + ~10 textures (crafting table, furnace, all tool tiers)
- **Phase 6:** + mob textures + sky/sun/moon

---

## 11. Modern Quality-of-Life Features

These extend Alpha gameplay tastefully without breaking the era's feel.

| Feature | Phase | Notes |
|---|---|---|
| **F3 debug overlay** | 7 (stub in 3) | FPS, XYZ, facing, chunk coords, biome, looking-at block. Everyone expects this. |
| **Configurable keybinds** | 7 | Settings → Controls; rebind any input map action |
| **Mouse sensitivity slider** | 7 | 0.0005–0.01 rad/px |
| **FOV slider** | 7 | 60°–110° |
| **Render distance slider** | 3 | 2–12 chunks; live update, no restart |
| **Toggle sneak / sprint** | 1 | Setting: hold (default) vs toggle |
| **Auto-save every 5 min** | 7 | Plus on graceful quit |
| **Crash-safe saves** | 7 | Write-temp + fsync + rename |
| **Smooth lighting** | 6 | Per-vertex light interpolation in chunk shader |
| **Frustum culling** | 3 | Godot does this for free; just verify |
| **Item tooltip on hover** | 4 | Name + count in inventory screen |
| **Death message** | 6 | "You were slain by a Zombie" |
| **Pause menu Save & Quit** | 7 | Distinct from "quit without saving" |
| **Settings persist to disk** | 7 | `user://settings.cfg` |
| **Pre-generate spawn area** | 3 | Generate ~9 chunks around spawn before player drops in (no falling-into-the-void on first load) |

**Explicitly NOT adding (preserves Alpha feel):**
- Hunger bar
- XP / enchanting
- Recipe book / search
- Minimap / waypoints
- Sleep-to-skip-night (Alpha had no beds)
- Item recovery on death (Alpha-era was harsh)

---

## 12. Definition of Done (whole MVP)

- [ ] All 7 phases pass acceptance criteria
- [ ] All GUT tests green (`godot --headless` exits 0)
- [ ] Linter clean (`gdformat --check && gdlint`)
- [ ] Native exports build for macOS, Linux, Windows
- [ ] You can play a 30-min "first night" session: spawn → punch tree → craft tools → mine stone → build a shelter → survive zombies → continue next day
- [ ] Game is saved and resumable
- [ ] No frame drops at render_distance=4 on dev machine
- [ ] README.md links to PLANNING.md, this file, and a short "how to run" guide

---

## 13. Risks & Mitigations (live list)

| Risk | Likelihood | Mitigation |
|---|---|---|
| GDScript chunk mesher too slow at greedy meshing | Medium | Profile in Phase 3; port to C# only if confirmed bottleneck |
| Light propagation across chunk borders glitches | High | Spike a 2-chunk torch test at start of Phase 6 before building rest |
| AI codegen mixes Godot 3 / 4 syntax | High | Always specify "Godot 4.x" in prompts; lint catches most parse errors |
| Visual bugs I can't see from here | High | You screenshot anything weird; we triage together |
| Asset style drift across AI generations | Medium | Lock style guide §10.4; generate batches with same prompt template |
| Save format break during dev | Medium | Bump version u32; keep loader/upgrader skeleton from day 1 |

---

## 14. What I Need From You to Start

Before I scaffold Phase 0, please confirm:
1. **Godot version installed?** (4.3+ preferred)
2. **gdtoolkit + git-lfs installed?** (`pip install gdtoolkit && brew install git-lfs && git lfs install`)
3. **OK to `git init` in `/Users/tomdonohue/projects/minecraft-clone`?**
4. **Pixellab handoff confirmed** — I'll draft prompts, you generate, drop PNGs into `assets/textures/blocks/raw/`. Sound good?

Once you've confirmed, I'll scaffold Phase 0 and we go.
