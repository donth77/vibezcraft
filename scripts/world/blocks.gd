class_name Blocks
extends RefCounted

# gdlint: disable=max-file-lines
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
# Vanilla Alpha BlockTNT (v.java, id 46). Hardness 0 = instant break, drops
# itself (NOT primed-TNT-on-mine — vanilla a(Random)=0 only suppresses the
# random drop when the block is broken by an explosion shockwave). Right-
# click with flint and steel ignites: replace block with kr (EntityTNTPrimed),
# 80-tick fuse → explosion power 4 at the entity position. Faces use 3
# distinct atlas tiles (top fuse plate, side TNT lettering, plain red bottom)
# extracted from the Alpha terrain.png at row 0 cols 8-10.
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

# Lazy-init lookup table for light_opacity (built on first access).
# Direct PackedByteArray index is significantly faster than a multi-arm
# match in GDScript — called ~30K times per worldgen chunk + ~30K times
# per lighting BFS pass.
static var _light_opacity_lut: PackedByteArray


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
		and id != WOOD_STAIRS
		and id != COBBLESTONE_STAIRS
		and id != WOODEN_DOOR
		and id != IRON_DOOR
		and id != LADDER
		# Flowers + mushrooms render as cross-quads like saplings — opaque
		# treatment would cull the dirt/grass face below them, leaving a
		# punch-through hole when the cross shader discards the corners.
		and id != FLOWER_RED
		and id != FLOWER_YELLOW
		and id != MUSHROOM_BROWN
		and id != MUSHROOM_RED
		and id != SUGAR_CANE
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
	# Flowers + mushrooms — cross-quad blocks pass light through, same as
	# SAPLING. Vanilla mr.java extends ok which extends nq with no opacity
	# override → defaults to 0 (transparent).
	_light_opacity_lut[FLOWER_RED] = 0
	_light_opacity_lut[FLOWER_YELLOW] = 0
	_light_opacity_lut[MUSHROOM_BROWN] = 0
	_light_opacity_lut[MUSHROOM_RED] = 0
	_light_opacity_lut[SUGAR_CANE] = 0


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
		# Vanilla gd.java:13 `co.b(x, y, z, x+1, y+1.5, z+1)` — full cell
		# width, 1.5 high so the highlight wraps the half-block extension
		# above the cell that prevents the player from hopping over.
		return AABB(Vector3.ZERO, Vector3(1.0, 1.5, 1.0))
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
	return AABB(Vector3.ZERO, Vector3.ONE)


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
		or id == FIRE
		or id == FLOWER_RED
		or id == FLOWER_YELLOW
		or id == MUSHROOM_BROWN
		or id == MUSHROOM_RED
		or id == SUGAR_CANE
	):
		return MESH_SHAPE_CROSS
	if id == TORCH:
		return MESH_SHAPE_TORCH
	if id == CHEST:
		return MESH_SHAPE_EXTERNAL
	if id == FENCE:
		return MESH_SHAPE_FENCE
	if id == WOOD_STAIRS or id == COBBLESTONE_STAIRS:
		return MESH_SHAPE_STAIRS
	if id == WOODEN_DOOR or id == IRON_DOOR:
		return MESH_SHAPE_DOOR
	if id == LADDER:
		return MESH_SHAPE_LADDER
	return MESH_SHAPE_CUBE


# True if the mesher should hand this block to the GDScript path even
# when the native MesherNative GDExtension is loaded. Native handles only
# CUBE today; non-cube shapes are sparse enough that doing them in
# GDScript per chunk has negligible cost.
static func needs_gdscript_mesher(id: int) -> bool:
	return mesh_shape(id) != MESH_SHAPE_CUBE


# Vanilla `Block.getExplosionResistance` — how much a block resists the
# blast wave from TNT / creepers. The explosion ray loses
# `(resistance + 0.3) × 0.225` intensity per 0.3-block step, so a 4.0-power
# TNT blast (initial ~3 intensity per ray) breaks ~3 blocks of stone deep
# but ~0 blocks of cobblestone (cobble's resistance 30 is a vanilla
# anomaly — the recipe is faster to mine but tougher to explode). Bedrock
# and obsidian use absurd values so they're effectively immune to TNT.
# Numbers come from Bukkit/mc-dev (Beta-faithful; Alpha used the same
# values for the few blocks it had).
static func explosion_resistance(id: int) -> float:
	match id:
		BEDROCK:
			return 6000000.0
		OBSIDIAN:
			return 2000.0
		COBBLESTONE, COBBLESTONE_STAIRS:
			return 30.0
		WATER_FLOWING, WATER_STILL, LAVA_FLOWING, LAVA_STILL:
			return 500.0
		IRON_DOOR:
			return 25.0
		STONE, BRICK, FURNACE, LIT_FURNACE, IRON_ORE, COAL_ORE, GOLD_ORE, DIAMOND_ORE:
			return 6.0
		WOODEN_DOOR:
			return 15.0
		LOG, PLANKS, CRAFTING_TABLE, FENCE, WOOD_STAIRS, CHEST, LADDER:
			return 2.5
	# Soft / replaceable blocks — air, plants, sand, dirt, leaves, glass,
	# torch, fire, sapling, TNT. Vanilla TNT resistance is 0 specifically
	# so a TNT cell offers no shielding to the next chained TNT — keeps
	# stack chain reactions punchy.
	return 0.0


# Block hardness — base for all break-time math. Vanilla MC values, in
# "block-hardness units" not seconds. Final time = hardness × multiplier
# (1.5 if correct tool, 5.0 if wrong/no tool) ÷ tool speed.
static func hardness(id: int) -> float:
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
		SAPLING, TORCH, FLOWER_RED, FLOWER_YELLOW, MUSHROOM_BROWN, MUSHROOM_RED, SUGAR_CANE:
			return 0.0  # vanilla: instant break
		DIRT, SAND:
			return 0.5
		GRASS, FARMLAND, GRAVEL:
			return 0.6
		LADDER:
			return 0.4  # ca.java `c(0.4f)` — soft wood, quick break
		TNT:
			return 0.0  # v.java `c(0.0f)` — instant break (still drops the block)
		LOG, PLANKS, CRAFTING_TABLE, FENCE, WOOD_STAIRS, COBBLESTONE_STAIRS:
			# mb.java:14 `this.c(nq2.bi)` — inherits parent hardness (2.0).
			return 2.0
		WOODEN_DOOR:
			return 3.0  # gv.java: nq.aE `c(3.0f)` — wood door
		IRON_DOOR:
			return 5.0  # gv.java: nq.aL `c(5.0f)` — iron door
		CHEST:
			return 2.5  # c.java:c(2.5f) — slightly tougher than planks
		STONE, COBBLESTONE, BRICK:
			return 1.5
		FURNACE, LIT_FURNACE:
			return 3.5
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return 3.0
		OBSIDIAN:
			return 50.0
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
	return 0


# Which tool type is "correct" for break-speed bonus (see Items.TOOL_TYPE_*).
# 0 = any/none (no bonus from any tool). Mirrors vanilla ItemPickaxe's block list.
static func preferred_tool_type(id: int) -> int:
	match id:
		STONE, COBBLESTONE, COBBLESTONE_STAIRS, BRICK, OBSIDIAN:
			return Items.TOOL_TYPE_PICKAXE
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return Items.TOOL_TYPE_PICKAXE
		FURNACE, LIT_FURNACE:
			return Items.TOOL_TYPE_PICKAXE
		LOG, PLANKS, CHEST, FENCE, WOOD_STAIRS, WOODEN_DOOR, LADDER:
			return Items.TOOL_TYPE_AXE
		IRON_DOOR:
			return Items.TOOL_TYPE_PICKAXE
		DIRT, GRASS, SAND, FARMLAND, GRAVEL:
			return Items.TOOL_TYPE_SHOVEL
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
		SAPLING:
			return SAPLING  # drops itself when broken
		FLOWER_RED, FLOWER_YELLOW, MUSHROOM_BROWN, MUSHROOM_RED:
			return id  # plants drop themselves
		SUGAR_CANE:
			return Items.SUGAR_CANE  # drops as ITEM (re-place via item)
		BEDROCK:
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
	return id


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
	return "unknown"


# Returns the texture name for a given block face. face ∈ {"top", "bottom", "side"}
static func get_face_texture(id: int, face: String) -> String:
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
