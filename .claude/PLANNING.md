# Minecraft Alpha Clone — Planning Document

A from-scratch, AI-assisted clone of **Minecraft Java Edition Alpha** (June–December 2010), built in **Godot 4 + GDScript**. The goal is to replicate Alpha's gameplay loop verbatim, not to extend or modernize it.

> Status: **draft** — open questions at the bottom; nothing is committed until we agree.

---

## 1. Vision & Scope

**Build target:** A playable native-desktop voxel survival game that feels like Minecraft Alpha v1.2.0 (Halloween Update, October 2010). Single-player only for MVP. No mods, no Beta/Release content.

**Why Alpha specifically (per research):**
- Self-contained, well-documented era with a clear feature ceiling.
- Small enough mob/block/recipe roster to actually finish.
- Pre-hunger-bar, pre-experience, pre-enchanting → simpler systems.
- The Nether existed by v1.2.0, which is a fun stretch goal but optional.

**Non-goals (MVP):**
- Multiplayer / networking
- Mod loader / data packs
- Modern terrain (3D noise overhangs, climate biomes, structures beyond villages)
- Any post-Alpha content (hunger, XP, brewing, enchantments, villagers, end, etc.)
- Mobile and console targets

---

## 2. Tech Stack — Godot 4 + GDScript

### Primary stack
| Layer | Choice | Why |
|---|---|---|
| Engine | **Godot 4.x (latest stable)** | Open source, MIT-licensed, Vulkan renderer, fast iteration, no per-seat or revenue licensing |
| Language | **GDScript with strict typing** | Tightest editor integration, hot reload on save, smaller AI-codegen surface than C# |
| Renderer | **Vulkan (Forward+)** | Best perf; falls back to GL Compatibility for older HW |
| Player physics | **`CharacterBody3D`** for MVP, custom AABB later if needed | Skip writing a collider on day one; revisit only if precision issues emerge |
| Threading | **`WorkerThreadPool`** (Godot 4.1+) | Worldgen + chunk meshing off the main thread |
| Mesh API | **`ArrayMesh` / `SurfaceTool`** | Direct vertex/index buffer construction; needed for chunk meshing |
| Audio | **`AudioStreamPlayer3D`** | Built-in spatial audio, attenuation, doppler — no work to do |
| Persistence | **`FileAccess` + custom binary chunk format** in `user://` | Simple, fast, version-able. Avoid `ResourceSaver` for bulk voxel data |
| UI | **Godot `Control` nodes** (HUD, hotbar, inventory) | Native, themeable, no external UI lib |
| Testing | **GUT (Godot Unit Test)** | Headless test runner, integrates with `godot --headless` for CI |
| Style / lint | **`gdformat` + `gdlint`** (gdtoolkit) | Pre-commit hook for consistency |
| Version control | **Git + Git LFS** | LFS for textures and audio binaries |

### Why GDScript over C#
- Strict typing (`var blocks: PackedByteArray`, typed function signatures, typed arrays) gets ~80% of static-type safety
- **Hot reload on save** — no compile step, fastest possible inner loop
- Smaller, more stable API surface → less AI hallucination
- For Minecraft-clone scale, only the chunk mesher will ever be perf-critical
- **Escape hatch:** if the mesher is slow, port *that single class* to C# or GDExtension (C++/Rust). Don't go mixed-language preemptively.

### Render & build targets
- **Primary:** Native desktop (Linux, macOS, Windows)
- **Stretch:** Web export (HTML5/WASM) — works but adds ~30 MB engine runtime download
- **Out of scope:** Mobile, console (would need input rework)

### Recommended dev tooling
- **Godot 4 editor** — built-in debugger, profiler, remote scene tree, network monitor
- **Tracy profiler** integration — for deep frame analysis once the mesher is in place
- **GUT** — `godot --headless -s addons/gut/gut_cmdln.gd` for CI tests
- **Aseprite** (or any pixel editor) — for 16×16 textures
- **Pre-commit hook:** `gdformat` + `gdlint`
- **Claude Code** — codegen and `godot --headless --check-only` for syntax verification; **user drives the editor for visual verification** (I can't see the editor in-loop)

### Godot-specific gotchas to lock in early
- **Always specify "Godot 4.x"** in any AI prompt — Godot 3 vs 4 syntax differs in many small ways (`onready` → `@onready`, signal `connect()` API, `Vector3.UP` location, `KEY_*` constants, etc.)
- **Coordinate convention:** Godot uses **-Z forward**, +X right, +Y up. Different from Minecraft's documented "+X east, -Z north." Adopt Godot's convention internally and document the mapping if we ever compare to MC saves.
- **Block storage:** always `PackedByteArray`, never plain `Array[int]` (massive memory hit + slow iteration).
- **Avoid `@tool` scripts** unless we genuinely need editor-time behavior — they run in the editor and can corrupt state on bugs.
- **Don't fight nodes with ECS.** Godot's scene tree *is* the entity model. Use node composition; don't bolt an external ECS on top for a few hundred entities.

### Alternatives considered (and why not)
- **Unity** — mature voxel ecosystem and asset store, but slowest iteration loop (domain reload), proprietary licensing complexity, and AI codegen for Unity's massive C# API hallucinates more than for Godot or TS.
- **Three.js + TS** — best AI training-data coverage and fastest HMR loop, but you wanted a real engine, and WebGL caps voxel throughput.
- **Bevy (Rust)** — best long-term performance, ECS-native, but Rust compile times kill iteration speed for AI-driven dev.
- **Plain WebGPU** — too thin an ecosystem in 2026 for this scope.

---

## 3. Minecraft Alpha Reference (what we're cloning)

Compiled from the Minecraft Wiki's Alpha pages. **In-Alpha** = fair game for MVP; **Beta+** = explicitly out of scope.

### Core mechanics (in Alpha)
- **Infinite world** generated in **16×16×128** chunks (Alpha's vertical limit was 128, not modern 384)
- **2D Perlin noise** terrain — Alpha did *not* have 3D-noise overhangs (that came later); terrain is heightmap-based with caves carved by separate noise
- **Day/night cycle** (~20 min real-time per day)
- **Health system** (10 hearts = 20 HP) — but **no hunger bar** (hunger arrived in Beta 1.8)
- **Sneaking** (added mid-Alpha)
- **Fishing rods** (added mid-Alpha)
- **Redstone** circuits (ore, dust, torches, levers, buttons, pressure plates, doors)
- **Nether** dimension via portals (v1.2.0, Halloween Update)
- **Inventory:** 4 armor + 27 storage + 9 hotbar (40 slots total in Alpha — one extra crafting slot vs Beta's 36)
- **Crafting:** 2×2 in inventory, 3×3 at crafting table; smelting at furnace
- **Stack size** 64 (1 for tools/armor)
- **Multiplayer (SMP)** — out of MVP scope

### Mobs (Alpha roster)
**Passive:** pig, cow, chicken, sheep, squid
**Hostile (overworld):** zombie, skeleton, creeper, spider, slime
**Nether:** ghast, zombie pigman
**Notable absences:** no enderman, no villager, no wolf (wolves came in Beta 1.4)

### Block set (Alpha-era essentials)
Stone, cobblestone, dirt, grass, sand, gravel, wood (oak only — other woods came later), planks, leaves, water, lava, bedrock, ores (coal, iron, gold, diamond, redstone, lapis), glass, wool (16 colors), TNT, torch, ladder, sign, fence, door (wood/iron), stairs, slab, crafting table, furnace, chest, jukebox, note block, bed (added Beta — *exclude*), cactus, sugar cane (then "reeds"), pumpkin, jack o'lantern, snow, ice, clay, brick, mossy cobble, obsidian, glowstone, netherrack, soul sand.

### Crafting recipes (Alpha)
~50 recipes total. Wooden → stone → iron → diamond tool tier progression. Bow + arrows. Bucket. Flint & steel. Boat, minecart (+ powered/storage variants). Compass, clock, map.

### Sounds / music
C418's Alpha-era tracks ("Sweden", "Subwoofer Lullaby", etc.) — we'll need royalty-free substitutes or originals.

---

## 4. Architecture (Godot Project Layout)

```
project.godot
res://
├── main.tscn                       # entry scene, holds Game autoload + initial world
├── scripts/
│   ├── game.gd                     # autoload — global state, day/night clock, pause
│   ├── world/
│   │   ├── chunk.gd                # PackedByteArray block data, dirty flag, neighbor refs
│   │   ├── chunk_manager.gd        # load/unload around player, LRU cache
│   │   ├── mesher.gd               # naive face-cull → greedy meshing (runs in WorkerThreadPool)
│   │   ├── worldgen.gd             # heightmap + caves + ore distribution
│   │   └── blocks.gd               # block registry: id → texture rect, hardness, drops, sounds
│   ├── player/
│   │   ├── player.gd               # CharacterBody3D, WASD/jump/sneak, mouse-look
│   │   ├── inventory.gd            # 40-slot model, stack rules
│   │   └── interaction.gd          # raycast → break/place block
│   ├── entities/
│   │   ├── mob_base.gd             # shared damage/ai/animation behavior
│   │   ├── zombie.gd
│   │   ├── creeper.gd
│   │   └── ...
│   ├── crafting/
│   │   ├── recipes.gd              # data-driven recipe table loader
│   │   ├── grid.gd                 # 2x2 / 3x3 matcher (shaped + shapeless)
│   │   └── furnace.gd              # smelting timer + fuel
│   └── persistence/
│       └── save_load.gd            # FileAccess binary format, region-file style
├── scenes/
│   ├── player/player.tscn
│   ├── world/chunk.tscn            # MeshInstance3D + StaticBody3D for collision
│   ├── ui/hotbar.tscn
│   ├── ui/inventory.tscn
│   ├── ui/pause_menu.tscn
│   └── entities/zombie.tscn, creeper.tscn, ...
├── shaders/
│   ├── chunk.gdshader              # block lighting, atlas sampling, biome tint
│   └── sky.gdshader                # day/night sky gradient, sun/moon
├── assets/
│   ├── textures/blocks/            # 16x16 PNGs, packed into atlas at runtime
│   ├── textures/items/
│   ├── audio/sfx/
│   └── audio/music/
├── data/
│   └── recipes.json                # crafting + smelting recipes
├── addons/
│   └── gut/                        # GUT testing framework
└── tests/                          # GUT test suites
```

### Key architectural decisions to lock in early
1. **Coordinate system:** Godot-native — +Y up, -Z forward, +X right. Internal "world coords" match Godot directly.
2. **Block IDs:** byte-sized (0–255) stored in `PackedByteArray`. Alpha never exceeded this; widening to `u16` is a pointless cost.
3. **Chunk storage:** flat `PackedByteArray` of size `16*16*128 = 32_768` per chunk, indexed `[y * 256 + z * 16 + x]` (Y-major for cache-friendly vertical scans during meshing and lighting).
4. **Meshing strategy:** start with **face-culled naive meshing** (skip hidden faces between two opaque blocks). Upgrade to **greedy meshing** only after profiling shows it's needed. Don't pre-optimize.
5. **Worker boundary:** worldgen + meshing run in `WorkerThreadPool`. Workers produce vertex/index `PackedVector3Array`/`PackedInt32Array` and hand them back to the main thread, which calls `ArrayMesh.add_surface_from_arrays` (the only Godot scene API that's main-thread-only).
6. **Tick rate:** rendering uncapped via `_process`. Game logic on `_physics_process` (60 Hz default). Mob AI ticks at Minecraft-faithful 20 Hz via a `Timer` node firing every 50 ms.
7. **Atlas:** all block textures packed into one atlas at startup, sampled in the chunk shader by UV offset. Avoids per-chunk material switching.

---

## 5. MVP Milestones

Each phase is independently demoable and ends with a screenshot/gif worth showing.

### Phase 0 — "I see a cube" (~½ day)
- New Godot 4 project, set up `project.godot`, configure Vulkan renderer
- Add a `MeshInstance3D` with a `BoxMesh` and a textured `StandardMaterial3D`
- `Camera3D` with simple orbit script
- FPS counter (`Engine.get_frames_per_second()` in a Label)
- Pre-commit hook with `gdformat` + `gdlint`
- **Done when:** textured cube spins in the editor + an exported build

### Phase 1 — "I can walk on blocks" (~1 day)
- Hand-build a 16×16×16 chunk of stone+grass via a script (one `MeshInstance3D` per block — placeholder, not optimized)
- `CharacterBody3D` player scene with capsule collider, mouse-look, WASD, jump, gravity
- Pointer capture on click; ESC to release
- **Done when:** you can run around the platform without falling through. *(Godot's built-in physics saves us a custom AABB collider on day one.)*

### Phase 2 — "I can mine and place" (~1 day)
- Replace the per-block `MeshInstance3D` approach with `ArrayMesh` built from the chunk's `PackedByteArray` (face-culled naive meshing)
- Raycast from camera (`PhysicsDirectSpaceState3D.intersect_ray`) to find target block
- LMB to break (instant for now), RMB to place
- Re-mesh chunk on edit, regenerate `StaticBody3D` collision
- Crosshair UI
- **Done when:** you can dig a tunnel and build a wall

### Phase 3 — "It's a real world" (~3–4 days)
- `ChunkManager` with load/unload around player, LRU cache
- 2D Perlin heightmap worldgen (Godot's `FastNoiseLite`) running in `WorkerThreadPool`
- Grass/dirt/stone/bedrock vertical layering
- Ore distribution pass (coal, iron near surface; diamond deep)
- Simple cave carving via 3D noise threshold
- Render distance config (`@export var render_distance := 4`)
- **Done when:** infinite-feeling terrain with caves, no frame drops at default render distance

### Phase 4 — "Inventory & hotbar" (~2 days)
- 40-slot inventory data model (4 armor + 27 storage + 9 hotbar in a `Resource` subclass)
- Hotbar UI with `Control` nodes (1–9 keys + scroll wheel)
- Inventory screen (E to open) with 2×2 craft grid
- Block drops on break (small `RigidBody3D` items), pickup on walk-over
- Stack splitting / merging via mouse drag
- **Done when:** breaking dirt gives you dirt, you can place it from hotbar

### Phase 5 — "Crafting & tools" (~2 days)
- Recipe registry from `data/recipes.json` (shaped + shapeless)
- Crafting table (3×3) and furnace block scenes
- Wooden → stone → iron → diamond tool tiers
- Tool-appropriate break speeds + drop rules (stone needs pickaxe, etc.)
- **Done when:** chop wood → planks → sticks → wooden pickaxe → mine stone → stone tools → smelt iron

### Phase 6 — "Day, night, and danger" (~3 days)
- Sky shader (`gdshader`) with sun/moon, smooth day/night gradient
- Light propagation: block light + skylight, BFS flood-fill stored per chunk
- First mob: **zombie** scene (`CharacterBody3D` + `mob_base.gd`) — wanders, despawns in daylight, melees player
- Health, damage, respawn at world spawn
- Then: skeleton, creeper, spider, pig, cow, chicken, sheep
- Mob spawning rules (light level, surface for passive, dark for hostile)
- **Done when:** night is genuinely scary

### Phase 7 — "Persistence & polish" (~2 days)
- `FileAccess` binary save/load for chunks + player + inventory in `user://world/`
- Pause menu, settings (render distance, mouse sensitivity, FOV)
- `GPUParticles3D` for block-break particles
- Sound effects via `AudioStreamPlayer3D`
- Title screen
- **Done when:** you can quit, reopen, and resume

### Stretch — "The Nether" (Halloween Update parity)
- Obsidian + flint & steel → portal block
- Nether dimension (separate world, 1:8 scale)
- Netherrack, soul sand, glowstone, lava seas
- Ghast (ranged fireball mob), zombie pigman (neutral, swarm-on-hit)
- **Done when:** you can portal there and back, with separate save data

**Estimated MVP total:** ~2.5–3 weeks of focused dev with heavy AI assist. Stretch adds ~1 week.

---

## 6. Risks & Open Questions

### Technical risks
- **Chunk mesher perf in GDScript.** Naive meshing might be fine, but greedy meshing in pure GDScript may not hit 60 FPS at higher render distances. Mitigation: profile early; port `mesher.gd` to C# or GDExtension if it shows up as the bottleneck.
- **WorkerThreadPool ergonomics.** Passing chunk data between threads is by reference for `PackedByteArray`, which is fast — but main-thread `ArrayMesh` updates can stall. Plan to amortize over multiple frames (1–2 chunks meshed per frame max).
- **Light propagation across chunk borders.** Classic voxel-engine landmine — BFS flood-fill that crosses chunks must invalidate neighbors. Spike this early in Phase 6.
- **Visual verification gap.** I can't drive the Godot editor in-loop the way I could drive a browser. Plan: you screenshot weird visuals; I read them and react. Also use `godot --headless` for any logic I can verify text-only.

### Design questions for you
1. **Faithfulness vs. quality-of-life.** Alpha had no minimap, no waypoints, brutal nights. Strict Alpha fidelity, or selective modern QoL? *My lean: strict fidelity — that's the point of choosing Alpha.*
2. **Art assets.** Original Alpha textures are copyrighted. Options: (a) commission/AI-generate a faux-16×16 pack, (b) use a CC-licensed pack, (c) ship placeholder solid colors and theme later. *My lean: (c) for MVP, swap in (a) before any public sharing.*
3. **Music.** Skip for MVP, or commission/generate ambient tracks?
4. **Public release.** Itch.io? GitHub Releases? Or strictly private? Affects the legal-risk shape of the asset question.
5. **The Nether.** In MVP or stretch? *My lean: stretch — it doubles the worldgen + mob complexity.*
6. **Save format compatibility.** Should our save format be vaguely Anvil-like (so we could later import/export to MC), or purpose-built for our engine? *My lean: purpose-built — Anvil compat is a swamp and unnecessary for Alpha-clone goals.*

---

## 7. Suggested Next Steps

Once you've reviewed this:
1. Answer the open questions in §6.
2. I scaffold Phase 0: a Godot 4 project with a textured spinning cube, `gdformat`/`gdlint` pre-commit, and a GUT test runner stub.
3. We `git init`, commit, and iterate from there milestone by milestone.

---

*Sources: [Minecraft Wiki — Java Edition Alpha](https://minecraft.wiki/w/Java_Edition_Alpha), [Alpha v1.2.0 Halloween Update](https://minecraft.wiki/w/Java_Edition_Alpha_v1.2.0), [Minecraft Wiki — World Generation](https://minecraft.wiki/w/World_generation), [Vercidium — Voxel World Optimisations](https://vercidium.com/blog/voxel-world-optimisations/).*
