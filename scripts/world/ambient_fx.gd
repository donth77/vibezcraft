class_name AmbientFx
extends RefCounted

# Random-tick ambient effects for lava + fire cells near the player —
# port of vanilla `f.java` randomDisplayTick plus
# `ld.java:188-199` (ParticleLava at 1/100 on air-above lava) and
# `qh.java:186-238` (fire.fire sound at 1/24 + largesmoke on flammable
# neighbors). Factored out of ChunkManager to keep that file under the
# 1000-line linter cap; `tick` is called at Alpha's 20 Hz cadence on
# desktop and at a reduced 5 Hz cadence on mobile web.
#
# Vanilla runs 1000 random-cell rolls per 20 Hz client tick in a 16-block cube
# centered on the player (nextInt(16) - nextInt(16) yields a triangular
# distribution ±15, mode 0), for 20k rolls/sec. Desktop runs that same
# cadence; mobile web retains an explicit reduced budget below.

const _CELLS_PER_SCAN: int = 1000
# Mobile-web budget. The 1000-cell interpreted loop measured 12.5 ms per
# scan on a mid-tier phone proxy, usually
# hunting for zero lava/fire/torch cells. 250 keeps every effect — sparks
# just take a few seconds to ramp near a lava pour instead of ~1 s, which
# a phone screen hides. Desktop keeps vanilla density.
const _CELLS_PER_SCAN_MOBILE_WEB: int = 250
# Matches vanilla's nextInt(16) - nextInt(16): triangular distribution
# over [-15, 15] with peak at 0, concentrating rolls near the player.
const _SCAN_RADIUS: int = 15


# One scan pass. Rolls _CELLS_PER_SCAN random cells in a block-radius
# window around the player and dispatches effects based on cell id.
# `manager` is the ChunkManager (needed only by the rare effect callbacks
# for particle spawn parenting); `chunks` is the manager's `_chunks` dict
# (coord → ChunkNode) used for the hot 1000-cell read loop without going
# through manager.call("get_world_block", ...) — that dynamic dispatch
# alone was costing ~3 ms per tick at the 10 Hz cadence.
static func tick(manager: Node, chunks: Dictionary, player_pos: Vector3) -> void:
	var px: int = int(floor(player_pos.x))
	var py: int = int(floor(player_pos.y))
	var pz: int = int(floor(player_pos.z))
	var pcx: int = px >> 4
	var pcz: int = pz >> 4
	# Pre-fetch the 3x3 chunk window in one pass. The scan radius is 15
	# blocks centered on the player, so every candidate cell lands in
	# pcx ± 1, pcz ± 1 — at most 9 chunks. Resolving these once up front
	# replaces the per-iteration chunks.has + dict get (which the single-
	# slot cache only avoided ~25% of the time due to the triangular
	# distribution spreading cells across the 4 player-corner chunks).
	# Net: ~1500-2000 dict lookups → 9 dict lookups per scan.
	var nine_chunks: Array = []
	nine_chunks.resize(9)
	for dcz in range(-1, 2):
		for dcx in range(-1, 2):
			var cc := Vector2i(pcx + dcx, pcz + dcz)
			var c: Chunk = null
			if chunks.has(cc):
				c = (chunks[cc] as Node3D).chunk
			nine_chunks[(dcz + 1) * 3 + (dcx + 1)] = c
	# Static context — check OS directly rather than Game.is_mobile_web().
	# Two has_feature lookups per scan is noise.
	var mobile_web: bool = OS.has_feature("web_android") or OS.has_feature("web_ios")
	var cells: int = _CELLS_PER_SCAN_MOBILE_WEB if mobile_web else _CELLS_PER_SCAN
	for _i in range(cells):
		var dx: int = randi_range(0, _SCAN_RADIUS) - randi_range(0, _SCAN_RADIUS)
		var dy: int = randi_range(0, _SCAN_RADIUS) - randi_range(0, _SCAN_RADIUS)
		var dz: int = randi_range(0, _SCAN_RADIUS) - randi_range(0, _SCAN_RADIUS)
		var wx: int = px + dx
		var wy: int = py + dy
		var wz: int = pz + dz
		if wy < 1 or wy >= Chunk.SIZE_Y - 1:
			continue
		# Direct array index into the prefetched 3x3 window. The shift
		# handles negative wx correctly (Python-style: -1 >> 4 == -1).
		var ddx: int = (wx >> 4) - pcx + 1
		var ddz: int = (wz >> 4) - pcz + 1
		if ddx < 0 or ddx > 2 or ddz < 0 or ddz > 2:
			continue  # outside the 3x3 window (only at scan-radius corners)
		var chunk_here: Chunk = nine_chunks[ddz * 3 + ddx] as Chunk
		if chunk_here == null:
			continue
		var id: int = chunk_here.get_block(wx & 15, wy, wz & 15)
		if Blocks.is_lava(id):
			_lava(manager, wx, wy, wz)
		elif id == Blocks.FIRE:
			_fire(manager, wx, wy, wz)
		elif id == Blocks.TORCH:
			_torch(manager, wx, wy, wz)
		elif id == Blocks.REDSTONE_REPEATER_ON:
			_repeater(manager, wx, wy, wz)


# Lava-cell ambient: only fires when the cell directly above is AIR
# (matches vanilla ld.java:193 `f(x, y+1, z) == hb.a`). Vanilla ld.java:193
# rolls `nextInt(100) == 0` (1/100 per cell per scan). We previously used
# 1/4 which produced ~25× too many sparks for large pools — visual was a
# "fountain of specks" instead of vanilla's occasional lazy popper.
static func _lava(manager: Node, wx: int, wy: int, wz: int) -> void:
	var above: int = manager.call("get_world_block", Vector3i(wx, wy + 1, wz)) as int
	if above != Blocks.AIR:
		return
	# ld.java:197: one lava particle on one in every 100 selected lava cells.
	if randi() % 100 != 0:
		return
	# Vanilla ld.java:197 spawns the "lava" particle silently — no SFX.
	FluidFx.spawn_lava_spark(manager, Vector3i(wx, wy, wz))


# Fire-cell ambient: crackle sound + smoke puff. qh.java:186-188 rolls
# 1-in-24 for the sound. We gate the crackle by remaining fire life —
# short-lived fire (placed on a non-flammable surface like grass, lasts
# ~2 s before age>3 extinction) shouldn't fire a crackle in its last
# tick: fire.ogg is 1.82 s long at pitch 1.0 and STRETCHES to ~6 s at
# pitch 0.3, so a crackle that starts at 1.5 s outlasts the fire by
# several seconds. Skip when the cell is one or two ticks from
# extinguishing AND there are no flammable neighbors keeping it alive.
static func _fire(manager: Node, wx: int, wy: int, wz: int) -> void:
	if randi() % 24 == 0:
		if not _fire_about_to_die(manager, wx, wy, wz):
			SFX.play_fire_crackle()
	# Smoke disabled — never got the particles to render right (squished
	# sprite look even through the lava-fizz pool). Vanilla qh.java:189-
	# 236 emits one `largesmoke` per flammable-adjacent face per random
	# tick; revisit when a dedicated emitter looks correct.


# True if the fire cell will extinguish within ~1 tick. Used to skip the
# crackle SFX so a 1.82-2 s clip doesn't outlast a fire that's about to
# go out. Mirrors the extinction check in BlockFire.update (Step 2): no
# flammable neighbor + opaque floor + age > 3 → next tick extinguishes.
static func _fire_about_to_die(manager: Node, wx: int, wy: int, wz: int) -> bool:
	var pos := Vector3i(wx, wy, wz)
	var age: int = manager.get_world_block_meta(pos)
	if age < 3:
		return false
	for o: Vector3i in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]:
		if BlockFire.can_catch_fire(manager.get_world_block(pos + o)):
			return false
	return true


# Torch-cell ambient: flame + smoke at the torch tip, meta-aware so wall
# torches' particles end up on the leaning side. ob.java:140-162 emits one
# smoke + one flame every time World's display-tick scan selects the cell;
# there is no additional per-torch probability gate.
static func _torch(manager: Node, wx: int, wy: int, wz: int) -> void:
	var meta: int = manager.call("get_world_block_meta", Vector3i(wx, wy, wz)) as int
	FluidFx.spawn_torch_particles(manager, Vector3i(wx, wy, wz), meta)


# Powered Beta 1.3 repeater display tick. BlockRedstoneRepeater chooses
# either the fixed output torch or the movable delay torch with equal
# probability, then jitters one fullbright reddust mote around its tip.
static func _repeater(manager: Node, wx: int, wy: int, wz: int) -> void:
	var pos := Vector3i(wx, wy, wz)
	var meta: int = manager.call("get_world_block_meta", pos) as int
	var output: Vector3 = Vector3(Redstone.repeater_output_offset(meta))
	var local_offset: Vector3
	if randi() % 2 == 0:
		local_offset = output * 0.3125
	else:
		local_offset = -output * Redstone.repeater_torch_offset(meta)
	BlockFx.spawn_reddust_at(manager, Vector3(pos) + Vector3(0.5, 0.4, 0.5) + local_offset)
