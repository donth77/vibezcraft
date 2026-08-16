# Minecraft Alpha 1.2.6-Faithful Nether Implementation Plan

- Status: implementation-ready plan
- Target: Minecraft Java Edition Alpha v1.2.6 behavior, adapted to this
  project's architecture
- Audience: a parallel implementation session working in this
  repository
- Last source audit: 2026-08-16

## 1. Purpose and execution contract

This document is the handoff contract for implementing the complete
Alpha v1.2.6 Nether slice: dimension travel, Nether blocks and the one
new inventory item, terrain and caves, population features, environment
rules, portals, zombie pigmen, ghasts, ghast fireballs, natural
spawning, assets, persistence, and performance hardening.

The implementation session must:

1. Read `CLAUDE.md`, `.claude/optimizations.md`, and
   `.claude/alpha-1.2.6-mapping.md` before changing code.
2. Treat the local Alpha source listed in section 16 as the behavioral
   authority. Wiki pages are historical cross-checks, not substitutes
   for source.
3. Work in the batch order in section 11. Do not begin a later batch
   until the current batch's acceptance criteria and tests pass.
4. Preserve every existing persisted block and item ID. Never renumber
   content to make room.
5. Keep a simple, readable GDScript implementation as the reference
   path. Add or extend native generation only after source fixtures pass
   against that path, then require byte-for-byte native parity.
6. Preserve the project's deterministic, order-independent world
   generation contract even where the original client depended on a
   shared mutable RNG. The deliberate deviation is specified in
   section 6.5.
7. Run the full test suite at each batch exit, not only the new tests.
   Capture test counts, fixture hashes, and performance measurements in
   the handoff.
8. Keep unrelated worktree changes intact. Do not commit automatically;
   leave each completed batch checkpoint-ready unless the operator asks
   for commits.

This plan has sequential architecture dependencies even if the work is
performed in a parallel session. Before editing, claim the current
batch and refresh `git status`. Never revert another session's changes.
Parallelize independent fixture, asset, or test work only after the
owning batch has frozen its interfaces; do not concurrently edit the
content registries, `ChunkManager`, save formats, or native ABI from two
sessions.

If source and this document disagree, stop, record the source evidence,
and update the plan before implementing the disputed behavior. If a
performance optimization changes observable Alpha behavior, reject it
unless the deviation is explicitly approved and documented.

## 2. Definition of faithful

“Alpha-faithful” means the released Java Alpha v1.2.6 behavior, not a
modern Nether and not a reconstruction from memory. The implementation
must reproduce the following observable contract:

- Dimension ID `-1`, 16×128×16 chunks, an enclosed ceiling, large
  netherrack caverns, a lava sea, bedrock at both vertical extremes,
  Nether caves, soul-sand/gravel surface patches, lava springs, fire,
  glowstone clusters, and both mushroom colors.
- Netherrack, soul sand, glowstone, the portal world block, and
  glowstone dust, with their Alpha hardness, drops, crafting, light,
  collision, and fire behavior.
- Classic 4×5-outer-footprint portals with a 2×3 interior and optional
  corner cells, 8:1 horizontal coordinate scaling, bounded destination
  search, and portal creation.
- Nether-specific fog, darkness, absent sky/clouds/celestial lighting,
  longer horizontal lava flow, water evaporation, and unreliable
  compass/clock displays.
- Zombie pigmen and ghasts as the only natural hostile Nether species,
  including Alpha combat, aggro, fire immunity, drops, visuals, sounds,
  and persistence semantics.
- Every player-obtainable new block/item working in the debug spawner,
  inventory and hotbar, held first-person and third-person views,
  dropped form, pickup flow, and placed/use form.

The project may make only these predetermined compatibility deviations:

- Nether feature placement is canonicalized to be deterministic by
  source chunk and independent of generation/load order (section 6.5).
- The project can maintain a validated portal index as a transparent
  acceleration structure; bounded raw portal search remains the
  correctness fallback.
- Because this project already has beds, attempting to use one in the
  Nether is denied with “This dimension is unsuitable for sleeping.”
  Do not add the later exploding-bed mechanic.
- The extracted Alpha texture pack is the visual fidelity oracle.
  Source sound-event names and any locally supplied Alpha sound set are
  the audio oracle; default-pack fallbacks must preserve the same
  silhouettes, animation states, and event coverage.

### Explicitly out of scope

- Nether fortresses, blazes, magma cubes, wither skeletons, quartz,
  nether brick, biomes, modern ambient particles, respawn anchors, and
  modern portal sizes.
- Ghast tears, gold nuggets, zombie-pigman weapon drops, bartering, or
  zombified-piglin forgiveness.
- Modern four-dust glowstone crafting; Alpha v1.2.6 uses nine dust.
- Modern entity-through-portal support. In the Alpha client source the
  local player owns the dimension-change callback.
- A general save-ID widening migration. The current byte namespace is
  sufficient for this feature with the reservation below.
- Rewriting unrelated Overworld terrain or changing established
  Overworld behavior.

## 3. Repository audit and blocking design decisions

### 3.1 The content-ID range is already exhausted

Chunks and inventories persist unsigned byte IDs. Current blocks use
`0–49` and `51–96`; `50` is a burned legacy tall-grass value. Items use
`100–204`. Four new world blocks do not fit below 100.

Reserve the following globally unique IDs after re-auditing the live
registries. Abort the batch if any reservation is no longer free.

| Content | Project ID | Alpha source ID | Kind | Inventory form |
|---|---:|---:|---|---|
| Netherrack | 97 | 87 | block | yes |
| Soul sand | 98 | 88 | block | yes |
| Glowstone | 99 | 89 | block | yes |
| Glowstone dust | 205 | 348 | item | yes |
| Portal | 206 | 90 | block | no |

Do not reuse ID 50: an older save containing that byte could silently
turn removed tall grass into portals. Do not renumber existing IDs.
Reserve `207–255` for future content in the same unified byte namespace.

The engine currently infers content type from `id < 100`. Replace that
assumption with explicit registry queries:

- `Blocks.is_registered(id)`
- `Blocks.has_item_form(id)` or
  `Blocks.is_inventory_placeable(id)`
- `Items.is_registered(id)`
- one invariant test that every non-air ID belongs to exactly one
  registry and that all IDs fit `0–255`

At minimum audit and remove numeric classification from:

- `scripts/player/interaction.gd`
- `scripts/player/player.gd`
- `scripts/world/dropped_item.gd`
- `scripts/world/blocks.gd`
- `scripts/ui/item_icons.gd`
- `scripts/ui/debug_item_spawner.gd`
- item placement, debug-tool, held-item, dropped-item, and redstone
  rendering tests

`BlockAtlas` already has a 256-entry lookup table and chunk/native
storage is already byte-compatible with block ID 206. Test those facts;
do not widen storage speculatively.

### 3.2 Generation must remain worker-safe

Chunk generation runs off-thread. It may return only voxel/data results;
it must not touch scene nodes, resources, autoload state, or live
neighbor chunks. Nether population crosses chunk edges, so use the
existing source-chunk decoration ownership model and a sufficient voxel
halo. Apply results on the main thread in a fixed order.

Every queued job and result must carry:

- dimension ID;
- a monotonically increasing transition/generation epoch;
- chunk coordinates;
- generator/provider identity where useful for diagnostics.

Discard a result if any of those no longer matches the active world.
This prevents an old Overworld worker result from materializing after a
portal transition.

### 3.3 Save storage currently assumes one dimension

Keep the existing Overworld layout byte-compatible. Add dimension-aware
paths rather than moving old files:

```text
user://WorldN/
  world.json
  player.bin
  entities.bin              # existing Overworld entities
  region/                   # existing Overworld chunks
  DIM-1/
    entities.bin
    region/
    portal_index.bin        # optional, rebuildable acceleration data
```

Include dimension in region-cache keys and all APIs that resolve
chunks, entities, scheduled ticks, or world-scoped block-entity data.
Upgrade `player.bin` to a versioned format that stores the current
dimension. A v1 player save migrates to dimension 0 without changing
any other value.

Use one `ChunkManager` and one resident dimension at a time. Portal
travel must save and unload the source, clear or re-key every
dimension-owned queue/cache, select the destination provider, load its
chunks and entities, then place/unfreeze the player. Do not keep both
dimension scene graphs resident.

### 3.4 Spawning is not currently a complete integration path

`NaturalMobSpawner` exists but is not wired into normal chunk-manager
ticks; only the passive spawner is called for fresh chunks. Refactor or
wire a single authoritative natural hostile spawn controller. Nether
spawn predicates must not inherit an Overworld light-level gate.

The F6 debug mob spawner currently searches for a topmost floor. Add
species spawn descriptors:

- zombie pigman: grounded, two-block creature clearance;
- ghast: airborne search for a clear 4×4×4 volume, away from the
  ceiling and floor;
- cage spawning: apply the same species clearance rather than spawning
  into blocks.

### 3.5 Asset tooling is incomplete

The local `vendor/mojang/alpha-1.2.6/client.jar` contains
`terrain.png`, `gui/items.png`, `mob/ghast.png`,
`mob/ghast_fire.png`, and `mob/pigzombie.png` — all five verified
present during Batch 0.

**Corrected 2026-08-16 (Batch 0).** This section previously said the
extractor was missing. It is not. Commit `1d12a1b`
("chore(tools): move vanilla-touching scripts to gitignored internal/")
deliberately relocated it, with six other tools that read Mojang
material, to `scripts/dev/internal/extract_alpha_pack.py`;
`.gitignore` excludes that directory so the tools stay on disk but out
of a public tree. Do not "restore" it to a tracked path — that would
undo an intentional legal-hygiene decision.

What the move *did* break was the tool's `ROOT` constant: the file went
one directory deeper without the path walk being updated, so every input
resolved under `scripts/` and the extractor could not run at all. Batch 0
fixed `ROOT`, added a `--verify` dry run that reports required inputs,
planned write targets and their ignore status, and pinned both in
`tests/test_alpha_pack_extractor.gd`. `CLAUDE.md`'s layout section now
points at the real location.

Note for Batch 2: re-running the extractor writes two item sprites the
pack does not currently carry (`boat`, `leather`), and the extracted
`leather` differs from the `assets/textures/items/leather.png` fallback.
Batch 0 deliberately left the pack untouched; choosing between the
extracted sprite and the shipped fallback is Batch 2's call.

Extract the required files into the pack layout expected by the runtime
and provide default-pack fallbacks for every texture and sound. Because
the repository globally ignores PNG files, add narrow allow-rules for
the intended default-pack asset paths and verify the complete asset set
from a clean checkout/build. The client JAR does not contain the Alpha
sound library, so audit existing `assets/audio/sfx/` coverage and source
the required event files separately from the texture extraction step.

## 4. Source-derived block and item specification

### 4.1 Content definitions

| Content | Source behavior to reproduce |
|---|---|
| Netherrack | Terrain texture tile 103; rock material; hardness 0.4; stone step sound; mineable effectively by every pickaxe tier; supports fire forever. |
| Soul sand | Terrain tile 104; sand material and sound; hardness 0.5; collision top at 0.875 blocks; colliding entities have horizontal X/Z velocity multiplied by 0.4. |
| Glowstone | Terrain tile 105; glass material/sound; hardness 0.3; emitted light 15; always drops exactly one glowstone dust in Alpha v1.2.6. |
| Glowstone dust | Item tile 73; stacks normally; a full 3×3 grid of nine dust crafts one glowstone block. |
| Portal | Source block ID 90; project ID 206; no inventory form, collision, selection box, or drop; emitted light 11 from source emission 0.75; translucent animated world rendering. |

The Alpha atlases are row-major 16×16 tile sheets:

- netherrack 103 → tile `(7, 6)`;
- soul sand 104 → `(8, 6)`;
- glowstone 105 → `(9, 6)`;
- portal source tile 14 → `(14, 0)`;
- glowstone dust item 73 → `(9, 4)`.

Use these coordinates in the local Alpha extraction mapping. Default
fallback files must use semantic names and may be original art.

### 4.2 Interaction details

- Netherrack fire is persistent because fire checks its supporting
  block. This is a fire-system rule, not a large random tick value.
- Soul-sand slowdown applies to all colliding movable entities. It must
  not alter vertical velocity and must work at chunk seams.
- Soul sand's 0.875 collision top affects eye/foot height and movement;
  do not fake it using only a speed modifier on a full-height cube.
- Glowstone break/drop behavior is independent of tool tier in the
  source and produces one dust, never the block.
- The nine-dust recipe must consume all nine slots and produce exactly
  one block.
- Portal cannot appear in creative/debug item lists and cannot be
  obtained through pick-block unless a separate developer-only raw-ID
  tool is deliberately used.

## 5. Dimension and environment specification

Implement a small dimension/provider abstraction rather than adding
`if nether` branches throughout unrelated systems. The provider should
own or expose:

- ID and save namespace;
- generator;
- sky/skylight policy;
- fog and background colors;
- celestial angle/time-display policy;
- fluid-placement and flow rules;
- natural spawn tables;
- coordinate scale;
- surface-spawn/respawn policy.

### 5.1 Alpha Nether environment

- Dimension ID: `-1`.
- World height: 128, matching existing chunk storage.
- No sky, sun, moon, stars, clouds, rain, or Overworld horizon.
- Fixed celestial angle `0.5` for source-compatible queries, while
  visual sky rendering remains disabled.
- Fog color: `(0.2, 0.03, 0.03)` before engine color-space conversion.
- Use the source no-sky brightness table with ambient floor 0.1;
  Overworld uses 0.05. For level `i`, fixture
  `f = 1 - i / 15` and
  `brightness[i] = (1 - f) / (f * 3 + 1) * 0.9 + 0.1`.
  Do not generate or propagate skylight in Nether chunks.
- Do not allow Nether terrain to define a player spawn point.
- World time can remain root/global for save compatibility, but it
  must not visibly drive the Nether.

### 5.2 Dimension-specific rules

- Placing water from a bucket plays the fizz effect, emits eight large
  smoke particles, places no fluid, and leaves the empty bucket.
- Lava keeps the 30-tick lava update cadence. Its horizontal decay
  increment is one in the Nether instead of the Overworld increment of
  two, producing the Alpha v1.2.2-and-later longer reach. Do not
  describe or implement this as faster ticking.
- Compass and clock displays wander unpredictably in the Nether. Use a
  stable per-instance animation process; do not mutate inventory data
  or allocate a new texture every frame.
- Bed use is denied, does not set spawn, does not pass time, and does
  not explode.
- Death while in the Nether switches to dimension 0 before applying
  the existing bed/world-spawn respawn selection.
- Existing Overworld lighting, water, lava, clock, compass, bed, spawn,
  and day/night behavior must remain regression-identical.

## 6. Terrain generation and shape

### 6.1 Generator pipeline

Add a dedicated `WorldgenNether` reference generator with these
explicit stages:

1. coarse density field;
2. trilinear interpolation and base netherrack/lava fill;
3. bedrock and surface replacement;
4. Nether cave carving;
5. source-chunk population/decorations;
6. lighting inputs and chunk metadata.

Do not fork the Overworld generator by sprinkling Nether conditions
inside `worldgen.gd`. Shared Java RNG/noise helpers are appropriate;
the dimension pipelines should remain separately testable.

Use the project's Java-compatible RNG/noise implementation exclusively:
preserve the 48-bit `Random` state, bounded-`nextInt` rejection,
`nextDouble`, cached `nextGaussian` behavior, Java signed-64 overflow,
and cast/truncation semantics. Do not substitute Godot RNG, native
`rand`, or generic floor calls for negative-coordinate source casts.

### 6.2 Density field and base fill

`ChunkProviderHell` (`kj.java`) constructs all noise generators from one
shared Java `Random` in this exact order:

1. 16-octave field;
2. 16-octave field;
3. 8-octave selector;
4. 4-octave surface field;
5. 4-octave surface field;
6. 10-octave auxiliary field;
7. 16-octave auxiliary field.

Preserve constructor consumption order. Generate a `5×17×5` coarse
density grid and interpolate each coarse cell `4×8×4` to fill the
`16×128×16` chunk.

Source constants and transforms to lock into fixtures:

- horizontal base scale `684.412 / 80`;
- vertical base scale `2053.236 / 60`;
- main-field X/Z scale `684.412`;
- main-field Y scale `2053.236`;
- selector divided by 10 before blending;
- vertical bias `cos(y * PI * 6 / 17) * 2`;
- the source cosine bias's cubic penalty within four samples of both
  vertical boundaries;
- the separate final-three-sample top blend toward `-10` (the
  lower-bound blend branch is inactive because its source threshold is
  zero);
- density-positive cells become netherrack;
- density-negative cells below Y 32 become still lava, otherwise air.

The source array layout is `(x * 16 + z) * 128 + y`. The project chunk
layout is `y * 256 + z * 16 + x`. Remap through named indexing helpers;
never paste source index arithmetic into project storage.

### 6.3 Surface replacement and bedrock

For each X/Z column, reproduce `kj.java`'s RNG consumption and rules:

- randomized bottom and top bedrock layers using `nextInt(5)`;
- surface depth based on surface noise `/ 3 + 3 + random * 0.25`;
- soul-sand and gravel patch selection around Y 60–65 from the two
  0.03125-scale noise fields;
- netherrack as the normal top/filler block;
- if the selected surface is air below Y 64, substitute lava.

Bedrock must prevent reaching the void or roof without making each
boundary a perfectly flat slab.

### 6.4 Nether caves

Port `ju.java` as a dedicated Nether cave stage, including the
`MapGenBase` source-neighborhood behavior it relies on.

- Carve only the source-eligible netherrack, dirt, and grass IDs
  (practically netherrack in normal Nether terrain).
- Abort a candidate segment when lava is detected in its safety scan.
- Clamp carving to Y 1–119.
- Preserve source RNG, branch, radius, and interpolation order.
- Make cross-chunk output independent of request order.

### 6.5 Population, cross-chunk ownership, and deterministic deviation

The source populates in this fixed order:

1. eight lava-spring anchors at
   `x/z = chunk * 16 + nextInt(16) + 8` and
   `y = nextInt(120) + 4`;
2. `nextInt(nextInt(10) + 1) + 1` fire-cluster anchors, with the same
   X/Z and Y formulas;
3. `nextInt(nextInt(10) + 1)` glowstone-A anchors, again with the same
   X/Z and Y formulas;
4. ten glowstone-B anchors at the same offset X/Z but
   `y = nextInt(128)`;
5. one brown-mushroom anchor at the same offset X/Z and
   `y = nextInt(128)`;
6. one red-mushroom anchor with that same coordinate formula.

The mushroom guards use `nextInt(1) == 0` and are therefore always
true. Keep that oddity.

Feature rules:

- Lava spring (`kf.java`): above must be netherrack; the candidate is
  air or netherrack; among the four sides plus below, exactly four are
  netherrack and one is air.
- Fire cluster (`pm.java`): 64 attempts using triangular X/Z offsets
  from two `nextInt(8)` calls and triangular Y offsets from two
  `nextInt(4)` calls; place only in air with netherrack below.
- Both glowstone entry points (`dt.java` and `lp.java`): anchor must be
  air with netherrack above; place it, then make 1,500 attempts with
  triangular X/Z offsets in ±7 and downward offsets 0–11; place in air
  only when exactly one orthogonal neighbor is glowstone. Keep two
  named entry points until parity proves their decompiled behavior is
  identical.
- Mushroom decorator (`aj.java`): 64 attempts using the same
  triangular X/Z ±7 and Y ±3 formulas as fire; place only in air when
  the existing mushroom block's source placement predicate succeeds.

Decorators begin at a +8 X/Z offset and can spill across chunk
boundaries. A source chunk owns its decoration RNG/results. Generate
into a halo or deterministic write list, then merge source chunks in a
fixed order. Never mutate a live neighbor from a worker.

Important deliberate deviation: unlike the Overworld provider,
`kj.java` does not reseed its shared RNG before population. Literal
emulation would make decorations depend on which chunks happened to
load first. For this project, reconstruct each source chunk's
post-surface Java-Random state from
`cx * 341873128712 + cz * 132897987541` and the exact surface RNG
consumption, then run that source chunk's population sequence. This is
the canonical expected output for both GDScript and native paths.
Record this deviation in code comments and fixture metadata.

## 7. Portals and dimension travel

### 7.1 Frame validation and activation

Reproduce `x.java`, not modern portal rules:

- the tested outer footprint is exactly four blocks wide and five
  blocks tall;
- the two three-block vertical sides and the two two-block horizontal
  edges must be obsidian;
- the four outer corner cells are skipped by the Alpha validator and
  are optional; they may be obsidian, air, or another block;
- interior is exactly two wide by three tall;
- orientation is along one horizontal axis;
- every interior cell must be air or fire;
- fire placement/update inside a valid frame fills all six cells with
  portal blocks;
- derive visual axis from adjacent portal cells as `x.java` does; do
  not add modern portal-axis metadata that changes the save contract;
- breaking/invalidating the frame causes its portal cells to remove
  themselves.

Portal cells have no collision or selection box. Render a thin,
two-sided, translucent surface aligned to the frame axis, with the
source 0.25-block visual thickness. Port `et.java`'s deterministic
32-frame portal texture generator (`Random(100)`) or consume an exact
fixture-equivalent 32-frame result, and preserve the source animation
cadence. Use one shared material/texture resource, not one material per
block or chunk. On random display ticks, use the source one-in-100
`portal.portal` ambient-sound gate and four orientation-aware portal
particles per portal cell. Add the screen overlay/transition effect
without allowing particles or audio voices to grow without bound.

### 7.2 Exposure and transition

The local player accumulates portal exposure by `0.0125` per tick,
requiring 80 ticks (four seconds at 20 Hz) to travel. Outside a portal,
exposure decays by `0.05` per tick. Completion sets a ten-tick cooldown.
Play trigger and travel sounds at the source-compatible points and use
the Alpha loading labels “Entering the Nether” and “Leaving the
Nether.” Other entities pass through the non-colliding portal cells but
do not change dimensions in this Alpha client target.

Make travel a non-reentrant transaction:

1. lock input and expose the loading UI;
2. save player and source-dimension dirty chunks/entities;
3. increment the generation epoch and cancel/discard stale work;
4. unload source nodes and clear/re-key dimension-owned runtime state;
5. select destination provider and derive scaled coordinates;
6. find or create the destination portal;
7. load/materialize a safe destination ring;
8. place the player, zero velocity, preserve yaw, set pitch to zero,
   set cooldown, persist the new dimension, and unlock input;
9. on failure, restore a safe source state and report the error rather
   than leaving a partially switched save.

Entering `-1` divides X/Z by 8. Returning to `0` multiplies X/Z by 8.
Use doubles/floats during scaling and floor rules consistent with
negative coordinates; add explicit negative-coordinate tests.

### 7.3 Destination search and construction

- Search the inclusive 128-block horizontal X/Z radius and Y 127 down
  through 0 for portal blocks, selecting the nearest squared 3D
  distance. Preserve `no.java`'s X-major, then Z, then descending-Y scan
  order as the tie-breaker.
- Normalize candidates to the bottom portal cell before comparing or
  placing the player.
- If no portal exists, search a radius of 16 for a source-compatible
  frame site with clearance.
- If no normal site exists, clamp the fallback Y to 70–118, build a
  safe obsidian platform/frame, and activate it.
- Place the player at the source-compatible portal center, with zero
  velocity, retained yaw, and pitch zero.

A portal index may avoid loading every chunk in the radius, but it is
rebuildable cache data, must validate indexed portals before use, must
remove stale entries, and must fall back to bounded raw chunk search.
Never make correctness depend on the cache.

## 8. Mobs, projectiles, and spawning

### 8.1 Zombie pigman

Implement the Alpha `pt.java` behavior:

- 20 health inherited from the hostile base, melee damage 5;
- texture `/mob/pigzombie.png`;
- movement speed 0.5 while neutral and 0.95 with a target;
- immune to fire;
- neutral while `Anger == 0`;
- when attacked by a player, alert every zombie pigman in an AABB
  expanded 32 blocks on X, Y, and Z, and target that player;
- set `Anger = 400 + nextInt(400)` and delayed angry sound countdown
  `nextInt(40)`; preserve the source edge case where an initial zero
  countdown never enters the decrement-to-zero sound branch;
- preserve Alpha's quirk: `Anger` is never decremented. Once angered it
  remains nonzero and is persisted as a short. Do not implement modern
  20–40-second forgiveness;
- after load, a nonzero-anger pigman must be able to reacquire a valid
  player target;
- hold an existing golden sword, using a reusable mob-held-item render
  path based on the skeleton implementation;
- ambient/hurt/death/angry sounds use the source pig-zombie event
  families;
- drop 0–2 cooked porkchops; do not drop the sword or gold nuggets.

Tests must cover group aggro at the edges and outside of the expanded
32-block AABB, permanent anger over more than 800 ticks, save/reload,
speed switching, fire/lava immunity, held-sword rendering, and drop
bounds.

### 8.2 Ghast

Implement `am.java` and its model/renderer:

- a 4×4 collision body, flying movement, fire immunity, 10 health, and
  one-per-group limit;
- normal and charged textures
  `/mob/ghast.png` and `/mob/ghast_fire.png`;
- immediately despawn/kill itself on Peaceful;
- choose waypoints within ±16 on all axes; reroll when distance is
  below 1 or above 60;
- every 2–6 ticks, collision-scan the path and accelerate by 0.1 along
  it, or reset the waypoint to the current position when blocked;
- acquire the nearest player within 100 blocks and reacquire every 20
  ticks;
- engage within 64 blocks and line of sight;
- face the target; play charge sound at counter 10; fire at counter 20;
  spawn the projectile four blocks forward; reset the counter to -40;
  decrement positive charge when line of sight/range is lost;
- switch to the charged texture only when the charge counter is above
  10;
- use source moan/scream/death sounds at source volume 10;
- drop 0–2 gunpowder, never ghast tears;
- natural spawn predicate is one chance in 20 after normal collision
  validity and difficulty greater than Peaceful.

Model the 16×16×16 body and nine two-pixel tentacles from `hc.java`.
Tentacle lengths are generated with `Random(1660)` and range from
8–14; animate pitch as
`0.2 * sin(age * 0.3 + tentacle_index) + 0.4`. Reproduce the
charge squash/stretch from `jz.java` exactly. With interpolated charge
`q = max(0, lerp(previous_charge, charge, partial_tick) / 20)`, compute
`inv = 1 / (q^5 * 2 + 1)`, then scale Y by
`(8 + inv) / 2` and X/Z by `(8 + 1 / inv) / 2`. Lock at least the idle,
counter-10, and counter-20 poses in tests. Meshes and materials must be
shared; animation must not allocate per frame. Apply the established
mob LOD/collision policies.

### 8.3 Ghast fireball

Implement `az.java` as an ephemeral entity:

- one-block collision size;
- construct aim using Gaussian spread 0.4, normalize acceleration to
  0.1;
- integrate velocity and acceleration each tick;
- drag 0.95 in air and 0.8 in water;
- emit smoke each tick with bounded particle counts;
- ignore collision with the shooter for the first 25 ticks;
- on impact, apply the source direct-damage call (zero), create a
  power-1 explosion with fire enabled, then free the projectile;
- when attacked/deflected, take the attacker's look vector and reset
  acceleration to magnitude 0.1; keep the original shooter reference,
  because `az.java` does not transfer it to the deflector;
- render as the source camera-facing, 2×-scaled item-tile billboard
  from `gl.java`. The source tile is `dx.aB`, the snowball; reuse the
  existing `Items.SNOWBALL` icon instead of inventing a fire-charge
  texture. The projectile has no inventory/debug-spawner form;
- while in water, emit four bubble particles per tick before applying
  the 0.8 drag;
- do not persist fireballs across save, matching the absence of a
  source entity-registry entry.

Test shooter grace, wall/entity collision, explosion radius/power and
fire flag, deflection direction with unchanged shooter reference, drag,
and impact/dimension-unload cleanup. Do not add an arbitrary
time-to-live that is absent from `az.java`.

### 8.4 Natural spawning

The Hell biome source list is exactly ghast and zombie pigman, with no
passive list. Reproduce the Alpha hostile loop where it affects
observable distribution:

- collect the 17×17 eligible chunk area around each player;
- source hostile threshold is
  `100 * eligible_chunk_count / 256`; `bg.java` skips spawning only
  when the current hostile count is greater than this value, not when
  it is equal, so a successful group may overshoot it;
- keep the project's existing Overworld hostile cap at 70 unless a
  separate, measured correction is approved;
- each eligible chunk is considered only on the source one-in-50
  random gate;
- select one class for a candidate group;
- choose X/Z within the chunk and Y in 0–127;
- reject solid/fluid starting cells;
- perform the source three group passes and four attempts, with
  triangular X/Z spread from two `nextInt(6)` calls and the source's
  effectively zero Y jitter;
- reject locations within 24 blocks of a player or world spawn;
- apply entity-specific collision and spawn predicates;
- cap the group through the entity's source group-size method.

Keep spawning deterministic enough for controlled tests but do not
couple the simulation RNG to world-generation RNG. Difficulty Peaceful
must remove/prevent both hostiles. Avoid a global Overworld light gate
in the Nether.

## 9. Asset and presentation matrix

This is the acceptance contract for item/block icons and every other
presentation context. Every row must be verified. “N/A by design” is
an acceptance result, not missing implementation.

| Content | Pack/default asset | Debug spawner | Inventory/hotbar | Held in hand | Dropped | Placed/in world |
|---|---|---|---|---|---|---|
| Netherrack | terrain tile 103 plus default fallback | block list | baked block icon | FP and TP cube | spinning/bobbing block cube | opaque terrain block; correct sound/hardness; persistent fire support |
| Soul sand | tile 104 plus fallback | block list | baked block icon | FP and TP cube | block cube | 0.875 collision top and slowdown |
| Glowstone | tile 105 plus fallback | block list | baked block icon | FP and TP cube | block cube | emits 15; breaks to one dust |
| Glowstone dust | item tile 73 plus fallback | item list | sprite icon | FP and TP extruded sprite | item sprite/billboard and bob | N/A; used by 3×3 recipe |
| Portal | animated local texture/fallback | excluded | excluded | excluded | excluded | thin translucent animated surface, particles, sound, light 11, no collision/drop |
| Zombie pigman sword | existing golden-sword item asset | mob via F6 | existing behavior | existing player behavior | existing behavior | visibly held by mob |
| Ghast | normal and charged mob textures/fallbacks | F6 airborne mode | N/A | N/A | drops gunpowder | model, tentacles, charge deformation and texture swap |
| Ghast fireball | existing snowball item tile | excluded | excluded | excluded | excluded | 2× billboard, smoke/bubbles, collision, explosion |

Required asset-system work:

- map local Alpha atlas tiles into the `alpha_vanilla` pack;
- add the project's default `programmer_art` files and either provide
  `pixel_perfection` variants or verify its loader falls back to the
  default pack for every new semantic asset;
- add semantic pack paths under
  `assets/textures/packs/{pack}/blocks`,
  `.../items`, and `.../mobs` as expected by existing loaders;
- use `BlockIconRenderer` for block inventory icons and
  `SpriteExtruder` for glowstone dust/held item treatment;
- make `ItemIcons`, player-held routing, `DroppedItem`, and the debug
  item spawner use explicit registries, not numeric ranges;
- use `MobBase._resolve_pack_mob_path` for mob overrides;
- add default-pack fallback textures and sound assets;
- register portal trigger/travel/ambient, ghast, pigman, charge,
  fireball, fizz, and any missing impact events in
  `scripts/audio/sfx.gd`;
- provide silent-safe fallback if optional local Alpha audio is absent.

The implementation is incomplete if an item works only after a console
grant, appears as a placeholder in one view, or changes visual type
when dropped.

## 10. Target architecture and likely files

Names may follow local conventions, but keep responsibilities separate.

Likely new scripts:

- `scripts/world/dimension_context.gd` or
  `scripts/world/world_provider.gd`
- `scripts/world/worldgen_nether.gd`
- `scripts/world/worldgen_nether_caves.gd`
- `scripts/world/nether_population.gd`
- `scripts/world/nether_portal.gd`
- `scripts/world/nether_teleporter.gd`
- `scripts/entities/zombie_pigman.gd`
- `scripts/entities/ghast.gd`
- `scripts/entities/ghast_fireball.gd`
- `shaders/portal.gdshader`

Likely modified systems:

- `scripts/world/blocks.gd`, `scripts/world/items.gd`, atlas, icons,
  recipes, and block icon renderer;
- player interaction and FP/TP held item routing;
- dropped items and both debug spawners;
- fire, fluids, lighting, clock/compass, beds, respawn;
- `ChunkManager`, chunk views/meshing, world environment, sky dome,
  day/night driver, loading screen;
- region/player/entity save systems and block-entity/tick caches;
- mob registry, AI/render base, spawner managers, SFX registry;
- `src/worldgen_native.h/.cpp` after the reference generator passes.

Dimension ownership must be explicit for:

- chunk maps, region caches, dirty sets, worker queues/results;
- lighting queues and pending relights;
- scheduled block ticks;
- chest, furnace, sign, jukebox, and spawner state;
- active entities and serialized entity stores;
- population/decor completion records;
- portal index/cache;
- transient particles/audio and debug selections.

On transition, either clear these structures or key them by dimension.
Add assertions that catch accidental cross-dimension access in debug
builds.

## 11. Ordered implementation batches

### Batch 0 — Baseline, namespace runway, and source fixtures

Goal: make later Nether content safe without changing existing
gameplay.

Work:

- Record git status and preserve unrelated changes.
- Run the full tests, format/lint checks, native build, and existing
  performance probes. Save Overworld generation hashes for a fixed seed
  and coordinate matrix.
- Re-audit IDs 97–99, 205–206 and add documented reservations.
- Replace `id < 100` / `id >= 100` content-kind decisions with explicit
  registries throughout runtime and tests.
- Add invariants for uniqueness, byte range, AIR, item-form policy, and
  burned ID 50.
- Restore/recreate the local Alpha pack extractor and test it against
  the ignored client JAR without checking extracted assets into git.
- Create a local Java/source oracle that emits compact generated facts:
  voxel hashes, selected cells, feature counts, RNG checkpoints, and
  entity constants. Check in fixture output and provenance rather than
  source/JAR blobs.
- Establish fixture seeds `0`, `1`, `-1`, `12345`, and `987654321`,
  with positive, negative, origin, and seam-adjacent chunk coordinates.

Acceptance criteria:

- Every existing item/block behaves and renders exactly as before.
- ID 206 can be registered as a non-item block in a focused test
  without being classified as an item or truncated.
- Existing saves and inventory bytes load unchanged.
- Local extraction reports all required Alpha textures and never
  writes into a tracked raw-asset path.
- Fixture metadata records source version, class/method, coordinate
  layout, seed, and deterministic-population deviation.
- All baseline tests pass and Overworld fixture hashes are captured.

Required tests:

- `tests/test_content_registry.gd`
- expanded item placement/debug/held/drop registry tests
- save round-trip for IDs 0, 50, 99, 100, 205, 206, and 255 as raw
  byte values where the format permits
- extractor dry-run/path-safety test
- full existing suite and native build

Handoff evidence: ID table, affected range-assumption callsites,
baseline test count, Overworld hashes, extractor inventory, and fixture
manifest.

### Batch 1 — Dimension and persistence foundation

Goal: switch an empty/test provider between dimension 0 and -1 without
data leakage or save corruption.

Work:

- Introduce provider/context interfaces and move existing Overworld
  constants behind the default provider without behavior changes.
- Make chunk, region, entity, block-entity, scheduled-tick, lighting,
  and generation-job ownership dimension-aware.
- Add `DIM-1` paths while preserving all existing root paths.
- Version player save data and add current dimension with v1 migration.
- Add transition epochs, stale-result rejection, and a test-only
  dimension switch transaction.
- Peek player dimension/position before constructing the initial chunk
  ring.
- Implement source-save, unload, destination-load, failure rollback,
  and death-to-Overworld scaffolding.

Acceptance criteria:

- A v1 world opens in dimension 0 without rewritten chunk/entity data.
- Identical chunk coordinates in dimensions 0 and -1 store different
  bytes and cache entries.
- Switching dimensions repeatedly leaves only one resident chunk set.
- A delayed old-epoch worker result is rejected.
- Save/restart in dimension -1 restores that dimension and position;
  death returns to the correct Overworld respawn.
- Overworld generation, environment, saving, and entity persistence
  remain unchanged.

Required tests:

- `tests/test_dimension_context.gd`
- `tests/test_dimension_save_load.gd`
- v1→v2 player migration and corrupt/unknown-version handling
- region cache-key isolation and entity-file isolation
- scheduled tick/block-entity isolation
- stale worker result and rollback fault injection
- existing save/load, streaming, lighting, and worldgen suites

Handoff evidence: save tree before/after, migration bytes, memory/node
counts over ten switches, and rollback test output.

### Batch 2 — Blocks, item economy, assets, and complete presentation

Goal: add netherrack, soul sand, glowstone, and dust with every intended
representation, and establish the portal block's world-only registry
contract for Batch 7.

Work:

- Register the reserved IDs and source properties from section 4.
- Add the three inventory blocks to atlas/meshing, debug block list,
  icons, held cube path, dropped block path, placement, mining,
  save/load, and pickup.
- Add glowstone dust to item icons, debug item list, inventory/hotbar,
  held sprite extrusion, dropped item path, and recipe system.
- Implement glowstone's one-dust drop and nine-dust recipe.
- Implement soul-sand collision height/slowdown and persistent
  netherrack fire.
- Register portal as a world-only block and ensure every item-facing
  path excludes it. Prepare its texture input, but defer its custom
  mesh, animation, particles, and travel behavior to Batch 7.
- Finish local extraction mappings and default-pack fallbacks.

Acceptance criteria:

- Every applicable matrix cell for netherrack, soul sand, glowstone,
  and dust is correct; the portal's item/debug/held/drop cells are
  correctly excluded pending its Batch 7 world rendering.
- No placeholder/missing textures in either the default pack or local
  Alpha pack.
- Glowstone emits light 15, relights on placement/break at a chunk
  seam, and drops one dust.
- Nine dust crafts one glowstone; no four-dust recipe exists.
- Soul sand has a 0.875 top and multiplies horizontal motion by 0.4
  without changing vertical motion.
- Fire on netherrack persists through the normal extinguish path.
- Portal ID 206 survives chunk/save/network-free internal byte paths
  but is unobtainable as an item.

Required tests:

- `tests/test_nether_blocks.gd`
- `tests/test_nether_rendering.gd`
- recipe, drops, collision, fire, light, seam relight, save round-trip
- snapshot/structural tests for debug lists, inventory icon kind, FP/TP
  held kind, and dropped kind
- manual visual matrix in both packs

Handoff evidence: screenshots of each presentation context, recipe/drop
results, collision measurements, and asset-manifest diff.

### Batch 3 — GDScript base terrain, surfaces, and caves

Goal: produce source-oracle-compatible Nether chunks without
decorations.

Work:

- Implement `WorldgenNether` with exact Java RNG/noise construction,
  coarse density interpolation, lava sea, surface replacement, and
  bedrock.
- Port Nether caves with source-neighborhood ownership.
- Add explicit source-layout/project-layout conversion.
- Integrate the generator through the provider and worker path.
- Keep this path clear and unoptimized as the reference implementation.

Acceptance criteria:

- Reference fixtures match raw Alpha IDs before project-ID remapping,
  then match project bytes after remapping.
- Exact full-chunk hashes pass for the seed/coordinate fixture matrix.
- Selected density, bedrock, lava-level, surface-patch, negative
  coordinate, and cave cells match the independent oracle.
- Requesting chunks in reversed/random order yields identical bytes.
- No scene/resource access occurs on worker threads.
- Overworld hashes are byte-identical to Batch 0.

Required tests:

- `tests/test_nether_worldgen.gd`
- `tests/test_nether_worldgen_oracle.gd`
- density/RNG checkpoints and index-remap tests
- cave seam and lava-abort fixtures
- request-order permutation and repeated-run hashes
- worker-thread safety stress test

Handoff evidence: fixture pass table, representative vertical slices,
hash matrix, order permutation result, and generation timing baseline.

### Batch 4 — Population, decorations, and seam determinism

Goal: add all Alpha Nether decoration features without seams or
load-order dependence.

Work:

- Implement lava springs, fire clusters, both glowstone entry points,
  and both mushrooms in the exact source order.
- Reconstruct the per-source-chunk post-surface RNG state.
- Extend the source-chunk halo/merge pipeline for +8-offset features.
- Define deterministic collision/merge precedence if two sources write
  one cell; mirror existing project conventions and lock it in tests.

Acceptance criteria:

- Feature anchors, counts, selected coordinates, and final chunk hashes
  match canonical fixtures.
- Both glowstone generators perform 1,500 attempts and obey the
  exactly-one-neighbor rule.
- No decoration seam changes when neighboring chunks load later.
- Generating a region in row-major, reverse, spiral, and randomized
  order produces identical final bytes.
- Reloading persisted chunks does not re-run or duplicate population.
- Overworld generation remains byte-identical.

Required tests:

- population RNG/anchor fixtures
- per-feature predicate unit tests
- `tests/test_nether_population.gd`
- four load-order permutations across at least a 5×5 region
- negative-coordinate and four-way seam cases
- persisted decoration-complete round-trip

Handoff evidence: per-feature fixture report, seam diff report, order
hashes, and screenshots of representative glowstone/fire/mushrooms.

### Batch 5 — Native parity and generation performance

Goal: make Nether generation production-ready without changing its
reference output.

Work:

- Extend the native worldgen API with an explicit Nether entry point or
  dimension enum; do not overload ambiguous Overworld parameters.
- Port stages incrementally and compare after density, surface, caves,
  and population.
- Keep GDScript fallback functional for platforms without the
  extension.
- Profile before optimizing. Follow `.claude/optimizations.md` and
  avoid per-cell allocations or scene calls.

Acceptance criteria:

- Native and GDScript output are byte-for-byte identical for every
  fixture and order test.
- A build without the extension produces the same world through the
  fallback.
- Native Nether worker generation p95 is no more than 1.25× the
  existing native Overworld worker-generation p95 for the same sampled
  chunk count, unless a documented density-complexity baseline proves
  a different reviewed threshold is necessary.
- No existing generation/materialization metric regresses by more than
  10% across repeated comparable runs.
- No leaks or unbounded buffers appear during a 20×20 traversal.

Required tests:

- `tests/test_nether_worldgen_native.gd`
- all oracle, parity, seam, and order suites on both paths
- debug and release native builds on the current platform
- fallback run with native extension intentionally unavailable
- PerfProbe cold/warm samples with seed/route/hardware recorded

Handoff evidence: native/GDScript hash table, build logs, p50/p95/max
timings, allocations/memory trend, and Overworld comparison.

### Batch 6 — Nether environment, lighting, fluids, and item rules

Goal: make the dimension look and behave like Alpha's Nether.

Work:

- Disable sky/cloud/celestial/weather rendering through provider
  policy.
- Add fixed fog/background and no-skylight lighting behavior.
- Apply water-bucket evaporation, lava decay increment, compass/clock
  wandering, bed denial, and respawn behavior.
- Ensure glowstone, lava, fire, and portal emissive values relight
  correctly without a sky channel.
- Add particles/audio with pooling and limits.

Acceptance criteria:

- No sky/cloud/sun/moon/star/weather artifact appears from ground to
  roof or after dimension switching.
- Empty Nether darkness follows the 0.1 ambient-floor table; glowstone
  is 15 and portal is 11.
- Water never persists from a bucket; bucket state, fizz, and eight
  smoke particles are correct.
- A controlled flat test shows Nether lava advances one horizontal
  decay level per block while Overworld lava still advances two, with
  the same 30-tick update cadence.
- Compass and clock wander in Nether and immediately resume correct
  behavior after returning.
- Beds neither sleep, set spawn, nor explode.
- Ten repeated switches restore the exact Overworld environment each
  time.

Required tests:

- `tests/test_nether_environment.gd`
- no-skylight and emissive propagation/seam tests
- fluid cadence/decay snapshots
- water-bucket inventory/effect test
- clock/compass dimension-policy tests
- bed, death, and repeated-environment-switch tests
- manual visual checks at multiple graphics settings

Handoff evidence: before/after screenshots, light probes, fluid state
timeline, and environment node/material counts.

### Batch 7 — Portal rendering, activation, search, and round trip

Goal: provide safe, persistent two-way travel using Alpha portal rules.

Work:

- Implement exact frame validation, activation by fire, self-removal,
  world-only rendering, particles, sound, light, and player exposure.
- Implement coordinate scaling, search, construction fallback, optional
  validated index, and the Batch 1 transition transaction.
- Add loading and failure recovery behavior.

Acceptance criteria:

- Only the exact 4×5 footprint with its ten required obsidian blocks
  and 2×3 clear/fire interior activates; optional corner contents do
  not affect activation, and both axis orientations work.
- Invalidating any required frame block removes all connected portal
  cells without unrelated flood-fill damage.
- Portal has no collision, selection, item, drop, or debug-item entry.
- Continuous exposure travels at 80 ticks, leaving decays at 0.05/tick,
  and cooldown prevents immediate bounce-back for ten ticks.
- Positive and negative 8:1 coordinate round trips find or create safe
  portals using source bounds.
- Existing portals win by nearest squared 3D distance; stale index
  entries are rejected and raw search succeeds.
- Failure injection cannot duplicate the player, lose inventory, mix
  chunks, or strand a half-switched save.

Required tests:

- `tests/test_nether_portal.gd`
- `tests/test_nether_teleporter.gd`
- exhaustive frame cells/orientations and invalid-frame tests
- deterministic 32-frame texture hashes/cadence and seeded
  ambient-sound/particle display-tick tests
- exposure/cooldown timelines
- search tie, radius boundary, Y boundary, fallback platform, negative
  coordinate, stale-index, and blocked-site tests
- save/restart on each side and transition fault injection
- portal material/mesh resource-sharing assertion

Handoff evidence: round-trip coordinate log, search/create trace,
failure recovery results, and portal visual/audio capture.

### Batch 8 — Zombie pigman

Goal: add a fully persistent, Alpha-faithful neutral hostile.

Work:

- Register entity ID/name without colliding with project entities.
- Add model/texture, held golden sword, AI, combat, group aggro,
  fire immunity, drops, sound, save data, and F6 spawning.
- Add grounded species clearance to debug and cage spawning.

Acceptance criteria:

- All section 8.1 behavior and tests pass.
- The mob can be spawned from F6, saved/unloaded/reloaded, fought, and
  observed holding the sword at every LOD.
- One player hit alerts exactly the qualifying nearby group.
- Anger remains nonzero indefinitely and across restart.
- No passive/hostile Overworld behavior changes.

Required tests:

- `tests/test_zombie_pigman.gd`
- mob-registry and entity-save round-trip
- aggro boundary, permanent anger, target reacquisition, combat/drop,
  fire/lava, held-item pose, LOD, and debug-spawn clearance tests
- bounded multi-mob performance sample

Handoff evidence: save payload, aggro map, drop samples, render
screenshots, and performance counters.

### Batch 9 — Ghast and fireball

Goal: add the Alpha flying hostile and its complete projectile loop.

Work:

- Implement model, shared meshes/materials, flight, targeting, charge,
  texture/shape transition, sounds, drops, and debug airborne spawning.
- Implement fireball movement, collision, deflection, explosion, fire,
  visual, particles, and lifecycle.
- Add LOD and collision policies appropriate to a 4×4 flying mob.

Acceptance criteria:

- All sections 8.2 and 8.3 behavior passes deterministic tests.
- F6 finds valid open air and never embeds a ghast in roof/terrain.
- Charge/firing counters, line of sight, four-block launch offset, and
  -40 cooldown match fixtures.
- Fireballs ignore their shooter for 25 ticks, can be deflected without
  changing their stored shooter, make power-1 fiery explosions, and
  clean themselves up on impact or dimension unload.
- Peaceful removes ghasts; drops are only 0–2 gunpowder.
- A sustained projectile/mob scene has stable node, material, mesh,
  particle, audio-voice, and memory counts.

Required tests:

- `tests/test_ghast.gd`
- `tests/test_ghast_fireball.gd`
- model/tentacle deterministic structure and captured pose tests
- waypoint obstruction, range, LOS, charge timeline, launch vector,
  Peaceful, drops, shooter grace, impact, deflection, and cleanup
- F6 airborne/cage spawn tests and performance stress scene

Handoff evidence: charge timeline, pose images, collision traces,
resource-count graph, and projectile stress results.

### Batch 10 — Natural spawning, integration, playtest, and release gate

Goal: connect all systems, audit fidelity, and prove the feature is
ship-ready.

Work:

- Wire the natural hostile controller and Hell spawn table.
- Exercise chunk streaming, portals, saves, lighting, fluids,
  projectiles, deaths, and both mobs together.
- Add `docs/nether-playtest-guide.md` with short, reproducible tracks
  for every manual-only criterion.
- Run a final Alpha-source audit and list every intentional deviation.
- Profile representative travel and combat routes; fix measured
  regressions.

Acceptance criteria:

- Nether natural spawns contain only zombie pigmen and ghasts, follow
  the scaled source cap and species predicates, and stop on Peaceful.
- No passive mobs naturally spawn in the Nether.
- A new-world portal round trip, an existing-world migration round
  trip, and a save/restart on both sides preserve inventory, entities,
  blocks, portal destinations, and dimension.
- All presentation-matrix cells and playtest tracks pass in the default
  and local Alpha packs; selecting Pixel Perfection resolves every new
  asset through its own files or the documented fallback.
- Native and fallback generation stay fixture-identical.
- No chunk seams, stuck lighting, stale workers, duplicate entities,
  cross-dimension ticks, or portal-transition corruption appear in
  stress tests.
- Steady gameplay holds the project's frame budget; compared with the
  Batch 0 route, unexplained p95 frame-time regression is at most 10%.
- All tests, lint/format checks, native builds, asset-integrity checks,
  and docs pass.

Required tests:

- `tests/test_nether_spawning.gd`
- `tests/test_nether_integration.gd`
- `tests/test_nether_performance.gd`
- full test suite on native and GDScript-fallback paths
- 30-minute automated portal/stream/save/load soak
- manual `docs/nether-playtest-guide.md` completion
- clean-install/default-pack, local-Alpha-pack, and
  Pixel-Perfection-fallback smoke tests

Handoff evidence: final test count, full command logs, playtest report,
source/deviation checklist, staged-file asset audit, p50/p95/max frame
and generation timings, memory trend, and remaining known issues.

## 12. Test strategy and commands

### 12.1 Independent oracle policy

Never compare an implementation only with another translation of
itself. Generate expected facts from the ignored Alpha source/JAR in a
local harness:

- raw source block IDs before project remapping;
- chunk hashes plus selected coordinates;
- RNG state/checkpoints after constructor, surface, and population
  phases;
- feature anchor/count summaries;
- portal frame/search examples;
- mob counter/state timelines.

Checked-in fixture data must be small, factual, reproducible, and free
of source/assets. Store the Alpha version, decompiler caveat, harness
revision, seed, coordinates, byte order, and canonicalized population
rule with each fixture set.

### 12.2 Minimum worldgen matrix

Use seeds:

```text
0
1
-1
12345
987654321
```

For each, cover at least:

- chunks `(0,0)`, `(1,0)`, `(0,1)`, `(-1,0)`, `(0,-1)`,
  `(-1,-1)`;
- one positive and one negative distant coordinate;
- a 5×5 seam region;
- row-major, reverse, spiral, randomized, and concurrent request order;
- GDScript reference, native implementation, and native-unavailable
  fallback.

### 12.3 Automated test layers

| Layer | What it proves |
|---|---|
| Registry/unit | IDs, properties, recipes, drops, collision shapes, dimension policies, mob counters and predicates |
| Fixture/oracle | Source-faithful RNG, terrain bytes, caves, population, portal and entity state |
| Parity | GDScript/native and request-order equality |
| Integration | inventory/held/drop/place, lighting, fluids, saves, portals, entity lifecycle and spawning |
| Fault injection | stale workers, corrupt saves, failed portal creation/load, missing optional assets/native extension |
| Performance/soak | frame time, generation time, leaks, resource sharing, queue bounds and repeated transitions |
| Manual | appearance, animation, audio, controls, transition feel and large-world seams |

Use deterministic injected RNG and clocks for unit tests. Do not expose
test-only behavior in release paths; use dependency seams.

### 12.4 Standard commands

Run the repository's actual platform command if it differs, and record
the command used:

```sh
godot --headless --path . -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests/ -gexit
gdformat --check scripts/ tests/
gdlint scripts/ tests/
scons platform=macos target=template_debug
```

During development, focused tests are acceptable for iteration. Every
batch exit requires the full suite. Also launch the desktop build:

```sh
godot --path . main.tscn
```

### 12.5 Manual playtest coverage

The final playtest guide must include:

1. Obtain each allowed block/item from F4 and inspect inventory,
   hotbar, FP/TP held, dropped, pickup, and placed/use form.
2. Verify portal is absent from item UI and has no pick/drop.
3. Mine/craft/drop glowstone and dust; test netherrack fire and
   soul-sand height/slowdown with player and mobs.
4. Inspect terrain floor-to-roof, lava sea, caves, bedrock, all
   decorators, chunk seams, and negative coordinates.
5. Test water, lava reach, lighting, fog, missing sky, compass, clock,
   bed, death, and return to Overworld.
6. Build portals on both axes; test interrupted exposure, invalid
   frames, positive/negative scaling, blocked destinations, reuse,
   fallback creation, save/restart, and rapid attempted re-entry.
7. Spawn and naturally encounter both mobs; verify pigman group anger,
   ghast charge/fire/deflection, drops, Peaceful, save/load, and LOD.
8. Traverse long enough to stream/unload both dimensions and watch
   debug counters for stale work, node/resource growth, light queues,
   entity counts, and frame spikes.

## 13. Performance requirements

Measure before optimizing and compare on the same machine, build,
seed, route, view distance, and graphics settings.

- Capture Batch 0 warm Overworld p50/p95/max for worker generation,
  main-thread materialization, frame time, memory, nodes, materials,
  meshes, particles, audio voices, and active entities.
- GDScript is the clarity-first correctness reference. Native output
  must match it exactly.
- Do not allocate a `ShaderMaterial` per portal block/chunk or a unique
  mob mesh/material per entity.
- Pool/bound portal and fireball particles and cap simultaneous audio
  voices.
- Portal search is allowed behind the loading screen but must be
  bounded, instrumented, and must not leave both dimensions resident.
- A steady representative Nether scene should keep the project's
  normal frame budget. Any p95 regression over 10% from its comparable
  baseline needs a cause and fix or an explicitly reviewed waiver.
- Native Nether chunk generation uses the Batch 5 relative gate;
  absolute numbers are diagnostic because CI/developer hardware varies.
- Stress tests must show stable memory/resource counts after warm-up,
  not merely avoid a crash.

Do not reduce source spawn caps, view distance, feature attempts, cave
complexity, or portal radius silently to meet a performance target.
Use LOD, shared resources, spatial queries, bounded scheduling, and
native parity-preserving work first.

## 14. Risk register and required mitigations

| Risk | Consequence | Required mitigation |
|---|---|---|
| Numeric block/item classification | Portal 206 renders/behaves as an item; save corruption | Batch 0 explicit registries and exhaustive ID invariants |
| Cross-dimension cache key omission | Chunks/entities/ticks leak between worlds | Dimension keying, unload assertions, repeated-switch tests |
| Stale worker result | Overworld data appears in Nether or vice versa | Epoch + dimension tags and discard tests |
| Source/project index mismatch | Transposed/corrupt terrain | Named indexing helpers and selected-cell fixtures |
| Shared-RNG literal port | Load-order-dependent decorations | Canonical per-source post-surface RNG reconstruction |
| Cross-chunk decorators | Seams or later overwrites | Source ownership, halo/write lists, fixed merge order |
| Modern behavior creep | Wrong recipes, portals, lava, anger, drops | Source checklist and explicit out-of-scope list |
| Portal search cost | Long freeze or unsafe spawn | Bounded search, validated cache, loading UI, profiling |
| Per-entity resources | Ghast/portal performance collapse | Shared meshes/materials, LOD, resource-count tests |
| Natural spawner not wired | Mobs only appear through debug tool | Batch 10 integration test from normal gameplay tick |
| Debug ghast floor spawn | Ghast embeds in roof/terrain | Species-aware volume search |
| Save migration failure | Existing worlds become unloadable | Versioned additive migration and golden save fixtures |

## 15. Final release acceptance checklist

The Nether is complete only when all statements are true:

- [ ] Existing IDs and Alpha save bytes were not renumbered.
- [ ] Dimension 0 is regression-identical in worldgen and gameplay.
- [ ] Dimension -1 has isolated chunks, entities, ticks, caches, and
      persistence.
- [ ] Base terrain, surfaces, bedrock, caves, and every population
      feature pass independent fixtures and load-order tests.
- [ ] Native and GDScript output are byte-identical; fallback works.
- [ ] Netherrack, soul sand, glowstone, dust, and portal match section
      4.
- [ ] Every presentation-matrix row is verified in both asset packs.
- [ ] Portal validation, exposure, scaling, search, construction,
      rollback, and persistence pass.
- [ ] Nether lighting, fog, sky, water, lava, clock, compass, bed, and
      respawn rules pass.
- [ ] Zombie pigmen, ghasts, fireballs, debug spawning, and natural
      spawning match section 8.
- [ ] Full tests, format/lint, native build, soak, and playtest pass.
- [ ] Performance gates pass without reducing Alpha behavior.
- [ ] The complete texture/audio asset manifest passes in both packs.
- [ ] Every deliberate deviation and remaining known issue is written
      down.

## 16. Reference ledger

### 16.1 Repository guidance and engine references

- `CLAUDE.md` — architecture, storage, threading, testing, and native
  parity rules.
- `.claude/optimizations.md` — measured optimization and mob/resource
  constraints.
- `.claude/alpha-1.2.6-mapping.md` — obfuscated Alpha class map.
- `.claude/redstone-plan.md` and
  `docs/redstone-playtest-guide.md` — batch-gate and playtest
  documentation patterns.
- `scripts/world/worldgen.gd` and `src/worldgen_native.*` — existing
  deterministic reference/native generation pattern.
- `scripts/world/chunk_manager.gd` — streaming, worker, generation, and
  spawn integration point.
- `scripts/world/natural_mob_spawner.gd` and
  `scripts/world/passive_spawner.gd` — current spawning paths.
- `scripts/ui/debug_item_spawner.gd` and
  `scripts/ui/debug_mob_spawner.gd` — required debug access.
- `scripts/player/player.gd`, `scripts/player/interaction.gd`,
  `scripts/world/dropped_item.gd`, `scripts/ui/item_icons.gd`,
  and `scripts/ui/block_icon_renderer.gd` — presentation and
  interaction paths.

### 16.2 Local Alpha v1.2.6 source authority

The source is local, ignored reference material under
`vendor/alpha-1.2.6-src/src/`:

| Behavior | Source |
|---|---|
| Nether provider/environment | `om.java` |
| Nether terrain and population order | `kj.java` |
| Nether caves | `ju.java` |
| Lava spring, fire, glowstone decorators | `kf.java`, `pm.java`, `dt.java`, `lp.java` |
| Block registrations/properties | `nq.java` |
| Netherrack, soul sand, glowstone | `qb.java`, `it.java`, `hk.java` |
| Fire persistence and fluid rules | `qh.java`, `ja.java`, `ld.java` |
| Glowstone dust and recipe | `dx.java`, `en.java` |
| Portal block/frame | `x.java` |
| Player portal exposure and dimension call | `bq.java`, `net/minecraft/client/Minecraft.java` |
| Destination search/construction | `no.java` |
| Portal frame texture generation | `et.java` |
| Hell spawn lists and natural loop | `k.java`, `gy.java`, `bg.java` |
| Ghast/model/renderer | `am.java`, `hc.java`, `jz.java` |
| Ghast fireball/renderer | `az.java`, `gl.java` |
| Zombie pigman | `pt.java` |
| Entity registry | `fq.java` |
| Water bucket, compass, clock | `ag.java`, `gp.java`, `ae.java` |

Decompiled names can be imperfect. Verify any ambiguous expression
against callsites and generated fixtures before coding.

### 16.3 External historical cross-checks

- [Minecraft Wiki: The Nether](https://minecraft.wiki/w/The_Nether) —
  Nether content history, including the Alpha v1.2.0 addition and
  Alpha v1.2.2 lava change.
- [Minecraft Wiki: Java Edition Alpha v1.2.0](https://minecraft.wiki/w/Java_Edition_Alpha_v1.2.0)
  and [Alpha v1.2.2](https://minecraft.wiki/w/Java_Edition_Alpha_v1.2.2)
  — release chronology. Do not copy preview-only behavior.
- [Minecraft Wiki: Nether portal](https://minecraft.wiki/w/Nether_portal),
  [Ghast](https://minecraft.wiki/w/Ghast),
  [Zombified Piglin](https://minecraft.wiki/w/Zombified_Piglin),
  [Soul Sand](https://minecraft.wiki/w/Soul_Sand), and
  [Glowstone](https://minecraft.wiki/w/Glowstone) — secondary behavior
  cross-checks; use the local Alpha source for version-specific truth.
- [Minecraft Wiki: pre-flattening data values](https://minecraft.wiki/w/Java_Edition_pre-flattening_data_values)
  — historical fluid-level metadata cross-check.
- [Minecraft.net: Block of the Week — Netherrack](https://www.minecraft.net/en-us/article/block-week-netherrack)
  — official historical overview and persistent-fire description.
External pages were last consulted on 2026-08-16. They may describe
later behavior on their current pages, so every implementation constant
must trace back to the Alpha source or a version-specific history entry.

## 17. Batch findings log

Recorded as each batch lands. Findings that contradict earlier sections
are also corrected in place; this log is the chronological trail.

### 17.1 Batch 0 (2026-08-16)

**Confirmed against source.** `nq.java:110-113` registers the four
Nether world blocks exactly as section 4 describes — netherrack
`new qb(87, 103).c(0.4f)`, soul sand `new it(88, 104).c(0.5f)`,
glowstone `new hk(89, 105, hb.o).c(0.3f).a(1.0f)`, portal
`new x(90, 14).c(-1.0f).a(0.75f)`. `dx.java:101` gives glowstone dust
`new dx(92).a(73)` → item 348, sprite tile 73. `it.java` confirms the
0.125 collision inset (top at 0.875) and the `az *= 0.4 / aB *= 0.4`
horizontal-only slowdown. `en.java:32` confirms the nine-dust recipe as
a full 3×3. `kj.java:28-38` confirms the 16/16/8/4/4/10/16 constructor
order. Section 4's one addition: the portal's hardness is `-1.0f`, the
unbreakable sentinel.

**`JavaRandom.next_long()` was wrong, and both implementations shared the
bug.** OpenJDK's `nextLong` is `((long)next(32) << 32) + next(32)` with
*both* halves sign-extended, so a negative low word subtracts. Our
GDScript port and `src/worldgen_native.cpp` both treated the low word as
unsigned, running 2³² high whenever it was negative. The GDScript↔native
parity tests could never catch it because both sides were wrong
identically — precisely the failure mode §12.1's independent-oracle rule
exists to prevent. The new JDK-backed oracle caught it on its first run.

`next_long()` is now correct. **The Overworld cave generator is not.**
`worldgen_caves.gd` and the native cave path both call a new, explicitly
named `next_long_legacy_unsigned_low()`, because those two seed
multipliers determine every cave in every Overworld world this project
has generated; switching them would re-carve unvisited chunks of
existing saves into shapes that do not meet their already-persisted
neighbours. Overworld output is therefore byte-identical to the Batch 0
baseline, and the deviation is pinned by
`tests/test_java_random.gd::test_legacy_next_long_preserves_shipped_overworld_caves`.

> **Open decision for the operator.** Alpha-faithful Overworld caves
> require the corrected `nextLong` in both the GDScript and native cave
> paths, plus a regenerated Overworld baseline fixture and a story for
> existing saves (accept the seam, or version the generator). Nothing in
> the Nether depends on this — all new Nether code uses the corrected
> `next_long()`.

**`kj.java` is compilable for a real Batch 3 oracle.** Its dependency
closure is only eight classes: `aj`, `cy`, `dt`, `ha`, `kf`, `lp`, `pm`,
`pu`. `cy` (World) is the heavy one, but the density and surface stages
only store it, so a stub `cy` should let the whole provider compile and
run. That would upgrade Batch 3 from "reproduce the constructor order"
to "diff against the real generator". `bs`/`z`/`nf` already compile
standalone and the Batch 0 oracle runs them directly.

**`scons` can skip the link.** During Batch 0 the debug dylib reported
"is up to date" even after `src/worldgen_native.cpp` changed and its
`.os` was rebuilt. Deleting `bin/libmesher_native.macos.template_debug.universal.dylib`
forced a correct relink. Batch 5 must verify the dylib's mtime after
building, not just scons' exit code, or a native parity run can silently
test a stale library.

**Deferred from Batch 0 by design.** `JavaRandom` still has no
`next_gaussian`; the ghast fireball's 0.4 spread (§8.3) needs it, and the
JDK's cached-pair behaviour is easy to get wrong, so the expected values
are already captured in the oracle fixture for whichever batch adds it.

### 17.2 Batch 1 (2026-08-16)

**`CLAUDE.md` was wrong about autoloads.** It claims only `Game` is an
autoload; there are eleven (`Game`, `SFX`, `FurnaceManager`,
`ChestStorage`, `JukeboxStorage`, `NaturalMobSpawner`, `SignStorage`,
`JukeboxAudio`, `WorldTime`, `WaterFX`, `Music`). Five of them are
world-position-keyed tile-entity stores with no dimension component,
which is exactly why `_clear_dimension_owned_state` exists.

**One resident dimension, cleared rather than keyed.** §3.3 allows either
clearing dimension-owned structures or keying them by dimension. Clearing
won: with one resident dimension a keyed structure would only ever hold
one key, and the clear is the same operation world-load already
performed. `ChunkManager._ready` now calls the same helper the transition
does, so the two paths cannot drift.

**Tests can write to a real save slot without naming one.** Persistence
APIs default `world_name` to `""`, which `SaveLoad.resolve_world`
resolves to `Game.active_world` — a real slot. The transition
transaction legitimately saves the dimension it is leaving, so the new
tests overwrote the live `World1` `player.bin` and `entities.bin` and
left a stray `DIM-1/`. Region files were untouched; everything was
restored from a pre-run backup, and both new suites now redirect
`Game.active_world` to a throwaway name. Any future batch that tests a
saving path must do the same — passing explicit world names is not
enough when the production function under test uses the default.

**A deferred lambda that captures a Node breaks on teardown.**
`BlockFx.warm_pool` captured the ChunkManager and its particle emitter in
a `call_deferred` lambda. Godot raises "Lambda capture at index N was
freed" while BINDING the captures, so the `is_instance_valid` guard
inside the body never runs. Invisible in the game (the manager outlives
the frame) and a wall of errors in a suite that spins managers up and
down. Now captures `weakref`s. Note `weakref()` returns Variant, so it
needs an explicit `: WeakRef` annotation or the project's
warnings-as-errors setting rejects `:=`.

**The mesher's worker-arity guard earned its keep.**
`tests/test_mesher.gd::test_worker_entry_point_accepts_bound_complete_edge`
drives `_compute_chunk_data` through the real bound Callable precisely
because `WorkerThreadPool` resolves arity at call time. Adding the
dimension and epoch parameters tripped it, which is the failure mode it
was written for. It now also asserts the tags are published.

**New `class_name` scripts need an editor index pass.** The three new
classes did not resolve under `godot --headless -s gut_cmdln.gd` until
`godot --headless --editor --quit-after N` rebuilt
`.godot/global_script_class_cache.cfg`. `.godot/` is gitignored, so a
fresh clone or CI needs that pass before the suite will run.
