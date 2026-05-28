class_name Blocks
extends RefCounted

# gdlint: disable=max-file-lines
# Preload-based dispatch for MobSpawnerManager. class_name registration
# can race on first run (headless tests skip the editor scan that
# populates the class cache), so we resolve the script statically here.
const _MOB_SPAWNER_MGR: GDScript = preload("res://scripts/world/mob_spawner_manager.gd")
# Random-tick density per loaded chunk per game tick. Vanilla picks 3
# random cells per 16×16×16 chunk section per tick; our 16×128×16
# chunks have 8 vertical sections → 24 cells/chunk/tick at 20 Hz.
# Most cells fast-path bail in `is_random_tickable` so the actual
# handler fires <100 times/sec across all loaded chunks.
const _RANDOM_TICKS_PER_CHUNK: int = 24

# Simulation radius (in chunks, Chebyshev/square) around the player for
# the random-tick pass. Vanilla MC ticks growth/decay only within a
# simulation distance smaller than the render distance; chunks rendered
# but beyond this radius don't random-tick (grass spread, crop/sapling/
# cane growth, leaf decay, farmland dry-out, ice/snow melt all pause out
# there, resuming when the player approaches). At radius 5 that's an
# 11×11 = 121-chunk square — vs the ~465 loaded at render distance 8,
# roughly a 4× cut in per-tick work, which is the dominant main-thread
# cost (see PerfProbe "random_tick"). Scheduled ticks (fluids, falling
# blocks, redstone) are NOT gated by this — they stay global.
const _SIMULATION_RADIUS_CHUNKS: int = 5

# Block IDs (Uint8 0-255). IDs are stable — append to the end, never renumber.
# File length cap is intentionally lifted: this is the canonical block
# registry — IDs, hardness, drops, light opacity, atlas-face mapping, and
# break-time math all live here so adding a block touches one file. Splitting
# would just trade a single source-of-truth for indirection across N files.

const AIR := 0
const BEDROCK := 1
const STONE := 2
const DIRT := 3
const GRASS := 4
const COBBLESTONE := 5
const LOG := 6
const PLANKS := 7
const LEAVES := 8
const SAND := 9
const BRICK := 10
const OBSIDIAN := 11
const COAL_ORE := 12
const IRON_ORE := 13
const GOLD_ORE := 14
const DIAMOND_ORE := 15
const CRAFTING_TABLE := 16
# Vanilla "BlockSoil" — dirt tilled by a hoe. Drops dirt when broken.
const FARMLAND := 17
# Vanilla BlockGravel. Static for now (gravity / falling-block physics
# deferred — vanilla `tickAlways()` will land with the entity-tick system).
const GRAVEL := 18
# Vanilla BlockFurnace + BlockBurningFurnace. Two IDs because the lit /
# unlit state is a separate block in vanilla (toggled in-place when fuel
# starts/stops burning). Only FURNACE is craftable; LIT_FURNACE is set by
# the furnace tile-entity ticker.
const FURNACE := 19
const LIT_FURNACE := 20
# Vanilla BlockGlass — transparent (alpha-test) block from smelting sand.
# Treated as non-opaque so the chunk mesher culls neighbor faces against
# it the same way it does with air.
const GLASS := 21
# Vanilla BlockSapling — drops from leaves at 1/20 per
# BlockLeaves.dropNaturally. Renders as a non-cube cross-quad in vanilla;
# we currently render as a full alpha-tested cube (proper cross-mesh
# requires non-cube mesher path — same TODO as torches/slabs/stairs).
const SAPLING := 22
# Vanilla Alpha distinguishes two water block ids: BlockFlowing (id 8) and
# BlockStationary (id 9). Worldgen writes STILL when filling oceans;
# flowing spread lands with the BlockFlowing.java port in phase 6b. Our
# stable-append rule prevents matching vanilla's ids exactly — ids 8/9
# are already LEAVES/SAND here.
const WATER_FLOWING := 23
const WATER_STILL := 24
# Vanilla Alpha BlockFluids with material hb.g (ld.java:8 — shared class
# with water). Two IDs mirror vanilla's flowing/still split. Unbreakable,
# emits max block-light (15 per ld.java:168 `d() return 30` on the Alpha
# internal 0-30 scale, = 15 on our 0-15 scale). Worldgen caves fill the
# bottom of carves with LAVA_STILL below y=10 per lx.java:115-116.
const LAVA_FLOWING := 25
const LAVA_STILL := 26
# Vanilla Alpha BlockFire (qh.java, id 51). Placed by lava ignition on a
# flammable (LOG/PLANKS/LEAVES) neighbor. Stores age 0..15 in meta;
# scheduled ticks via BlockFire.update age the cell, probabilistically
# burn adjacent flammables to AIR, and extinguish when support is gone.
# Non-opaque, emits block-light 15 (qh.java:47 `d() return 10` on the
# 0-15 vanilla HUD scale, but internal is 30/30 = we use 15). Rendered
# as a cross-quad like SAPLING — vanilla uses 4 tilted quads but the
# CROSS mesh path already ships and reads clearly.
const FIRE := 27
# Vanilla Alpha BlockTorch (nq.aE, id 50). Emits block-light 14 (vanilla's
# `d() return 14`). Renders as a 2/16-thick × 10/16-tall pillar — for now
# floor-only (meta 0); wall variants (meta 1-4) land in the next pass.
# Hardness 0 = instant break. Drops itself via standard cube drops.
const TORCH := 28
# Vanilla Alpha BlockChest (c.java / nq.au, id 54). 27-slot container with
# an animated lid (cz.java::TileEntityChestRenderer). Hardness 2.5, axe-
# preferred per c.c(2.5f).a(e). Rendered as a separate ChestNode entity
# (so the lid can pivot for open/close) — the chunk mesher emits NO
# visual faces for CHEST cells, only collision. Block-meta 0..3 carries
# facing direction (0 = -Z, 1 = -X, 2 = +Z, 3 = +X), set on placement
# from the player's yaw.
const CHEST := 29
# Vanilla Alpha BlockFence (gd.java / nq.aZ, id 85). Uses the planks
# texture (vanilla terrain index 4 = `nq.aZ.bg`). Hardness 2.0, axe-
# preferred, material wood. Renders as a 6/16-wide post (always) +
# two horizontal rails at y=6-9/16 and y=12-15/16, each rail emitting
# arms toward neighbors that are also fences. Hitbox extends 0.5 above
# the cell (1.5 total height) so the player can't hop a single fence —
# vanilla gd.java:13 `arrayList.add(co.b(x, y, z, x+1, y+1.5, z+1))`.
# Alpha-specific: connects to FENCES ONLY (not solid blocks). Beta+
# extended this to all opaque cubes; we stay Alpha-faithful.
const FENCE := 30
# Vanilla Alpha BlockStairs (mb.java) — two variants: wood (nq.at, id 53)
# and cobblestone (nq.aH, id 67). Each stair renders as a bottom half-slab
# + an upper step (two boxes, orientation from meta 0..3). Inherits
# hardness/material from its parent block. Resistance = parent / 3 per
# mb.java:15. Non-opaque (mb.java:27 returns false).
const WOOD_STAIRS := 31
const COBBLESTONE_STAIRS := 32
# Vanilla Alpha BlockDoor (gv.java). Two block IDs per door type (wood id=64,
# iron id=71 in vanilla). Each door occupies two vertically adjacent cells;
# metadata encodes facing (bits 0-1), open state (bit 2), and upper/lower
# half (bit 3). Upper half drops AIR; lower drops the door item. Iron doors
# don't open by hand (require redstone, which we don't have yet).
const WOODEN_DOOR := 33
const IRON_DOOR := 34
# Vanilla Alpha BlockLadder (ca.java / nq.aF, id 65). Thin 2/16 slab
# mounted against one of 4 cardinal walls. Metadata 2..5 encodes facing
# (2=+Z, 3=-Z, 4=+X, 5=-X — same scheme as torch wall metas). Hardness
# 0.4, axe-preferred, wood material. Player climbing physics clamp fall
# speed and allow upward movement when overlapping the ladder cell.
const LADDER := 35
# Vanilla Alpha BlockTNT (v.java, id 46). Hardness 0 = instant break. Vanilla
# `a(Random) { return 0; }` (v.java:29-31) means the block drops nothing on
# any break path — Alpha TNT was strictly craft-only. We intentionally
# deviate to modern-MC behavior and drop the block on hand-mine so it's
# acquirable without first reaching a creeper-source for gunpowder (no mobs
# yet — see `drops()` fall-through). Right-click with flint and steel
# ignites: replace block with kr (EntityTNTPrimed), 80-tick fuse →
# explosion power 4 at the entity position. Faces use 3 distinct atlas
# tiles (top fuse plate, side TNT lettering, plain red bottom) extracted
# from the Alpha terrain.png at row 0 cols 8-10.
const TNT := 36
# Vanilla Alpha BlockFlowers (mr.java) — red poppy (nq.ad, id 37) and yellow
# dandelion (nq.ae, id 38). Cross-quad render like SAPLING. Hardness 0,
# light_opacity 0, valid plant support required (grass/dirt/farmland).
# Vanilla populate (px.java:388-399) places 2× poppy attempts/chunk always
# + 1× dandelion attempt at 1/2 probability.
const FLOWER_RED := 37
const FLOWER_YELLOW := 38
# Vanilla Alpha BlockMushroom (nq.af = brown, id 39; nq.ag = red, id 40).
# Same cross-quad shape as flowers; vanilla restricts to dim light + opaque
# block-below, but for the first decoration slice we treat them like flowers
# (grass/dirt support, no light gate). Vanilla populate gates them at 1/4
# (brown) and 1/8 (red) per chunk.
const MUSHROOM_BROWN := 39
const MUSHROOM_RED := 40
# Sugar cane (vanilla "reeds", introduced Alpha v1.0.4). Multi-block tall
# plant placed on grass/dirt/sand directly adjacent to water. Cross-quad
# mesh like flowers/mushrooms. Drops itself as ITEM (Items.SUGAR_CANE)
# when broken. Vanilla block ID is 83; ours is 41 because our IDs are
# sequential from 0 (see CLAUDE.md "block IDs are stable" note).
const SUGAR_CANE := 41
# Ice (vanilla BlockIce, id 79). Frozen water surface in cold biomes.
# Semi-transparent, slightly slippery. Drops nothing when broken (water
# flows back in vanilla). Worldgen converts WATER_STILL → ICE for
# surface cells in Tundra/Taiga/Ice Desert biomes.
const ICE := 42
# Snow block (vanilla BlockSnowBlock id 80). Full opaque white cube.
# Generated naturally on cold mountain peaks (Tundra/Taiga/Ice Desert
# at high altitude). Drops 4 snowballs in vanilla; we drop nothing for
# now since snowballs aren't an item yet.
const SNOW_BLOCK := 43
# Cactus (vanilla BlockCactus id 81). Multi-block tall plant in deserts.
# 14/16 width cube (gap on each side). Damages player on touch.
# Only places on SAND. Cannot have non-air blocks adjacent to its sides.
const CACTUS := 44
# Snow layer (vanilla BlockSnowLayer id 78). Thin 2/16-tall slab at the
# bottom of the cell; sits on top of grass/dirt/stone in cold biomes.
# Player walks through it (no collision) — vanilla treats it as a
# decoration block. Drops nothing for now (vanilla drops snowball,
# which we don't have).
const SNOW_LAYER := 45
# Pumpkin (Alpha 1.2.0 Halloween Update — `BlockPumpkin`, id 86 vanilla).
# 4-direction meta encodes which side carries the carved face (set at
# placement from player yaw). Hardness 1.0, axe is the preferred tool.
# Drops itself. Wearable in the helmet slot — when equipped, draws
# misc/pumpkinblur.png as a vignette HUD overlay (interaction.gd hook).
const PUMPKIN := 46
# Jack O'Lantern (Alpha 1.2.0 — `BlockPumpkinLantern`, id 91 vanilla).
# Identical to PUMPKIN except the face texture is `jack_o_lantern_face`
# (glowing eyes) and the block emits light level 15 (highest tier,
# alongside lava). Crafted from 1 pumpkin + 1 torch (shapeless).
const JACK_O_LANTERN := 47
# Bookshelf [BETA 1.3 exception] — added Feb 2011. Vanilla id 47;
# here id 48 to avoid collision with JACK_O_LANTERN. Faces: top + bottom
# are planks (4, 0); the 4 sides are bookshelf_side (3, 2 — slot
# reserved in Alpha terrain.png already). Hardness 1.5, axe preferred.
# Recipe: 6 planks + 3 books. Drops 3 books on break (vanilla
# BlockBookshelf.dropBlockAsItemWithChance). Ships pre-enchanting so
# the book item has a non-decorative purpose now.
const BOOKSHELF := 48
# Crops (wheat) — vanilla nq.az = BlockCrops, id 59. 8 growth stages
# stored in meta 0..7. Plantable on FARMLAND only; mature (meta=7)
# drops 1 wheat + 0..3 seeds, immature drops 1 seed. Random-ticked by
# TickScheduler — vanilla a(World, ...) at ld.java is the tick path;
# the tick rate matches sapling growth (~30s avg per stage on grass-
# like surfaces). Bonemeal advances to mature like saplings.
# We allocate id 49 because vanilla 59 is in our reserved 0..99 range
# but our existing IDs are densely packed up to 47; 49 keeps the
# growth/plant family contiguous.
const CROPS := 49
# Slot 50 intentionally LEFT BURNED. Briefly held a TALL_GRASS [Beta
# 1.6] block as a "natural seed source" exception, but tall grass
# doesn't exist in Alpha 1.2.6 — Mojang shipped it in Beta 1.6 to
# solve exactly the same gap. We chose strict Alpha fidelity:
# wheat seeds remain debug-spawn only (J menu), matching how Alpha-
# era players actually obtained them (creative-mode item spawn).
# Chunk saves from the brief tall-grass commits may persist id=50;
# the unknown-id default (AIR) silently strips those on load.
# Vanilla BlockMobSpawner (eb.java, id 52) — the mossy stone cage with
# a rotating mini-mob inside, found in dungeons. We use it as the
# primary debug tool for triggering mob spawns at a specific location
# during development. Single tile-entity stores which mob to spawn
# (see mob_spawner_manager.gd). Hardness 5.0, pickaxe-harvest, drops
# nothing on break (vanilla — keeps spawners non-renewable).
const MOB_SPAWNER := 51

# --- Alpha 1.2.6 solid blocks (Classic + Indev legacy). All full cubes,
# no special mesh; just per-face textures + tool/hardness/drop tables.
# Constructor args from vendor/alpha-1.2.6-src/src/nq.java.

# Wool — vanilla nq.ab (id 35). Indev "cloth" block. Vanilla stores 16
# color subtypes in cell meta on one block id; we ship 16 SEPARATE
# block IDs instead so the existing native-mesher per-id atlas lookup
# Just Works (per-meta cube textures would require a native-side
# rewrite). Alpha 1.2.6 terrain.png only had ONE wool tile (white at
# (0,4)); the other 15 colors are procedurally tinted from white at
# extract time using vanilla MC dye-color constants. Hardness 0.8.
# [BETA 1.2 exception applies for the colored variants — Alpha 1.2.6
# had the meta values but only a white texture; Beta 1.2 added dyes
# and the colored tile art.] Save format note: 16 ids burn 16 slots
# of our uint8 0..99 block-id space, but space is roomy + we treat
# wool as a series rather than 1 block w/ subtypes.
const WOOL_WHITE := 52
const WOOL_ORANGE := 53
const WOOL_MAGENTA := 54
const WOOL_LIGHT_BLUE := 55
const WOOL_YELLOW := 56
const WOOL_LIME := 57
const WOOL_PINK := 58
const WOOL_GRAY := 59
const WOOL_LIGHT_GRAY := 60
const WOOL_CYAN := 61
const WOOL_PURPLE := 62
const WOOL_BLUE := 63
const WOOL_BROWN := 64
const WOOL_GREEN := 65
const WOOL_RED := 66
const WOOL_BLACK := 67
# Sponge — vanilla nq.L (id 19). Classic-era yellow block. Originally
# absorbed water on placement (BlockSponge.a checks neighbor water
# cells and converts them to AIR); we'll wire that later when the
# absorb-on-place hook lands. Hardness 0.6.
const SPONGE := 68
# Iron block — vanilla nq.ai (id 42). 9 iron ingots in 3×3 to craft
# (Beta 1.0 recipe; Alpha 1.2.6 had no decompression recipe either
# direction so it's debug-spawn only here). Hardness 5.0, pickaxe-
# harvest, iron-tier required (matches vanilla resistance-to-blast).
const IRON_BLOCK := 69
# Gold block — vanilla nq.ah (id 41). Same as IRON_BLOCK but gold
# (3.0 hardness). Pickaxe-harvest, iron-tier required.
const GOLD_BLOCK := 70
# Diamond block — vanilla nq.ax (id 57). Same pattern. 5.0 hardness,
# pickaxe-harvest, iron-tier required.
const DIAMOND_BLOCK := 71
# Clay — vanilla nq.aW = lj(82, 72). Full cube, 0.6 hardness, drops 4
# clay balls (dx.aG = Items.CLAY_BALL). Generates underwater in lakes
# and ocean beaches via WorldGenClay (hy.java) — 10 attempts/chunk.
# Texture at terrain.png (8, 4). Material gravel → "gravel" SFX.
# Shovel-preferred. Smelt 1 clay_ball → 1 brick item.
const CLAY := 72
# Stone half-slab — vanilla nq.ak = qj(44, false). Half-height cube
# (bbox 0..1, 0..0.5, 0..1). Placed by clicking on a face; clicking
# on top of an existing half-slab converts it to a DOUBLE_SLAB and
# drops nothing. Vanilla qj.java::e() handles the combine; ours runs
# in interaction.gd::_try_place_slab. Hardness 2.0, pickaxe-preferred.
# Drops itself even when broken from a double-slab (vanilla
# qj.java::a returns nq.ak.bh).
const HALF_SLAB := 73
# Stone double-slab — vanilla nq.aj = qj(43, true). Full cube rendered
# with the slab side texture on the X/Z faces. Not normally placeable
# directly — formed by stacking two HALF_SLABs. Broken with a pickaxe
# drops 2 HALF_SLABs (vanilla — see drop_quantity).
const DOUBLE_SLAB := 74
# Sign — vanilla nq.aD = ni(63, qc.class, true) for the standing
# floor-post variant and nq.aI = ni(68, qc.class, false) for the wall-
# mounted variant. Both use TileEntitySign (qc.class) storing 4 lines
# × 15 chars of editable text. Material wood (`hb.e`), hardness 1.0,
# axe-preferred. Drops the sign ITEM (not the block) on break.
# Stage 1 ships the block ids + persistence + basic placement; stage 2
# adds the non-cube post/wall mesh + 3D text via SubViewport.
const SIGN_STANDING := 75
# Standing sign meta: 4 bits encode 16 yaw rotations (0..15 maps to
# 0°..337.5° in 22.5° increments — vanilla ni.java). Wall sign meta
# is only 0..3 (the 4 cardinal directions; see SIGN_WALL).
const SIGN_WALL := 76

# Beta 1.8 BlockFenceGate (vanilla v.java in Beta source; not present in
# Alpha 1.2.6 — adopted as a Beta-era exception alongside the worldgen /
# physics ports we already take from Beta). Two stacked vertical posts
# + two cross-rails between them, openable like a door. Meta bits:
#   0-1 = facing (0=+Z south, 1=-X west, 2=-Z north, 3=+X east)
#   2   = open flag (0=closed, 1=open)
#   3   = unused
# Closed: 1.5-tall hitbox so the player can't hop over (matches FENCE).
# Open: passable. Texture is planks on every face (vanilla v.java).
const FENCE_GATE := 77

# Vanilla Alpha 1.2.6 BlockMinecartTrack (qe.java). Flat 1-pixel rail
# on top of a solid support block — the minecart entity follows it.
# Meta encodes orientation (10 values, matching vanilla qd.java's
# direction lookup table):
#   0 = N-S straight (along Z)
#   1 = E-W straight (along X)
#   2 = ascending east  (climbing +X)
#   3 = ascending west  (climbing -X)
#   4 = ascending north (climbing -Z)
#   5 = ascending south (climbing +Z)
#   6 = curve N-E
#   7 = curve S-E
#   8 = curve S-W
#   9 = curve N-W
# Drop: 1 rail item (Items.RAIL). Auto-connect to neighbor rails
# happens at placement time — same family as FENCE's meta-aware
# connection logic.
const RAIL := 78
# Wooden slab + double-slab [BETA 1.3 exception] — vanilla nq.aT =
# qj(126, false) for the half-slab; the wood variant came in Beta with
# the planks-textured slab line. Same placement / combine semantics as
# the stone slab (HALF_SLAB / DOUBLE_SLAB): right-click on a face puts
# a half-slab in the neighbor cell; right-click on the TOP face of an
# existing wooden half-slab upgrades that cell to a wood double-slab.
# Material wood (axe-preferred, hand-breakable). Hardness 2.0 (planks).
# All 6 faces use the `planks` atlas slot — no dedicated wood-slab
# texture in Alpha terrain.png since the slab silhouette is conveyed
# by the half-height mesh, not a beveled side strip.
const WOOD_HALF_SLAB := 79
const WOOD_DOUBLE_SLAB := 80
# Cobblestone slab + double-slab [BETA 1.3 exception] — same family
# as the wood slab. Vanilla had stone, sandstone, cobblestone, wood,
# brick, and smooth-stone variants under qj.java with different
# textures + materials. Cobblestone variant: Material.stone,
# pickaxe-required to drop, hardness 2.0. All 6 faces use the
# `cobblestone` atlas slot.
const COBBLESTONE_HALF_SLAB := 81
const COBBLESTONE_DOUBLE_SLAB := 82
# Bed [BETA 1.3 exception] — vanilla bd.java BlockBed (item id 26 in
# Beta, drops Items.BED). Beds span TWO cells: a FOOT block at the
# player-clicked cell and a HEAD block one cell along the placer's
# facing. We split into TWO block IDs (BED_FOOT, BED_HEAD) so the
# mesher can pick per-half face textures without re-reading neighbors;
# vanilla uses ONE id with a meta bit 3 head flag, but our two-ID
# split keeps the mesher table-driven and matches our SIGN_STANDING /
# SIGN_WALL pair pattern.
#
# Meta layout for both halves:
#   bits 0-1 = facing the player faced when placing (0=+Z south,
#              1=-X west, 2=-Z north, 3=+X east) — same BlockDirectional
#              convention as fence-gate / chest / door.
#   bit 2..  = unused (vanilla's occupied flag is bit 2; we don't yet
#              render the "sleeping player" overlay, so it's reserved).
#
# Material wool/cloth: hardness 0.2 (vanilla `c(0.2f)`), no required
# tool, breakable by hand. Drops 1 Items.BED. Light passes through.
const BED_FOOT := 83
const BED_HEAD := 84
# Jukebox [BETA 1.4 exception] — vanilla BlockJukebox (id 84). Full
# cube, wood material, hardness 2.0, axe-preferred. Stores a single
# music disc (tile-entity dict at JukeboxStorage); right-click swaps
# the contained disc, LMB-break drops it along with the jukebox. No
# meta — orientation is fixed (top is always TOP, sides identical).
const JUKEBOX := 85
# Mossy cobblestone [BETA 1.0 exception — Beta promoted it from a
# dungeon-only worldgen variant to a craftable block, but Alpha
# 1.2.6 has it as a cobble texture variant already, placed by
# WorldGenDungeons (`cm.java`)]. Same material as COBBLESTONE
# (Material.stone, hardness 2.0, pickaxe-required, drops itself), just
# with the mossy texture. Currently only spawned by the dungeon
# worldgen pass; future Beta 1.0 recipe `cobblestone + vine` lands
# alongside vine.
const MOSSY_COBBLESTONE := 86

# Vanilla 1.8+ BlockSlime — NOT in Alpha 1.2.6 (added much later for
# redstone contraptions + fall-damage cushion). Bundled here as a
# modern-QoL deviation since the user explicitly asked for it
# alongside slimeball + slime mob. Render as a translucent green
# cube; no bounce / no fall-damage cushion mechanics yet (would need
# a `slow_landing` block-tag layer that the player physics reads).
const SLIME_BLOCK := 87

# Mesh shape selectors — used by the chunk mesher to pick the right
# vertex layout per block. Default CUBE is the hot path; non-cube
# shapes (CROSS, TORCH, SLAB, …) emit custom geometry. Adding a new
# shape: bump the enum, branch in mesher.gd._emit_block_faces, and
# (if the GDExtension is loaded) the C++ MesherNative — or list the
# shape in NON_CUBE_SHAPES so MesherNative defers it to the GDScript
# path while the cube fast-path stays native.
const MESH_SHAPE_CUBE: int = 0
const MESH_SHAPE_CROSS: int = 1  # two crossed quads, like sapling/grass-plant
const MESH_SHAPE_TORCH: int = 2  # small pillar centered in cell (floor torch)
# No visual emit from the chunk mesher; the block is rendered by an
# external entity (e.g. ChestNode for chests). Mesher still emits a
# full-cube collision soup so the player has solid ground / can't walk
# through. Adjacent opaque cubes treat this cell as opaque (face culling
# proceeds normally), so the entity covers the visual gap.
const MESH_SHAPE_EXTERNAL: int = 3
# Neighbor-aware fence post + rails. The mesher checks the 4 horizontal
# neighbors for same-id (fence-to-fence-only per Alpha gd.java:1199) and
# emits arms into the connected directions on top of an always-rendered
# 6/16 post. Collision soup includes the 1.5-tall hitbox so the player
# can't hop a single fence (gd.java:12-14). Custom selection bbox stays
# at full-cell-width-by-1.5-tall too, matching vanilla's selection.
const MESH_SHAPE_FENCE: int = 4
# Two-box stair step with 4 facing orientations (meta 0..3). Each
# orientation renders a full-width bottom half-slab + a half-width
# full-height upper step. Vanilla render type 10 (bk.java:1246-1263).
const MESH_SHAPE_STAIRS: int = 5
# Thin 3/16-block slab with 4 orientations × open/closed from metadata.
# Two-block tall: lower half renders the bottom texture, upper the top.
const MESH_SHAPE_DOOR: int = 6
# Flat 2/16-thick slab mounted against a wall face. 4 orientations via
# metadata (2..5), same as torch wall variants. Vanilla render type 8.
const MESH_SHAPE_LADDER: int = 7
# Thin 2/16-tall slab on the floor — used by snow_layer. Bottom face
# hugs the supporting block below; top face + 4 sides at y=2/16.
const MESH_SHAPE_SNOW_LAYER: int = 8
# Vanilla Alpha BlockFire render type 3 (bk.java::d). Two leaning vertical
# planes if the cell below is opaque (X-cross with tops offset 0.2 inward),
# or wall-hugging quads against each opaque/flammable side neighbor when
# the floor is non-solid. All quads use the same animated fire atlas tile
# (chunk shader does time-based UV strip lookup), so no extra material.
const MESH_SHAPE_FIRE: int = 9
# Half-slab — bottom-half cube (bbox 0..1, 0..0.5, 0..1). Emits 6
# faces like a normal cube but the top face is at y=0.5 and the 4
# side faces only span the bottom half. Vanilla qj.java::a(true) sets
# bbox via Block.a(0,0,0,1,0.5,1).
const MESH_SHAPE_SLAB: int = 10
# Sign — stage 1 ships as a thin vertical post in the cell center
# (placeholder). Stage 2 replaces with the full post + flat-panel mesh
# and routes the panel face through the tile-entity text texture.
const MESH_SHAPE_SIGN: int = 11
# Beta 1.8 fence gate — 2 posts + 2 cross-rails when closed; rails hide
# (rotate parallel to the posts) when open. Meta-aware orientation +
# open/closed state. Same family as the door but with collision toggling
# rather than two stacked halves.
const MESH_SHAPE_FENCE_GATE: int = 12
# Rail — a flat 1-pixel quad on top of a supporting solid block.
# Texture rotates/swaps based on meta orientation. No collision (player
# walks straight over rails); only the minecart entity reads the meta.
const MESH_SHAPE_RAIL: int = 13
# Beta 1.3 bed — 9/16 block tall, two-cell pair (foot + head). Each
# half builds its own mesh with FOOT or HEAD face textures depending
# on the block id (BED_FOOT vs BED_HEAD). Meta 0-1 selects facing for
# both halves (matched by placement code) so the bed mesher can yaw
# the local quads to align with the placer's direction without
# reading neighbors.
const MESH_SHAPE_BED: int = 14

# Lazy-init lookup table for light_opacity (built on first access).
# Direct PackedByteArray index is significantly faster than a multi-arm
# match in GDScript — called ~30K times per worldgen chunk + ~30K times
# per lighting BFS pass.
static var _light_opacity_lut: PackedByteArray
# Lazy-init explosion-resistance LUT (PackedFloat32Array of 256 entries).
# explosion_resistance() is called once per non-AIR cell per ray step in
# an explosion (~5000+ calls per TNT detonation). The match statement
# version is ~10× slower than a direct array index, and the BFS-shaped
# explosion ray-cast is the hot path during chained TNT cascades.
static var _resistance_lut: PackedFloat32Array


# Dispatch a scheduled block-tick fired by `TickScheduler`. `manager` is
# the ChunkManager (typed Node to avoid a hard import — static classes
# can't reference autoloads directly). `pos` is world coords. `block_id`
# is the id scheduled when the tick was enqueued — checking it against
# the current block at `pos` is the caller's job (the cell may have been
# broken mid-delay, in which case the tick is a no-op).
#
# Stub handler — Flow #3 adds the BlockFlowing / BlockLava branches here.
# For now the tick fires but does nothing; tests exercise the scheduler
# mechanism without any side effects.
static func on_scheduled_tick(manager, pos: Vector3i, block_id: int) -> void:
	# Cell may have been modified since the tick was scheduled (player
	# edit, flow conversion, etc.). Drop the tick if so — vanilla's
	# BlockFlowing.b() makes the same check before acting.
	var current_id: int = manager.get_world_block(pos)
	if current_id != block_id:
		return
	# Flow #3 — fluid tick dispatch. BlockFluids owns the spread algorithm
	# (ja.java port); we dispatch flowing water and flowing lava into it.
	# STILL variants don't tick in vanilla — they only re-check on a
	# neighbor change via BlockFluids.on_neighbor_changed.
	if block_id == WATER_FLOWING or block_id == LAVA_FLOWING:
		BlockFluids.update(manager, pos, block_id)
	elif block_id == FIRE:
		BlockFire.update(manager, pos)
	elif block_id == CROPS:
		_tick_crops(manager, pos)
	elif block_id == MOB_SPAWNER:
		# Preload-based dispatch dodges the class_name registry race —
		# new files aren't in the cache until the editor scans them,
		# and headless test runs skip that scan.
		_MOB_SPAWNER_MGR.on_tick(manager, pos)


# --- Random-tick subsystem (vanilla `cy.java::a(...)` per-tick sweep) ---
#
# Vanilla picks 3 random cells per 16³ chunk section per game tick and
# fires `updateTick` on whatever block is at each cell. Most blocks
# don't override updateTick — for those, the lookup is a cheap branch
# that exits immediately. Random-tickable blocks (grass spread/decay,
# leaf decay, crop growth, ice melt, fire spread, etc.) drive most of
# the world's "passive ambient change" mechanics.
#
# Our chunks are 16×128×16 (no section split — 8 vertical 16-cube
# sections worth). To match vanilla density we fire 24 random ticks
# per chunk per game tick (8 sections × 3). Driver runs from
# `TickScheduler.advance` so it stays on the 20 Hz vanilla cadence
# and pauses correctly on frame hitches.
#
# Perf budget (typical 5×5 = 25 loaded chunks × 24 random ticks × 20
# Hz): 12,000 cell lookups/sec. ~99% hit the `is_random_tickable`
# fast-path bail (non-grass = non-tickable), so the actual handler
# fires <100 times/sec. Set_world_block writes dominate when grass
# IS spreading; batch via `manager.begin_batch` / `end_batch` is a
# future optimization if profiling shows it.


# Quick-gate for the random-tick pass. Most cells aren't random-
# tickable so this check is the dominant cost — keep it a single
# branch on the block id. Add new entries here as blocks gain random-
# tick behavior (leaves decay, crops, ice melt, fire spread, …).
static func is_random_tickable(id: int) -> bool:
	return id == GRASS


# Driver — iterate every loaded chunk and fire N random cells. Called
# once per game tick from `TickScheduler.advance`. `manager` is the
# ChunkManager (autoload-free typed Node).
static func run_random_tick_pass(manager) -> void:
	# Defensive: TickScheduler tests pass a minimal fake manager that
	# doesn't implement `iter_loaded_chunks`. Skip the random-tick pass
	# in that case so scheduled-tick tests can drive `advance()` without
	# needing to mock the full ChunkManager surface.
	if not manager.has_method("iter_loaded_chunks"):
		return
	var probe_token := PerfProbe.begin("random_tick")
	# Iterate the loaded-chunks dict directly. Chunks are keyed by
	# Vector2i(cx, cz); the Chunk's `blocks` PackedByteArray lets us
	# skip the manager.get_world_block dict-lookup overhead for the
	# hot fast-path branch (most cells are non-tickable).
	var chunks: Dictionary = manager.iter_loaded_chunks()
	# Simulation-distance gate. Skip chunks outside _SIMULATION_RADIUS_CHUNKS
	# of the player (Chebyshev distance, matching the square chunk ring).
	# Guarded by has_method so the TickScheduler test's minimal fake manager
	# — which reaches here only if it stubs iter_loaded_chunks — still ticks
	# every chunk it provides instead of crashing on a missing accessor.
	var has_center: bool = manager.has_method("get_player_chunk_coord")
	var center: Vector2i = manager.get_player_chunk_coord() if has_center else Vector2i.ZERO
	for coord: Vector2i in chunks:
		if (
			has_center
			and (
				absi(coord.x - center.x) > _SIMULATION_RADIUS_CHUNKS
				or absi(coord.y - center.y) > _SIMULATION_RADIUS_CHUNKS
			)
		):
			continue
		var chunk: Chunk = manager.get_chunk_at_coord(coord)
		if chunk == null:
			continue
		var base_x: int = coord.x * Chunk.SIZE_X
		var base_z: int = coord.y * Chunk.SIZE_Z
		for _i in range(_RANDOM_TICKS_PER_CHUNK):
			var lx: int = randi() % Chunk.SIZE_X
			var ly: int = randi() % Chunk.SIZE_Y
			var lz: int = randi() % Chunk.SIZE_Z
			var id: int = chunk.get_block(lx, ly, lz)
			if not is_random_tickable(id):
				continue
			on_random_tick(manager, Vector3i(base_x + lx, ly, base_z + lz), id)
	PerfProbe.end("random_tick", probe_token)


# Per-block random-tick dispatch. Mirrors `on_scheduled_tick` —
# branch on id, call species-specific handler. Empty fallthrough for
# unknown ids is a no-op (defensive against id mismatch between the
# `is_random_tickable` filter and this dispatch).
static func on_random_tick(manager, pos: Vector3i, block_id: int) -> void:
	if block_id == GRASS:
		_tick_grass(manager, pos)


# Vanilla `os.java::a()` (BlockGrass.updateTick) port:
#
#   if (world.getLightValue(x, y+1, z) < 4
#       && world.getBlock(x, y+1, z).material.blocksMovement()) {
#       if (random.nextInt(4) != 0) return;   // 1/4 chance per tick
#       world.setBlock(x, y, z, DIRT);
#   } else if (world.getLightValue(x, y+1, z) >= 9) {
#       int n7 = x + random.nextInt(3) - 1;        // -1..+1
#       int n6 = y + random.nextInt(5) - 3;        // -3..+1
#       int n5 = z + random.nextInt(3) - 1;
#       if (world.getBlock(n7, n6, n5) == DIRT
#           && world.getLightValue(n7, n6+1, n5) >= 4
#           && !world.getBlock(n7, n6+1, n5).material.blocksMovement()) {
#           world.setBlock(n7, n6, n5, GRASS);
#       }
#   }
#
# Two key vanilla quirks:
#   * Decay only fires when light above < 4 AND the block above is
#     opaque (`material.blocksMovement()` — equiv to our `is_opaque`).
#     Open grass under air with dim sky DOESN'T decay; only covered
#     grass does.
#   * Spread requires SOURCE light ≥ 9 (the grass itself must be well-
#     lit) AND target light ≥ 4 (the dirt's above-cell). The 9 vs 4
#     asymmetry is intentional — grass only "actively" spreads from
#     well-lit cells, but accepts low-light neighbors.
static func _tick_grass(manager, pos: Vector3i) -> void:
	var above: Vector3i = pos + Vector3i(0, 1, 0)
	# `manager.get_world_block_light` returns the COMBINED max of sky
	# + block light at the cell — same as vanilla `cy.j(...)`.
	var above_light: int = maxi(
		manager.get_world_sky_light(above), manager.get_world_block_light(above)
	)
	var above_id: int = manager.get_world_block(above)
	# Decay path — dim AND covered.
	if above_light < 4 and is_opaque(above_id):
		if randi() % 4 != 0:
			return
		manager.set_world_block(pos, DIRT)
		return
	# Spread path — well-lit source. Vanilla compares >= 9 on the source's
	# above-cell. Skip the spread sample if grass is under-lit (saves the
	# random + 4 block-lookups per call).
	if above_light < 9:
		return
	var n_x: int = pos.x + (randi() % 3 - 1)
	var n_y: int = pos.y + (randi() % 5 - 3)
	var n_z: int = pos.z + (randi() % 3 - 1)
	var target := Vector3i(n_x, n_y, n_z)
	if target == pos:
		return
	if manager.get_world_block(target) != DIRT:
		return
	var target_above: Vector3i = target + Vector3i(0, 1, 0)
	var target_above_light: int = maxi(
		manager.get_world_sky_light(target_above), manager.get_world_block_light(target_above)
	)
	if target_above_light < 4:
		return
	if is_opaque(manager.get_world_block(target_above)):
		return
	manager.set_world_block(target, GRASS)


# Crops growth tick. Advances meta by 1 each fire if conditions hold,
# then reschedules itself for the next stage. Vanilla BlockCrops.b
# checks light level (>= 9 in older versions; relaxed in Alpha — any
# sky-exposed cell works) and hydration. We mirror the relaxed Alpha
# behavior: any sky-lit cell over farmland grows, with a 200-tick
# interval (~10s) per stage. Mature (meta=7) stops rescheduling.
static func _tick_crops(manager, pos: Vector3i) -> void:
	var support_id: int = manager.get_world_block(pos + Vector3i(0, -1, 0))
	if support_id != FARMLAND:
		# Farmland turned back into dirt under the crop — break crop.
		manager.set_world_block(pos, AIR)
		return
	var meta: int = manager.get_world_block_meta(pos)
	if meta >= 7:
		return  # mature; no more growth ticks
	manager.set_world_block(pos, CROPS, meta + 1)
	# Reschedule. Random ±50% jitter so multiple crops planted at once
	# don't all mature on the same tick (visual variety + spreads the
	# remesh cost).
	var jitter: int = 100 + randi() % 200  # [100, 300] ticks
	TickScheduler.schedule(pos, CROPS, jitter)


# Blocks with full-cell physical collision: a mob can't walk INTO the
# cell, fluid can't flow INTO the cell, and the top face is a valid
# place to stand. Distinct from `is_opaque` (a rendering concept).
# Covers cases like CHEST and MOB_SPAWNER which are non-opaque for
# face-culling reasons but physically solid — without this distinction,
# water flow overwrites mob spawners, the pathfinder lets mobs walk
# THROUGH chests, and players can safespot mobs by standing on a chest.
# LEAVES / GLASS / ICE / CACTUS render with alpha-test (`is_opaque`
# false) but have full cube collision in vanilla.
static func is_solid_collision(id: int) -> bool:
	if is_opaque(id):
		return true
	return (
		id == CHEST
		or id == MOB_SPAWNER
		or id == LEAVES
		or id == GLASS
		or id == ICE
		or id == CACTUS
		or id == HALF_SLAB
		or id == WOOD_HALF_SLAB
		or id == COBBLESTONE_HALF_SLAB
		or id == WOOD_STAIRS
		or id == COBBLESTONE_STAIRS
		or id == WOODEN_DOOR
		or id == IRON_DOOR
		or id == FENCE
		or id == FENCE_GATE
		or id == SLIME_BLOCK
	)


static func is_opaque(id: int) -> bool:
	# LEAVES + GLASS + SAPLING render with alpha-test (discard in
	# chunk.gdshader); treating any as opaque would cull the stone/dirt
	# faces behind them and the shader discard would then punch straight
	# through to the world background. Mesher pairs this with a "same-id
	# cull" so adjacent leaves/glass don't emit shared internal faces.
	# Water is also non-opaque so terrain faces behind it stay visible
	# when we add the translucent water material in a later step.
	return (
		id != AIR
		and id != LEAVES
		and id != GLASS
		and id != ICE
		and id != CACTUS
		and id != SNOW_LAYER
		and id != SAPLING
		and id != WATER_FLOWING
		and id != WATER_STILL
		and id != LAVA_FLOWING
		and id != LAVA_STILL
		and id != FIRE
		and id != TORCH
		# Vanilla c.java BlockChest is a tile-entity that doesn't fill its
		# cell — the body is inset 1/16 on each XZ side, so neighbors
		# (especially the cell below) MUST keep emitting their faces or
		# the player sees through the chest's bottom inset to the sky.
		# Mirrors how Glass / Leaves opt out for the same shader-driven
		# reason.
		and id != CHEST
		# Fence renders as a thin post + rails (6/16 wide, with 1.5-tall
		# hitbox); neighboring cubes must keep emitting their faces so the
		# air around the post shows the world behind. Vanilla gd.a()
		# returns false for the same reason.
		and id != FENCE
		# Slime block is translucent — the chunk shader's alpha-test on
		# slime_block pixels would otherwise be hidden behind a culled
		# adjacent face. Same treatment as GLASS / LEAVES.
		and id != SLIME_BLOCK
		and id != WOOD_STAIRS
		and id != COBBLESTONE_STAIRS
		and id != WOODEN_DOOR
		and id != IRON_DOOR
		and id != LADDER
		# Fence gate is non-cube (2 posts + cross-rails); neighbour faces
		# must keep rendering through it.
		and id != FENCE_GATE
		# Flowers + mushrooms render as cross-quads like saplings — opaque
		# treatment would cull the dirt/grass face below them, leaving a
		# punch-through hole when the cross shader discards the corners.
		and id != FLOWER_RED
		and id != FLOWER_YELLOW
		and id != MUSHROOM_BROWN
		and id != MUSHROOM_RED
		and id != SUGAR_CANE
		# CROPS renders as a cross-quad (same reason as the flower
		# family above). Neighbor cubes must keep emitting their faces
		# or the cross-shader's discard punches a hole through to the
		# world background.
		and id != CROPS
		# HALF_SLAB exposes the upper half-cell — neighbor cubes need
		# to keep emitting their faces against the open half, else
		# the visible side-of-slab area shows the void. Same reason
		# as snow_layer. Wood + cobblestone half-slabs use the same
		# half-height mesh and need the same treatment.
		and id != HALF_SLAB
		and id != WOOD_HALF_SLAB
		and id != COBBLESTONE_HALF_SLAB
		# Signs are non-cube — neighbor cubes must keep their faces.
		and id != SIGN_STANDING
		and id != SIGN_WALL
		# Mob spawner is a sparse cage — vanilla eb.java::isOpaqueCube
		# returns false. Treating it as opaque hides the floor face
		# beneath it (and the cage's own bottom face), so the spawner
		# looks like a 5-faced block floating with no floor. Marking it
		# non-opaque lets the grass/dirt below emit its TOP face right
		# at the spawner's base.
		and id != MOB_SPAWNER
		# Rail is a flat 1-pixel quad on top of the supporting block.
		# Neighbor cubes (especially the support below) must keep
		# emitting their faces, since the rail doesn't fill its cell.
		and id != RAIL
		# Bed halves are 9/16 tall and leave the top 7/16 of their cells
		# open — adjacent cubes must keep emitting faces facing into the
		# bed cell so the air above the bed stays visible / lightable.
		and id != BED_FOOT
		and id != BED_HEAD
	)


# True if fire will consume this block — PLANKS, LOG, LEAVES, TNT per
# vanilla BlockFire.setBurnProperties (qh.java:13-18). TNT's burn rate
# matches wool's 30/60 in vanilla; ignition by adjacent fire calls the
# same flint-and-steel branch (auto-prime via BlockTNT.onBlockBurnt).
static func is_flammable(id: int) -> bool:
	return id == LOG or id == PLANKS or id == LEAVES or id == TNT


# True for either water variant. Used by mesher (skip meshing until the
# water shader lands), player physics (swim detection, later step), and
# worldgen (beach placement is adjacency-driven off the same test).
static func is_water(id: int) -> bool:
	return id == WATER_FLOWING or id == WATER_STILL


# True for either lava variant. Vanilla's BlockFluids with material hb.g
# (ld.java) — shares most logic with water but damages entities on contact
# and emits light. Worldgen uses it for cave-floor lava pools (lx.java:115).
static func is_lava(id: int) -> bool:
	return id == LAVA_FLOWING or id == LAVA_STILL


# True for any BlockFluids variant (water + lava). Handy for entity physics
# (swimming / fluid-drag paths) and mesher (variable-height fluid surface).
static func is_fluid(id: int) -> bool:
	return is_water(id) or is_lava(id)


# Vanilla BlockGravel + BlockSand inherit BlockFalling, which schedules
# a fall-tick whenever a neighbor changes. ChunkManager calls this after
# any block becomes AIR to settle anything sitting unsupported above.
static func has_gravity(id: int) -> bool:
	return id == SAND or id == GRAVEL


# Vanilla BlockPlant.a(Block) — what the plant accepts as a support block
# directly below it. Same set used by saplings, flowers, tall grass, etc.
# Bukkit/mc-dev BlockPlant.java: `block == GRASS || block == DIRT || block
# == SOIL` (SOIL == FARMLAND). When the cell below changes to anything
# else, ChunkManager drops the plant and spawns a DroppedItem.
static func is_valid_plant_support(id: int) -> bool:
	return id == GRASS or id == DIRT or id == FARMLAND


# Vanilla Block.isReplaceable(world,x,y,z) — true for cells the player
# can place INTO (the new block overwrites the old one). Plants and
# water are replaceable in vanilla; we currently only enable it for
# plants — placing into water needs the bucket / fluid-displacement
# system, which doesn't exist yet, so leaving water non-replaceable
# avoids dropping phantom water "items" via the displacement path.
static func is_replaceable(id: int) -> bool:
	# Vanilla BlockFluid.isBlockReplaceable returns true — placing into
	# water/lava overwrites the fluid cell (Alpha lets you destroy source
	# blocks this way too; bucket displacement came in 1.4). Lava is
	# included now that HP/damage shipped in Phase 5+ — the hazard is
	# real, so the gameplay loop "place dirt to bridge a lava pool" is
	# meaningful rather than a trivial safe-out.
	return (
		id == AIR
		or id == SAPLING
		or id == WATER_FLOWING
		or id == WATER_STILL
		or id == LAVA_FLOWING
		or id == LAVA_STILL
		or id == FIRE
		or id == FLOWER_RED
		or id == FLOWER_YELLOW
		or id == MUSHROOM_BROWN
		or id == MUSHROOM_RED
		or id == SUGAR_CANE
		or id == CROPS
		# Vanilla ji.java (BlockSnow) overrides isBlockReplaceable to
		# return true — placing a block onto a snow-layer cell stomps
		# the snow flat and stacks the new block in its place rather
		# than floating above it. Same behavior as tall grass / saplings.
		or id == SNOW_LAYER
	)


# Vanilla `Block.lightOpacity` — how much sky/block light this block
# subtracts when light passes through. 0 = fully transparent (air, glass,
# sapling), 1 = leaves (vanilla BlockLeaves uses 1), 3 = water (Bukkit/mc-dev
# Block.p(): BlockFlowing/BlockStationary call `.g(3)` to set this), 15 =
# fully opaque (cuts light to 0). Used by Lighting._column_pass and
# _lateral_pass — consult those for the propagation rule.
#
# LUT declaration lives at the top of the file (next to MESH_SHAPE_*) to
# satisfy gdlint's class-definitions-order rule. Build/access below.
static func _build_light_opacity_lut() -> void:
	_light_opacity_lut = PackedByteArray()
	_light_opacity_lut.resize(256)
	# Default 15 (fully opaque) for every id. Then patch the transparent
	# / partially-transparent ones — easier to maintain than a 256-entry
	# constant where most entries say "15".
	for i in range(256):
		_light_opacity_lut[i] = 15
	_light_opacity_lut[AIR] = 0
	_light_opacity_lut[GLASS] = 0
	# Ice — semi-transparent like glass; vanilla BlockIce returns 3 from
	# getOpacity (slight light dampening for the underwater volume below).
	_light_opacity_lut[ICE] = 3
	# Snow block — fully opaque white cube; default opacity (15) is right.
	# Cactus — non-cube (14/16 width with side gaps); pass light through
	# at the gap. Vanilla returns 0 from getOpacity.
	_light_opacity_lut[CACTUS] = 0
	_light_opacity_lut[SNOW_LAYER] = 0
	_light_opacity_lut[SAPLING] = 0
	_light_opacity_lut[LEAVES] = 1  # vanilla BlockLeaves
	# Alpha 1.2.6 BlockFluids: nq.q[water]=nq.q[lava]=0 (nq.java:139 defaults
	# `q` to `a() ? 255 : 0`, and BlockFluids.a() returns false — ld.java:53).
	# The sky-light column pass (ha.java:199-200) bumps 0 → 1, so fluids
	# attenuate 1 per step. Bukkit/Beta later raised water to 3 (`.g(3)`),
	# which we originally used — that made ocean floors pitch-black at ~5
	# blocks deep, not authentic Alpha. Lava block-light emission (15) is
	# carried separately via light_emission().
	_light_opacity_lut[WATER_FLOWING] = 0
	_light_opacity_lut[WATER_STILL] = 0
	_light_opacity_lut[LAVA_FLOWING] = 0
	_light_opacity_lut[LAVA_STILL] = 0
	# Vanilla qh.java (BlockFire) has no opacity override → inherits the
	# default 0 because fire is non-solid. Keep it transparent so fire
	# doesn't cast a sky-light shadow on blocks below it.
	_light_opacity_lut[FIRE] = 0
	# Vanilla nq.aq (BlockTorch) — non-solid (.b()=false), so vanilla's
	# `nq.q[id]` defaults to 0 = transparent. Without this entry the LUT
	# defaults to 15 (opaque), which causes two visible bugs:
	#   * Torch casts a sky-light shadow on cells below — dark spots under
	#     every torch even though its block-light=14 should be lighting them.
	#   * The sky_light BFS fires on every torch place/break (op_diff !=0)
	#     where it shouldn't — wasted work plus the shadow side effect.
	_light_opacity_lut[TORCH] = 0
	# Fence: thin post + rails — light passes around it. Vanilla gd.a()
	# returns false (not opaque cube) and isOpaqueCube → light_opacity=0.
	_light_opacity_lut[FENCE] = 0
	# Stairs: non-opaque (mb.java:27 returns false). Light passes through
	# the open half of the step shape.
	_light_opacity_lut[WOOD_STAIRS] = 0
	_light_opacity_lut[COBBLESTONE_STAIRS] = 0
	# Doors: thin slab, light passes around them. gv.java:35 a()=false.
	_light_opacity_lut[WOODEN_DOOR] = 0
	_light_opacity_lut[IRON_DOOR] = 0
	_light_opacity_lut[LADDER] = 0
	# Rail: 1-pixel-tall flat plane, light passes through. Vanilla
	# qe.java doesn't override isOpaqueCube → defaults to false → 0.
	_light_opacity_lut[RAIL] = 0
	# Bed: 9/16 tall, light passes through the open top. Vanilla
	# bd.java doesn't override isOpaqueCube either.
	_light_opacity_lut[BED_FOOT] = 0
	_light_opacity_lut[BED_HEAD] = 0
	# Flowers + mushrooms — cross-quad blocks pass light through, same as
	# SAPLING. Vanilla mr.java extends ok which extends nq with no opacity
	# override → defaults to 0 (transparent).
	_light_opacity_lut[FLOWER_RED] = 0
	_light_opacity_lut[FLOWER_YELLOW] = 0
	_light_opacity_lut[MUSHROOM_BROWN] = 0
	_light_opacity_lut[MUSHROOM_RED] = 0
	_light_opacity_lut[SUGAR_CANE] = 0
	# Crops — non-solid cross-quad, passes full light.
	_light_opacity_lut[CROPS] = 0
	# Half-slab — half-height cube; vanilla qj.java::a() returns
	# false (isOpaqueCube), so light passes through the open top
	# half. Set opacity 0 so sky light reaches the cell below.
	# DOUBLE_SLAB (full cube) keeps the default 15.
	_light_opacity_lut[HALF_SLAB] = 0
	# Wooden + cobblestone half-slabs — same half-cube silhouette as
	# the stone variant. Their DOUBLE_SLAB variants are full cubes →
	# stay at default 15.
	_light_opacity_lut[WOOD_HALF_SLAB] = 0
	_light_opacity_lut[COBBLESTONE_HALF_SLAB] = 0
	# Signs — thin plank, light passes through the surrounding air.
	_light_opacity_lut[SIGN_STANDING] = 0
	_light_opacity_lut[SIGN_WALL] = 0
	# Fence gate — non-cube (post + rails or just posts when open), light
	# passes through the empty cell volume. Vanilla v.java a()=false.
	_light_opacity_lut[FENCE_GATE] = 0
	# Mob spawner cage — light passes through bars (vanilla eb.java
	# inherits getOpacity=0 from BlockContainer when isOpaqueCube=false).
	_light_opacity_lut[MOB_SPAWNER] = 0


static func light_opacity(id: int) -> int:
	if _light_opacity_lut.is_empty():
		_build_light_opacity_lut()
	if id < 0 or id >= _light_opacity_lut.size():
		return 15
	return _light_opacity_lut[id]


# Block-light emission on the 0..15 scale (torches, lava, glowstone). Base
# for block-light BFS — each source seeds its cell with this value and
# neighbors decay by max(opacity, 1) per step. Sourced from Alpha Block.d()
# overrides; lava returns 30 on Alpha's 0-30 internal scale (ld.java:168)
# which maps to 15 on our scale. Not yet consumed by Lighting (block-light
# channel lands in a later pass) but wiring it here keeps block metadata
# complete so the lighting port flips on without revisiting every block.
static func light_emission(id: int) -> int:
	match id:
		LAVA_FLOWING, LAVA_STILL:
			return 15
		FIRE:
			return 15  # qh.java:47 `d() return 10` on Alpha 0-30 → 15 on our 0-15 scale
		TORCH:
			return 14  # vanilla nq.aE BlockTorch `d() return 14`
		JACK_O_LANTERN:
			return 15  # vanilla BlockPumpkinLantern.lightEmission = 15
	return 0


# True if `id` (the block the player wants to place) is allowed in a cell
# where the block directly below is `support_id`. Vanilla uses
# Block.canPlaceAt; for plants this delegates to BlockPlant.j(world,...).
# Cubes have no support requirement (return true unconditionally).
static func can_place_at(id: int, support_id: int) -> bool:
	if id == SAPLING or id == FLOWER_RED or id == FLOWER_YELLOW:
		return is_valid_plant_support(support_id)
	if id == MUSHROOM_BROWN or id == MUSHROOM_RED:
		# Vanilla mushrooms accept opaque-cube support too (so they grow on
		# stone in caves). Keep the same valid-plant check + opaque fallback.
		return is_valid_plant_support(support_id) or is_opaque(support_id)
	if id == SUGAR_CANE:
		# Vanilla sugar cane: grass/dirt/sand below + water adjacent at the
		# base. Placement just checks the support; water-adjacency is the
		# worldgen scatter's responsibility (and a future tick check). Also
		# allow stacking on another sugar cane (multi-tall placement).
		return (
			support_id == GRASS
			or support_id == DIRT
			or support_id == SAND
			or support_id == SUGAR_CANE
		)
	if id == CACTUS:
		# Vanilla BlockCactus.canPlace: SAND only, OR another CACTUS for
		# multi-tall stacking. Vanilla also requires NO solid block on
		# any of the 4 cardinal sides — that side-block check is a
		# placement-time concern handled in interaction.gd if needed.
		return support_id == SAND or support_id == CACTUS
	if id == CROPS:
		# Vanilla BlockCrops.canPlaceBlockAt: requires FARMLAND below.
		# Nothing else accepted (not grass / dirt) so the player has to
		# till first.
		return support_id == FARMLAND
	return true


# Cursor-selection AABB in cell-local coords (origin at the cell's
# (x,y,z), unit cube spans [(0,0,0), (1,1,1)]). Mirrors vanilla MC's
# Block.maxX/Y/Z fields set by the constructor — see BlockSapling()
# (`f=0.4 → (0.1, 0, 0.1)..(0.9, 0.8, 0.9)`) and BlockPlant() (`f=0.2 →
# (0.3, 0, 0.3)..(0.7, 0.6, 0.7)`) in Bukkit/mc-dev. Used by the player's
# selection-highlight wireframe so plants get a tight box matching the
# rendered sprite instead of a full unit cube floating around them.
# Cube blocks (default) get the unit cube AABB.
static func selection_aabb(id: int, meta: int = 0) -> AABB:
	if id == SAPLING:
		return AABB(Vector3(0.1, 0.0, 0.1), Vector3(0.8, 0.8, 0.8))
	# Vanilla BlockFlowers / BlockMushroom — both pass `f=0.2` to the
	# super(int, int) ctor that calls `setBlockBounds(0.5-f, 0, 0.5-f,
	# 0.5+f, f*2, 0.5+f)`. So the wireframe AABB is (0.3,0,0.3)..(0.7,
	# 0.4,0.7) — a 0.4-wide, 0.4-tall box hugging the cell's bottom center.
	if id == FLOWER_RED or id == FLOWER_YELLOW or id == MUSHROOM_BROWN or id == MUSHROOM_RED:
		return AABB(Vector3(0.3, 0.0, 0.3), Vector3(0.4, 0.4, 0.4))
	if id == SUGAR_CANE:
		# Vanilla BlockReed setBlockBounds(0.125, 0, 0.125, 0.875, 1.0, 0.875)
		# — taller than flowers and slightly wider, hugs the full cell height.
		return AABB(Vector3(0.125, 0.0, 0.125), Vector3(0.75, 1.0, 0.75))
	if id == SNOW_LAYER:
		# Vanilla BlockSnowLayer setBlockBounds(0, 0, 0, 1, 0.125, 1)
		# — full-width slab, 2/16 tall.
		return AABB(Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.125, 1.0))
	if id == TORCH:
		# Vanilla ob.java:122-138 — meta-aware bounding box per orientation:
		#   1 (-X support): (0,    0.2, 0.35)..(0.3, 0.8, 0.65)
		#   2 (+X support): (0.7,  0.2, 0.35)..(1.0, 0.8, 0.65)
		#   3 (-Z support): (0.35, 0.2, 0)..(0.65,  0.8, 0.3)
		#   4 (+Z support): (0.35, 0.2, 0.7)..(0.65, 0.8, 1.0)
		#   5 / 0 (floor):  (0.4,  0,   0.4)..(0.6,  0.6, 0.6)
		# Vanilla uses f2=0.15 for wall variants and f2=0.1 for floor; the
		# constants below are derived from that.
		match meta & 7:
			1:
				return AABB(Vector3(0.0, 0.2, 0.35), Vector3(0.3, 0.6, 0.3))
			2:
				return AABB(Vector3(0.7, 0.2, 0.35), Vector3(0.3, 0.6, 0.3))
			3:
				return AABB(Vector3(0.35, 0.2, 0.0), Vector3(0.3, 0.6, 0.3))
			4:
				return AABB(Vector3(0.35, 0.2, 0.7), Vector3(0.3, 0.6, 0.3))
			_:
				# 5 / 0 — floor torch. Mesh sits at y+0.125..y+0.75
				# (vanilla bk.java applies +0.125 Y offset). AABB
				# extends to 0.75 so the wireframe encloses the flame tip.
				return AABB(Vector3(0.4, 0.0, 0.4), Vector3(0.2, 0.75, 0.2))
	if id == FENCE:
		# Pure-meta fallback (no neighbour info): the post-only 6/16 × 16/16
		# × 6/16 column, matching the visible fence with no connected rails.
		# Connection-aware version is `fence_selection_aabb_at(world_pos,
		# chunk_manager)` — interaction.gd calls that for live highlight /
		# crack so the wireframe grows out toward each connected neighbour.
		# Alpha 1.2.6 gd.java inherits nq's 0..1 unit-cube selection bounds
		# (no setBlockBoundsBasedOnState override); the connection-aware
		# extension is a Beta-era improvement we adopt for visual clarity.
		return AABB(Vector3(0.375, 0.0, 0.375), Vector3(0.25, 1.0, 0.25))
	if id == FENCE_GATE:
		return _fence_gate_selection_aabb(meta)
	if id == WOODEN_DOOR or id == IRON_DOOR:
		return _door_selection_aabb(meta)
	if id == LADDER:
		# Vanilla ca.java — 0.125-thick slab against the support wall.
		var f: float = 0.125
		match meta:
			2:
				return AABB(Vector3(0, 0, 1.0 - f), Vector3(1, 1, f))
			3:
				return AABB(Vector3(0, 0, 0), Vector3(1, 1, f))
			4:
				return AABB(Vector3(1.0 - f, 0, 0), Vector3(f, 1, 1))
			5:
				return AABB(Vector3(0, 0, 0), Vector3(f, 1, 1))
		return AABB(Vector3(0, 0, 1.0 - f), Vector3(1, 1, f))
	if id == SIGN_STANDING:
		# Vanilla ni.java::ni() ctor — setBlockBounds(0.5-f, 0, 0.5-f,
		# 0.5+f, 1, 0.5+f) with f=0.25 → 0.5×1×0.5 column centered XZ.
		# Covers the union of post + rotated panel for any meta yaw.
		return AABB(Vector3(0.25, 0.0, 0.25), Vector3(0.5, 1.0, 0.5))
	if id == SIGN_WALL:
		# Vanilla ni.java::a(pk2, ...) — meta-driven thin panel at the
		# support face. Vanilla bounds: y ∈ [0.28125, 0.78125], width
		# spans full cell, 0.125 thick against the support side.
		# Our meta 0..3 → vanilla 2..5 (−Z / +Z / −X / +X faces).
		var y0: float = 0.28125
		var dy: float = 0.5
		var t: float = 0.125
		match meta:
			0:  # -Z face panel on +Z side of cell
				return AABB(Vector3(0, y0, 1.0 - t), Vector3(1.0, dy, t))
			1:  # +Z face panel on -Z side of cell
				return AABB(Vector3(0, y0, 0), Vector3(1.0, dy, t))
			2:  # -X face panel on +X side of cell
				return AABB(Vector3(1.0 - t, y0, 0), Vector3(t, dy, 1.0))
			_:  # +X face panel on -X side of cell (meta 3)
				return AABB(Vector3(0, y0, 0), Vector3(t, dy, 1.0))
	if id == RAIL:
		# Vanilla qe.java::a(World, int, int, int) — rail bounds are the
		# bottom 1/16 slab of the cell. Selection box matches the visible
		# rail plane so the player has a reliable target for break /
		# right-click instead of a thin 0-height surface.
		return AABB(Vector3(0, 0, 0), Vector3(1.0, 1.0 / 16.0, 1.0))
	if id == BED_FOOT or id == BED_HEAD:
		# Vanilla bd.java::a(World, int, int, int) — bed bounds are
		# (0, 0, 0)..(1, 0.5625, 1). The 9/16 height matches the visible
		# mattress + frame; selection wireframe sits flush with the top
		# of the bed instead of floating to the cell ceiling.
		return AABB(Vector3(0, 0, 0), Vector3(1.0, 9.0 / 16.0, 1.0))
	return AABB(Vector3.ZERO, Vector3.ONE)


# Beta 1.8 BlockFenceGate.updateShape (Bukkit/mc-dev): the visible AABB
# spans the full cell on one axis and 6/16 on the other, depending on
# facing. Open gates are passable but the WIREFRAME / selection still
# shows the closed footprint so the cursor has something to target.
# Facing 0/2 → rails along X (full X, narrow Z). Facing 1/3 → rails
# along Z (narrow X, full Z). Y is full 0..1 (the 1.5-tall collision
# only applies to player physics, not the selection wireframe).
static func _fence_gate_selection_aabb(meta: int) -> AABB:
	var facing: int = fence_gate_facing(meta)
	if facing == 0 or facing == 2:
		return AABB(Vector3(0.0, 0.0, 0.375), Vector3(1.0, 1.0, 0.25))
	return AABB(Vector3(0.375, 0.0, 0.0), Vector3(0.25, 1.0, 1.0))


# Vanilla BlockFenceGate.b(int) — meta bit 2 is the open flag.
static func is_fence_gate_open(meta: int) -> bool:
	return (meta & 4) != 0


# Vanilla BlockFenceGate.l(int) (inherited from BlockDirectional) — meta
# bits 0-1 store the 4-way facing. 0=south, 1=west, 2=north, 3=east —
# matches the player-yaw quadrant set in postPlace.
static func fence_gate_facing(meta: int) -> int:
	return meta & 3


# Vanilla BlockFence.setBlockBoundsBasedOnState (Beta+ mc-dev): the
# visible/selectable AABB grows out from the 6/16-wide center post to
# the cell edge along each direction with a connected fence neighbour.
# Mirrors `_emit_fence_geometry` exactly so the wireframe sits on the
# rendered geometry (post + connected rail boxes), not the 1.5-tall
# collision hitbox. Alpha 1.2.6 connects same-id only — solid-block
# connection is a Beta+ change we deliberately omit.
static func fence_selection_aabb(west: bool, east: bool, north: bool, south: bool) -> AABB:
	var x_min: float = 0.0 if west else 0.375
	var x_max: float = 1.0 if east else 0.625
	var z_min: float = 0.0 if north else 0.375
	var z_max: float = 1.0 if south else 0.625
	return AABB(Vector3(x_min, 0.0, z_min), Vector3(x_max - x_min, 1.0, z_max - z_min))


static func _door_selection_aabb(meta: int) -> AABB:
	var facing: int = _door_facing(meta)
	var f: float = 0.1875  # 3/16 door thickness
	match facing:
		0:
			return AABB(Vector3(0, 0, 0), Vector3(1, 1, f))
		1:
			return AABB(Vector3(1.0 - f, 0, 0), Vector3(f, 1, 1))
		2:
			return AABB(Vector3(0, 0, 1.0 - f), Vector3(1, 1, f))
		3:
			return AABB(Vector3(0, 0, 0), Vector3(f, 1, 1))
	return AABB(Vector3.ZERO, Vector3.ONE)


# Vanilla gv.java:177 — derives the visual facing from metadata. When the
# door is closed (bit 2 == 0), the facing rotates by -1 from raw meta bits.
# When open (bit 2 != 0), raw bits are the facing directly.
static func _door_facing(meta: int) -> int:
	if (meta & 4) == 0:
		return (meta - 1) & 3
	return meta & 3


# Mesh shape for the chunk mesher. Default = full cube; only the few
# non-cube blocks need to override. Branched on per-block in
# Mesher._emit_block_faces.
static func mesh_shape(id: int) -> int:
	if (
		id == SAPLING
		or id == FLOWER_RED
		or id == FLOWER_YELLOW
		or id == MUSHROOM_BROWN
		or id == MUSHROOM_RED
		or id == SUGAR_CANE
		or id == CROPS
	):
		# Crops technically uses a flat-faced "wheat" mesh in vanilla
		# (4 vertical quads per cell) but CROSS is visually close enough
		# at our texture resolution and reuses the existing mesher path.
		# Per-stage texture swap below differentiates the 8 growth stages.
		return MESH_SHAPE_CROSS
	if id == FIRE:
		return MESH_SHAPE_FIRE
	if id == TORCH:
		return MESH_SHAPE_TORCH
	if id == CHEST:
		return MESH_SHAPE_EXTERNAL
	if id == FENCE:
		return MESH_SHAPE_FENCE
	if id == FENCE_GATE:
		return MESH_SHAPE_FENCE_GATE
	if id == WOOD_STAIRS or id == COBBLESTONE_STAIRS:
		return MESH_SHAPE_STAIRS
	if id == WOODEN_DOOR or id == IRON_DOOR:
		return MESH_SHAPE_DOOR
	if id == LADDER:
		return MESH_SHAPE_LADDER
	if id == SNOW_LAYER:
		return MESH_SHAPE_SNOW_LAYER
	if id == HALF_SLAB or id == WOOD_HALF_SLAB or id == COBBLESTONE_HALF_SLAB:
		return MESH_SHAPE_SLAB
	if id == SIGN_STANDING or id == SIGN_WALL:
		return MESH_SHAPE_SIGN
	if id == RAIL:
		return MESH_SHAPE_RAIL
	if id == BED_FOOT or id == BED_HEAD:
		return MESH_SHAPE_BED
	return MESH_SHAPE_CUBE


# True if the mesher should hand this block to the GDScript path even
# when the native MesherNative GDExtension is loaded. Native handles only
# CUBE today; non-cube shapes are sparse enough that doing them in
# GDScript per chunk has negligible cost.
static func needs_gdscript_mesher(id: int) -> bool:
	return mesh_shape(id) != MESH_SHAPE_CUBE


# True if `id` is one of the 16 contiguous wool color block ids
# (WOOL_WHITE through WOOL_BLACK). Branch-free range check — much
# cheaper than a 16-way match. Used by hardness / SFX / sound routing
# / drops so the wool family stays a single concept even though we
# allocated separate ids for atlas-lookup simplicity.
static func is_wool(id: int) -> bool:
	return id >= WOOL_WHITE and id <= WOOL_BLACK


# Vanilla `Block.getExplosionResistance` — how much a block resists the
# blast wave from TNT / creepers. The explosion ray loses
# `(resistance + 0.3) × 0.225` intensity per 0.3-block step, so a 4.0-power
# TNT blast (initial ~3 intensity per ray) breaks ~3 blocks of stone deep
# but ~0 blocks of cobblestone (cobble's resistance 30 is a vanilla
# anomaly — the recipe is faster to mine but tougher to explode). Bedrock
# and obsidian use absurd values so they're effectively immune to TNT.
# Numbers come from Bukkit/mc-dev (Beta-faithful; Alpha used the same
# values for the few blocks it had).
# Direct LUT lookup for the explosion ray-cast hot path. Lazy-builds the
# table on first call by walking every block id through the slower match
# below. PackedFloat32Array index = block_id; returns 0.0 for unknown ids
# (matches the match's fallthrough).
static func explosion_resistance_fast(id: int) -> float:
	if _resistance_lut.is_empty():
		_resistance_lut = PackedFloat32Array()
		_resistance_lut.resize(256)
		for i in range(256):
			_resistance_lut[i] = explosion_resistance(i)
	return _resistance_lut[id] if id >= 0 and id < 256 else 0.0


static func explosion_resistance(id: int) -> float:
	# Wool family — same 4.0 for all 16 colors. Vanilla nq.ab uses
	# default `b(0.0)` which is 0.0 actually; we use 4.0 to match the
	# vanilla cloth-material resistance (the constructor sets material
	# resistance separately from per-block b()). Keeps wool from being
	# blown apart by TNT placed two cells away.
	if is_wool(id):
		return 4.0
	match id:
		BEDROCK:
			return 6000000.0
		OBSIDIAN:
			return 2000.0
		COBBLESTONE, COBBLESTONE_STAIRS, MOSSY_COBBLESTONE:
			return 30.0
		WATER_FLOWING, WATER_STILL, LAVA_FLOWING, LAVA_STILL:
			return 500.0
		IRON_DOOR:
			return 25.0
		STONE, BRICK, FURNACE, LIT_FURNACE, IRON_ORE, COAL_ORE, GOLD_ORE, DIAMOND_ORE:
			return 6.0
		WOODEN_DOOR:
			return 15.0
		LOG, PLANKS, CRAFTING_TABLE, FENCE, WOOD_STAIRS, CHEST, LADDER, BOOKSHELF, FENCE_GATE:
			return 2.5
		IRON_BLOCK, GOLD_BLOCK, DIAMOND_BLOCK:
			# Vanilla nq.e class constructor uses b(10.0f) — high blast
			# resistance, same as iron-tier ores.
			return 10.0
		SPONGE:
			return 3.0  # vanilla nq.L — light + brittle
		CLAY:
			return 3.0  # vanilla nq.aW — soft gravel-like
		HALF_SLAB, DOUBLE_SLAB:
			return 6.0  # vanilla qj — same as stone (Material.stone)
		WOOD_HALF_SLAB, WOOD_DOUBLE_SLAB:
			return 2.5  # vanilla Beta nq.aT — same as PLANKS (Material.wood)
		COBBLESTONE_HALF_SLAB, COBBLESTONE_DOUBLE_SLAB:
			return 30.0  # cobblestone-family — same blast resistance
		SIGN_STANDING, SIGN_WALL:
			return 5.0  # vanilla ni.java — same as wood family
	# Soft / replaceable blocks — air, plants, sand, dirt, leaves, glass,
	# torch, fire, sapling, TNT. Vanilla TNT resistance is 0 specifically
	# so a TNT cell offers no shielding to the next chained TNT — keeps
	# stack chain reactions punchy.
	return 0.0


# Block hardness — base for all break-time math. Vanilla MC values, in
# "block-hardness units" not seconds. Final time = hardness × multiplier
# (1.5 if correct tool, 5.0 if wrong/no tool) ÷ tool speed.
static func hardness(id: int) -> float:
	# Wool family hits 16 ids contiguously — split it out so the match
	# below stays readable. Vanilla nq.ab `c(0.8f)` — soft cloth, any
	# tool breaks fast.
	if is_wool(id):
		return 0.8
	match id:
		BEDROCK, WATER_FLOWING, WATER_STILL, LAVA_FLOWING, LAVA_STILL:
			# Fluids are unbreakable by hand; in vanilla they're only
			# removable via bucket pickup (separate interaction, not a
			# mining break). Lava also damages on contact, so letting the
			# player "mine" it would be a bad experience anyway.
			return -1.0  # unbreakable
		FIRE:
			# Vanilla qh.java has no hardness but the block drops to AIR
			# on any click — behaviorally equivalent to hardness 0 here.
			return 0.0
		LEAVES, GLASS:
			return 0.2
		ICE:
			return 0.5  # vanilla BlockIce hardness
		SNOW_BLOCK:
			return 0.2  # vanilla BlockSnowBlock — soft, shovel-preferred
		CACTUS:
			return 0.4  # vanilla BlockCactus hardness
		SNOW_LAYER:
			return 0.1  # vanilla BlockSnowLayer instant break
		SAPLING, TORCH, FLOWER_RED, FLOWER_YELLOW, MUSHROOM_BROWN, MUSHROOM_RED, SUGAR_CANE:
			return 0.0  # vanilla: instant break
		CROPS:
			# Vanilla BlockCrops inherits hardness 0 from BlockBush.
			# Instant break by any tool / bare hand.
			return 0.0
		DIRT, SAND:
			return 0.5
		GRASS, FARMLAND, GRAVEL:
			return 0.6
		LADDER:
			return 0.4  # ca.java `c(0.4f)` — soft wood, quick break
		TNT:
			return 0.0  # v.java `c(0.0f)` — instant break (still drops the block)
		LOG, PLANKS, CRAFTING_TABLE, FENCE, WOOD_STAIRS, COBBLESTONE_STAIRS, FENCE_GATE:
			# mb.java:14 `this.c(nq2.bi)` — inherits parent hardness (2.0).
			# BlockFenceGate (Bukkit) calls `super(Material.WOOD)` and never
			# overrides hardness, so it inherits the 2.0 wood-material default.
			return 2.0
		RAIL:
			# qe.java::c(0.7f) — soft, breaks fast with bare hand.
			return 0.7
		BED_FOOT, BED_HEAD:
			# bd.java::c(0.2f) — wool material, snaps quickly. Vanilla
			# doesn't gate on tool; bare-hand breaks in under a second.
			return 0.2
		JUKEBOX:
			# Beta 1.4 BlockJukebox::c(2.0f) — same as a regular wood
			# block. Axe-preferred (set in preferred_tool_type below).
			return 2.0
		WOODEN_DOOR:
			return 3.0  # gv.java: nq.aE `c(3.0f)` — wood door
		IRON_DOOR:
			return 5.0  # gv.java: nq.aL `c(5.0f)` — iron door
		CHEST:
			return 2.5  # c.java:c(2.5f) — slightly tougher than planks
		STONE, COBBLESTONE, MOSSY_COBBLESTONE, BRICK:
			return 1.5
		FURNACE, LIT_FURNACE:
			return 3.5
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return 3.0
		OBSIDIAN:
			return 50.0
		PUMPKIN, JACK_O_LANTERN:
			# Vanilla BlockPumpkin / BlockPumpkinLantern both `c(1.0f)`.
			# Axe-preferred but breakable by hand.
			return 1.0
		BOOKSHELF:
			# Vanilla BlockBookshelf `c(1.5f)`. Axe-preferred.
			return 1.5
		MOB_SPAWNER:
			# Vanilla BlockMobSpawner `c(5.0f)`. Pickaxe-preferred,
			# drops nothing on break (handled in drops()).
			return 5.0
		SPONGE:
			# Vanilla nq.L `c(0.6f)`. Soft, instant with any tool.
			return 0.6
		IRON_BLOCK:
			# Vanilla nq.ai `c(5.0f)`. Pickaxe-harvest, iron+.
			return 5.0
		GOLD_BLOCK:
			# Vanilla nq.ah `c(3.0f)`. Pickaxe-harvest, iron+.
			return 3.0
		DIAMOND_BLOCK:
			# Vanilla nq.ax `c(5.0f)`. Pickaxe-harvest, iron+.
			return 5.0
		CLAY:
			# Vanilla nq.aW `c(0.6f)`. Shovel-preferred, instant
			# with shovel, fairly fast bare-hand.
			return 0.6
		HALF_SLAB, DOUBLE_SLAB:
			# Vanilla qj.java inherits from BlockSandStone-style stone
			# (via `nq(id, 6, hb.d)`). Block.c is default 2.0 for stone
			# but qj overrides nothing — hits the default 2.0.
			return 2.0
		WOOD_HALF_SLAB, WOOD_DOUBLE_SLAB:
			# Beta nq.aT — Material.wood, axe-preferred. Hardness 2.0
			# matches PLANKS.
			return 2.0
		COBBLESTONE_HALF_SLAB, COBBLESTONE_DOUBLE_SLAB:
			# Cobblestone-textured variant — Material.stone, pickaxe-
			# required. Same hardness as the stone slab.
			return 2.0
		SIGN_STANDING, SIGN_WALL:
			# Vanilla ni.java `c(1.0f)` — fast break with axe, slow bare-
			# handed but still possible.
			return 1.0
		SLIME_BLOCK:
			# Modern MC BlockSlime is hardness 0 (instabreak by hand,
			# but the block IS dropped). Modern QoL deviation — not in
			# Alpha. Drops itself; no tool required.
			return 0.0
	return 1.0


# Required harvest level to actually drop the block when broken with a tool.
# 0 = no requirement (any tool / bare hand drops). Vanilla mc-dev values:
#   stone-class & coal: 0  (any pickaxe drops cobblestone/coal)
#   iron ore:           1  (stone pick or better)
#   gold/diamond/redstone ore: 2  (iron pick or better)
#   obsidian:           3  (diamond pick)
static func required_harvest_level(id: int) -> int:
	match id:
		IRON_ORE:
			return 1
		GOLD_ORE, DIAMOND_ORE:
			return 2
		OBSIDIAN:
			return 3
		IRON_BLOCK, GOLD_BLOCK, DIAMOND_BLOCK:
			# Vanilla nq.ai / ah / ax require iron-tier pickaxe to drop.
			# Wood / stone pickaxes break them but yield nothing.
			return 2
	return 0


# Which tool type is "correct" for break-speed bonus (see Items.TOOL_TYPE_*).
# 0 = any/none (no bonus from any tool). Mirrors vanilla ItemPickaxe's block list.
static func preferred_tool_type(id: int) -> int:
	match id:
		STONE, COBBLESTONE, MOSSY_COBBLESTONE, COBBLESTONE_STAIRS, BRICK, OBSIDIAN:
			return Items.TOOL_TYPE_PICKAXE
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return Items.TOOL_TYPE_PICKAXE
		FURNACE, LIT_FURNACE:
			return Items.TOOL_TYPE_PICKAXE
		LOG, PLANKS, CHEST, FENCE, WOOD_STAIRS, WOODEN_DOOR, LADDER, BOOKSHELF, FENCE_GATE:
			return Items.TOOL_TYPE_AXE
		IRON_DOOR:
			return Items.TOOL_TYPE_PICKAXE
		DIRT, GRASS, SAND, FARMLAND, GRAVEL:
			return Items.TOOL_TYPE_SHOVEL
		PUMPKIN, JACK_O_LANTERN:
			# Vanilla BlockPumpkin sets `b("axe")` via Block.b(String) —
			# axe gets the break-speed bonus, but any tool / bare hand drops.
			return Items.TOOL_TYPE_AXE
		IRON_BLOCK, GOLD_BLOCK, DIAMOND_BLOCK, MOB_SPAWNER:
			# All metal blocks + mossy mob spawner cage are pickaxe-preferred.
			return Items.TOOL_TYPE_PICKAXE
		CLAY:
			# Vanilla nq.aW uses gravel material → shovel break-speed bonus.
			return Items.TOOL_TYPE_SHOVEL
		HALF_SLAB, DOUBLE_SLAB:
			# Stone material → pickaxe-preferred. Required-level 0.
			return Items.TOOL_TYPE_PICKAXE
		WOOD_HALF_SLAB, WOOD_DOUBLE_SLAB:
			# Wood material → axe-preferred.
			return Items.TOOL_TYPE_AXE
		COBBLESTONE_HALF_SLAB, COBBLESTONE_DOUBLE_SLAB:
			# Cobblestone variant — Material.stone, pickaxe-preferred.
			return Items.TOOL_TYPE_PICKAXE
		RAIL:
			# Iron material — pickaxe-preferred. Hardness is low so even a
			# bare hand breaks it quickly; the pickaxe just speeds it up.
			return Items.TOOL_TYPE_PICKAXE
		BED_FOOT, BED_HEAD:
			# Wool material — vanilla bd.java doesn't set a tool affinity.
			# Same as wool blocks: fall through to the default 0 below.
			return 0
		JUKEBOX:
			# Vanilla BlockJukebox extends BlockContainer; the material is
			# wood (no override on c(Material) in the ctor). Wood material
			# → axe-preferred.
			return Items.TOOL_TYPE_AXE
		SIGN_STANDING, SIGN_WALL:
			# Vanilla ni.java sets material wood → axe-preferred.
			return Items.TOOL_TYPE_AXE
	return 0


# Time (seconds) to break this block with the given tool (or AIR for bare
# hand). Returns -1.0 for unbreakable. Mirrors vanilla Beta's
# `Block.getPlayerRelativeBlockHardness`:
#   • If the block's material requires a tool and the held tool doesn't
#     qualify, the slow branch applies: `hardness × 5` seconds.
#   • Otherwise the fast branch: `hardness × 1.5 / strVsBlock`, where
#     strVsBlock is the tool's speed when it's effective against this
#     block (correct type + sufficient tier), else 1.0 (bare-hand rate).
# "Requires a tool" = stone-class (pickaxe preferred, harvest level 0) or
# anything with a positive harvest level (ores, obsidian). Soft blocks
# (dirt, grass, wood, leaves, sand) all break fine bare-handed.
static func break_time(id: int, tool_id: int) -> float:
	var h: float = hardness(id)
	if h < 0.0:
		return -1.0
	var tool_kind: int = Items.tool_type(tool_id) if tool_id != AIR else 0
	var preferred: int = preferred_tool_type(id)
	var required_level: int = required_harvest_level(id)
	var type_ok: bool = preferred != 0 and tool_kind == preferred
	var tier_ok: bool = tool_id != AIR and Items.tool_harvest_level(tool_id) >= required_level
	var effective: bool = type_ok and tier_ok
	var requires_tool: bool = (
		(preferred == Items.TOOL_TYPE_PICKAXE and required_level == 0) or required_level > 0
	)
	if requires_tool and not effective:
		return h * 5.0
	var speed: float = Items.tool_speed(tool_id) if effective else 1.0
	return h * 1.5 / speed


# Wraps drop_with_tool with vanilla random-drop overrides:
#   • Leaves: 5% chance of SAPLING (BlockLeaves.dropNaturally — 1/20)
#   • Gravel: 10% chance of FLINT instead of gravel (BlockGravel)
# All other blocks return the deterministic drop_with_tool result.
static func random_drop(id: int, tool_id: int) -> int:
	if id == LEAVES:
		# Leaves use a 1/20 sapling roll regardless of tool.
		if randi() % 20 == 0:
			return SAPLING
		return AIR
	if id == GRAVEL:
		# 1/10 flint chance — only when broken with a shovel-or-bare-hand
		# (vanilla); a non-shovel/non-bare break still drops gravel via
		# drop_with_tool's normal path.
		if randi() % 10 == 0:
			return Items.FLINT
	return drop_with_tool(id, tool_id)


# Returns the item dropped when the block is broken with `tool_id`, gated
# by tool harvest level. AIR means "no drop". `tool_id == AIR` is bare hand.
static func drop_with_tool(id: int, tool_id: int) -> int:
	# Hard tier gate: if the tool is below the block's required level, no drop.
	var required: int = required_harvest_level(id)
	if required > 0:
		if tool_id == AIR:
			return AIR  # bare hand never satisfies a level requirement
		if Items.tool_harvest_level(tool_id) < required:
			return AIR
	# Stone-class blocks (cobblestone-droppers) ALSO require *some* pickaxe
	# even at level 0 — bare hand on stone drops nothing in vanilla.
	if preferred_tool_type(id) == Items.TOOL_TYPE_PICKAXE and required == 0:
		if tool_id == AIR or Items.tool_type(tool_id) != Items.TOOL_TYPE_PICKAXE:
			return AIR
	return drops(id)


# Bare-hand break time in seconds (Alpha hardness × 1.5 baseline).
# A return of -1.0 means unbreakable (bedrock).
static func break_time_bare_hand(id: int) -> float:
	match id:
		BEDROCK:
			return -1.0
		LEAVES:
			return 0.3
		DIRT, SAND:
			return 0.75
		GRASS, FARMLAND, GRAVEL:
			return 0.9
		LOG:
			return 3.0
		PLANKS:
			return 3.0
		STONE, COBBLESTONE, BRICK:
			return 7.5  # painfully slow without a pickaxe — Alpha-faithful
		FURNACE, LIT_FURNACE:
			return 17.5  # 3.5 hardness × 5 (no-tool penalty)
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return 15.0  # ores are tougher than stone — wood-pick takes ~2.5s
		OBSIDIAN:
			return 250.0  # only diamond pickaxe is practical
	return 1.5


# Alpha-faithful drop table. Returns the item ID dropped when the block is
# broken with bare hands or appropriate tool. AIR means "no drop".
# Bedrock is unbreakable in survival, but if it ever is broken: no drop.
# Ore-tier drop gating (wood-pick required for stone, etc.) lands with
# the tool-tier system in a later slice — for now, ores drop their items.
static func drops(id: int) -> int:
	match id:
		STONE:
			return COBBLESTONE
		GRASS, FARMLAND:
			return DIRT
		LEAVES:
			return AIR  # Alpha leaves dropped 0 or 1 sapling — no saplings yet
		GLASS:
			return AIR  # vanilla: glass shatters when broken, drops nothing
		ICE:
			return AIR  # vanilla: ice melts to water on break (handled in interaction)
		SNOW_BLOCK:
			# Vanilla `bo.java::a(int, Random, int)` returns ItemSnowball.
			# Quantity 4 is handled in drop_quantity below — matches
			# vanilla's `idDropped * 4` short-circuit.
			return Items.SNOWBALL
		CACTUS:
			return CACTUS  # drops itself
		SNOW_LAYER:
			# Vanilla BlockSnow drops 1 snowball per layer broken. Modern
			# scales with layer depth (1-8); we follow Alpha which only
			# had a single-layer snow_layer block, hence 1.
			return Items.SNOWBALL
		SAPLING:
			return SAPLING  # drops itself when broken
		FLOWER_RED, FLOWER_YELLOW, MUSHROOM_BROWN, MUSHROOM_RED:
			return id  # plants drop themselves
		SUGAR_CANE:
			return Items.SUGAR_CANE  # drops as ITEM (re-place via item)
		BEDROCK:
			return AIR
		MOB_SPAWNER:
			# Vanilla BlockMobSpawner.a(Random) returns 0 — spawner
			# blocks drop nothing on break (keeps them non-renewable,
			# only obtainable via creative/debug placement).
			return AIR
		WATER_FLOWING, WATER_STILL, LAVA_FLOWING, LAVA_STILL, FIRE:
			# Fluids and fire have no item form. When displaced (e.g. a block
			# placed on a water cell) `_place_block_from_held` drops the
			# replaced cell — without these cases, drops() fell through to
			# `return id` and spawned a dropped item with the water/lava/fire
			# BLOCK id, which renders as a blank grey "no-icon, no-name"
			# pickup since item-id space is disjoint from block-id space.
			return AIR
		WOODEN_DOOR:
			return Items.WOODEN_DOOR
		IRON_DOOR:
			return Items.IRON_DOOR
		COAL_ORE:
			return Items.COAL
		DIAMOND_ORE:
			return Items.DIAMOND
		IRON_ORE, GOLD_ORE:
			return id  # iron/gold ore drops itself (smelt for ingot)
		LIT_FURNACE:
			return FURNACE  # vanilla: lit furnace breaks back into the unlit form
		BOOKSHELF:
			# Vanilla BlockBookshelf returns Item.book — the 3-count comes
			# from drop_quantity() below, not here.
			return Items.BOOK
		CLAY:
			# Vanilla lj.java::a returns dx.aG (clay_ball item) — 4 per
			# break via drop_quantity(). Hand vs shovel: any tool drops.
			return Items.CLAY_BALL
		DOUBLE_SLAB:
			# Vanilla qj.java::a always returns nq.ak (half-slab id),
			# even when broken from a double-slab. Drop count = 2 via
			# drop_quantity to recover both halves.
			return HALF_SLAB
		HALF_SLAB:
			# Vanilla half-slab drops itself unchanged.
			return HALF_SLAB
		WOOD_DOUBLE_SLAB:
			return WOOD_HALF_SLAB
		WOOD_HALF_SLAB:
			return WOOD_HALF_SLAB
		COBBLESTONE_DOUBLE_SLAB:
			return COBBLESTONE_HALF_SLAB
		COBBLESTONE_HALF_SLAB:
			return COBBLESTONE_HALF_SLAB
		SIGN_STANDING, SIGN_WALL:
			# Vanilla ni.java::a returns dx.as (sign item, our Items.SIGN).
			# The text on the sign is discarded — vanilla doesn't preserve
			# it through item form either.
			return Items.SIGN
		RAIL:
			# Vanilla qe.java drops Items.MINECART_TRACK (item id 66).
			return Items.RAIL
		BED_FOOT, BED_HEAD:
			# Vanilla bd.java::e_() drops a single BED item regardless of
			# which half the player broke (and even when broken via the
			# paired-half cascade — see interaction.gd's break-cascade).
			return Items.BED
	return id


# How many drops the block produces per break. 1 for nearly everything;
# bookshelf yields 3 books per BlockBookshelf.dropBlockAsItemWithChance
# (drops getDropQuantity()=3 in Beta). Interaction.gd loops random_drop
# this many times so each drop hits the same RNG branch as a normal break
# (gravel-flint, leaves-sapling, etc. still roll per drop slot).
static func drop_quantity(id: int) -> int:
	if id == BOOKSHELF:
		return 3
	if id == CLAY:
		# Vanilla lj.java::a(Random) returns 4 — every clay block drops
		# 4 clay balls regardless of tool. Counts towards loop semantics
		# so interaction.gd's loop spawns 4 separate dropped items
		# (matches vanilla's per-item-spread on break-drop).
		return 4
	if id == DOUBLE_SLAB or id == WOOD_DOUBLE_SLAB or id == COBBLESTONE_DOUBLE_SLAB:
		# Vanilla qj.java — double-slab is two stacked halves; breaking
		# drops both back as separate half-slab items.
		return 2
	if id == SNOW_BLOCK:
		# Vanilla bo.java::a — snow block drops 4 snowballs.
		return 4
	return 1


static func name_of(id: int) -> String:
	match id:
		AIR:
			return "air"
		BEDROCK:
			return "bedrock"
		STONE:
			return "stone"
		DIRT:
			return "dirt"
		GRASS:
			return "grass"
		COBBLESTONE:
			return "cobblestone"
		MOSSY_COBBLESTONE:
			return "mossy_cobblestone"
		LOG:
			return "log"
		PLANKS:
			return "planks"
		LEAVES:
			return "leaves"
		SAND:
			return "sand"
		COAL_ORE:
			return "coal_ore"
		IRON_ORE:
			return "iron_ore"
		GOLD_ORE:
			return "gold_ore"
		DIAMOND_ORE:
			return "diamond_ore"
		CRAFTING_TABLE:
			return "crafting_table"
		FARMLAND:
			return "farmland"
		GRAVEL:
			return "gravel"
		FURNACE:
			return "furnace"
		LIT_FURNACE:
			return "lit_furnace"
		GLASS:
			return "glass"
		ICE:
			return "ice"
		SNOW_BLOCK:
			return "snow"
		SNOW_LAYER:
			return "snow"
		CACTUS:
			return "cactus_side"  # 1-arg fallback; per-face uses get_texture_for_face_string
		SAPLING:
			return "sapling"
		WATER_FLOWING:
			return "water_flowing"
		WATER_STILL:
			return "water"
		LAVA_FLOWING:
			return "lava_flowing"
		LAVA_STILL:
			return "lava"
		FIRE:
			return "fire"
		TORCH:
			return "torch"
		WOOD_STAIRS:
			return "wood_stairs"
		COBBLESTONE_STAIRS:
			return "cobblestone_stairs"
		WOODEN_DOOR:
			return "wooden_door"
		IRON_DOOR:
			return "iron_door"
		LADDER:
			return "ladder"
		TNT:
			return "tnt"
		FLOWER_RED:
			return "flower_red"
		FLOWER_YELLOW:
			return "flower_yellow"
		MUSHROOM_BROWN:
			return "mushroom_brown"
		MUSHROOM_RED:
			return "mushroom_red"
		SUGAR_CANE:
			return "sugar_cane"
		PUMPKIN:
			return "pumpkin"
		JACK_O_LANTERN:
			return "jack_o_lantern"
		BOOKSHELF:
			return "bookshelf"
		CROPS:
			return "crops_stage_7"  # 1-arg fallback (mature); meta-aware path below picks the per-stage tile
		MOB_SPAWNER:
			return "mob_spawner"
		WOOL_WHITE:
			return "wool_white"
		WOOL_ORANGE:
			return "wool_orange"
		WOOL_MAGENTA:
			return "wool_magenta"
		WOOL_LIGHT_BLUE:
			return "wool_light_blue"
		WOOL_YELLOW:
			return "wool_yellow"
		WOOL_LIME:
			return "wool_lime"
		WOOL_PINK:
			return "wool_pink"
		WOOL_GRAY:
			return "wool_gray"
		WOOL_LIGHT_GRAY:
			return "wool_light_gray"
		WOOL_CYAN:
			return "wool_cyan"
		WOOL_PURPLE:
			return "wool_purple"
		WOOL_BLUE:
			return "wool_blue"
		WOOL_BROWN:
			return "wool_brown"
		WOOL_GREEN:
			return "wool_green"
		WOOL_RED:
			return "wool_red"
		WOOL_BLACK:
			return "wool_black"
		SPONGE:
			return "sponge"
		IRON_BLOCK:
			return "iron_block"
		GOLD_BLOCK:
			return "gold_block"
		DIAMOND_BLOCK:
			return "diamond_block"
		CLAY:
			return "clay"
		HALF_SLAB:
			return "half_slab"
		DOUBLE_SLAB:
			return "double_slab"
		WOOD_HALF_SLAB:
			return "wood_half_slab"
		WOOD_DOUBLE_SLAB:
			return "wood_double_slab"
		COBBLESTONE_HALF_SLAB:
			return "cobblestone_half_slab"
		COBBLESTONE_DOUBLE_SLAB:
			return "cobblestone_double_slab"
		SIGN_STANDING:
			return "sign_standing"
		SIGN_WALL:
			return "sign_wall"
		FENCE_GATE:
			return "fence_gate"
		RAIL:
			return "rail"
		BED_FOOT:
			return "bed_foot"
		BED_HEAD:
			return "bed_head"
		JUKEBOX:
			return "jukebox"
		SLIME_BLOCK:
			return "slime_block"
	return "unknown"


# Returns the texture name for a given block face. face ∈ {"top", "bottom", "side"}
# Blocks whose 4 side faces aren't identical — the mesher pulls per-face
# textures via directional_face_texture below instead of the
# get_face_texture(id, "side") fast path. Currently pumpkin family;
# future furnace meta-aware front face, beds, etc. would extend this.
static func has_directional_face(id: int) -> bool:
	return id == PUMPKIN or id == JACK_O_LANTERN


# Per-face texture for directional blocks. `face_idx` is the mesher's
# 0..5 enum: 0=+Y, 1=-Y, 2=+X, 3=-X, 4=+Z, 5=-Z. `meta` is the block's
# stored facing (0..3 for pumpkins, mapping 0=-Z, 1=-X, 2=+Z, 3=+X to
# match the chest convention in _chest_meta_from_yaw).
static func directional_face_texture(id: int, face_idx: int, meta: int) -> String:
	if id == PUMPKIN or id == JACK_O_LANTERN:
		# Top + bottom share the stem texture regardless of meta.
		if face_idx == 0 or face_idx == 1:
			return "pumpkin_top"
		# Map the stored meta to the face_idx of the side it faces.
		# Inverse of the table in _chest_meta_from_yaw / pumpkin placement.
		var front_face_idx: int = 5  # default -Z when meta=0
		match meta:
			0:
				front_face_idx = 5  # -Z (north)
			1:
				front_face_idx = 3  # -X (west)
			2:
				front_face_idx = 4  # +Z (south)
			3:
				front_face_idx = 2  # +X (east)
		if face_idx == front_face_idx:
			return "jack_o_lantern_face" if id == JACK_O_LANTERN else "pumpkin_face"
		return "pumpkin_side"
	# Fallback for any future directional block that hits this path without
	# a special-case branch — render side as if it were non-directional.
	return get_face_texture(id, "side")


static func get_face_texture(id: int, face: String) -> String:
	# Wool family + the new solid blocks all share a texture across all
	# 6 faces — short-circuit before the match so we don't need 16+5
	# match arms.
	if is_wool(id):
		return name_of(id)  # wool_white / wool_orange / …
	if id == SPONGE:
		return "sponge"
	if id == IRON_BLOCK:
		return "iron_block"
	if id == GOLD_BLOCK:
		return "gold_block"
	if id == DIAMOND_BLOCK:
		return "diamond_block"
	if id == CLAY:
		return "clay"
	if id == SLIME_BLOCK:
		# All 6 faces share one tile; the chunk shader's per-face shading
		# LUT still gives the cube edge contrast.
		return "slime_block"
	if id == HALF_SLAB or id == DOUBLE_SLAB:
		# Vanilla qj.java::a(int) returns texture index 6 for top/bottom
		# (stone_slab_top) and 5 for sides (stone_slab_side).
		if face == "top" or face == "bottom":
			return "stone_slab_top"
		return "stone_slab_side"
	if id == WOOD_HALF_SLAB or id == WOOD_DOUBLE_SLAB:
		# Beta wood-slab variant — planks on all 6 faces. No dedicated
		# wood-slab top/side tile in Alpha terrain.png; the half-height
		# silhouette is what reads as a slab.
		return "planks"
	if id == COBBLESTONE_HALF_SLAB or id == COBBLESTONE_DOUBLE_SLAB:
		# Cobblestone-textured variant — cobblestone on all 6 faces.
		return "cobblestone"
	if id == SIGN_STANDING or id == SIGN_WALL:
		# Stage 1 placeholder: full-cube planks render. Stage 2 swaps to
		# the non-cube sign-post / wall-panel mesh with the wood texture
		# on the post and a procedural plank face for the inscribed area.
		return "planks"
	if id == FENCE_GATE:
		# Vanilla v.java (Beta BlockFenceGate) inherits the planks texture
		# from Material.WOOD with no override — every face of every box
		# (posts + rails) samples the planks tile.
		return "planks"
	if id == RAIL:
		# Rails sample one of two textures based on meta orientation: the
		# straight strip for orientations 0-5 (N-S, E-W, 4× ascending) or
		# the curved strip for 6-9 (turns). Meta isn't visible to
		# get_face_texture; the rail mesher reads meta directly to pick.
		# Default to straight — the curve case is handled in the mesher.
		return "rail"
	match id:
		BEDROCK:
			return "bedrock"
		STONE:
			return "stone"
		DIRT:
			return "dirt"
		GRASS:
			match face:
				"top":
					return "grass_top"
				"bottom":
					return "dirt"
				_:
					return "grass_side"
		COBBLESTONE:
			return "cobblestone"
		MOSSY_COBBLESTONE:
			return "mossy_cobblestone"
		BRICK:
			return "brick"
		OBSIDIAN:
			return "obsidian"
		LOG:
			match face:
				"top", "bottom":
					return "log_top"
				_:
					return "log_side"
		PLANKS:
			return "planks"
		LEAVES:
			return "leaves"
		SAND:
			return "sand"
		COAL_ORE:
			return "coal_ore"
		IRON_ORE:
			return "iron_ore"
		GOLD_ORE:
			return "gold_ore"
		DIAMOND_ORE:
			return "diamond_ore"
		CRAFTING_TABLE:
			match face:
				"top":
					return "crafting_table_top"
				"bottom":
					return "planks"
				_:
					return "crafting_table_side"
		JUKEBOX:
			# Vanilla BlockJukebox::a(int) — top returns the inlay-groove
			# tile, every other face returns the noteblock-side-style tile.
			# Bottom is the same as the sides (no dedicated bottom tile).
			if face == "top":
				return "jukebox_top"
			return "jukebox_side"
		BOOKSHELF:
			match face:
				"top", "bottom":
					return "planks"
				_:
					return "bookshelf_side"
		CROPS:
			# 1-arg fallback returns the mature stage tile. The mesher's
			# meta-aware path (directional_face_texture) picks the actual
			# stage at render time — see has_directional_face.
			return "crops_stage_7"
		MOB_SPAWNER:
			# All 6 faces share the mossy cage tile. Vanilla
			# BlockMobSpawner.getBlockTextureFromSide returns the same
			# index for every face.
			return "mob_spawner"
		FARMLAND:
			match face:
				"top":
					return "farmland"
				_:
					return "dirt"
		GRAVEL:
			return "gravel"
		FURNACE:
			match face:
				"top", "bottom":
					return "furnace_top"
				_:
					return "furnace_front"
		LIT_FURNACE:
			match face:
				"top", "bottom":
					return "furnace_top"
				_:
					return "furnace_front_lit"
		GLASS:
			return "glass"
		ICE:
			return "ice"
		SNOW_BLOCK:
			return "snow"
		SNOW_LAYER:
			return "snow"
		CACTUS:
			match face:
				"top":
					return "cactus_top"
				"bottom":
					return "cactus_bottom"
				_:
					return "cactus_side"
		PUMPKIN:
			match face:
				"top", "bottom":
					return "pumpkin_top"
				_:
					# Carved face on every side — used by the auxiliary
					# render paths (BlockIconRenderer iso bake, held-in-
					# hand mini-cube, DroppedItem world entity). Matches
					# vanilla Alpha's 2D inventory icon, which shows the
					# carved face from every angle.
					#
					# IN-WORLD rendering takes a different path: the chunk
					# mesher dispatches PUMPKIN / JACK_O_LANTERN through
					# directional_face_texture(), which reads block_meta
					# and only puts the carved face on the single side the
					# pumpkin was placed facing. So world geometry is
					# meta-accurate even though this fallback isn't.
					return "pumpkin_face"
		JACK_O_LANTERN:
			match face:
				"top", "bottom":
					return "pumpkin_top"
				_:
					return "jack_o_lantern_face"
		SAPLING:
			return "sapling"
		WATER_FLOWING, WATER_STILL:
			# No water texture in the atlas yet — the mesher skips water until
			# the dedicated water render pass lands. Return empty so any other
			# caller knows there's no bound tile.
			return ""
		LAVA_STILL:
			return "lava_still"
		LAVA_FLOWING:
			return "lava_flowing"
		FIRE:
			return "fire"
		TORCH:
			return "torch"
		CHEST:
			# Chest has 3 faces in vanilla terrain.png (c.java reads bg-1
			# for top/bottom, bg+1 for the latched front, bg for the
			# unmarked sides). The actual rendering goes through ChestNode
			# (separate entity), but BlockAtlas needs an entry so the
			# block icon renderer + tooltip preview have something to
			# show. The mesher skips CHEST cells, so this only feeds the
			# 3D icon path.
			match face:
				"top", "bottom":
					return "chest_top"
				_:
					return "chest_side"
		FENCE:
			# Vanilla nq.aZ uses terrain index 4 (= planks). Same texture
			# on every face of the post and rails — see gd.java:8
			# `super(n2, 4, hb.c)` and bk.java:1192 onward.
			return "planks"
		WOOD_STAIRS:
			return "planks"
		COBBLESTONE_STAIRS:
			return "cobblestone"
		LADDER:
			return "ladder"
		TNT:
			match face:
				"top":
					return "tnt_top"
				"bottom":
					return "tnt_bottom"
				_:
					return "tnt_side"
		FLOWER_RED:
			return "flower_red"
		FLOWER_YELLOW:
			return "flower_yellow"
		MUSHROOM_BROWN:
			return "mushroom_brown"
		MUSHROOM_RED:
			return "mushroom_red"
		SUGAR_CANE:
			return "sugar_cane"
	return ""


# Door texture varies by half — upper vs lower. Metadata bit 3 selects.
# Called by the mesher with the actual metadata; the base get_face_texture
# above can't branch on meta so doors route through here.
static func door_texture(id: int, meta: int) -> String:
	var is_upper: bool = (meta & 8) != 0
	if id == WOODEN_DOOR:
		return "door_wood_upper" if is_upper else "door_wood_lower"
	return "door_iron_upper" if is_upper else "door_iron_lower"
