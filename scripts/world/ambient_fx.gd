class_name AmbientFx
extends RefCounted

# Random-tick ambient effects for lava + fire cells near the player —
# port of vanilla `f.java` randomDisplayTick plus
# `ld.java:188-199` (ParticleLava at 1/100 on air-above lava) and
# `qh.java:186-238` (fire.fire sound at 1/24 + largesmoke on flammable
# neighbors). Factored out of ChunkManager to keep that file under the
# 1000-line linter cap; `tick` is called at 10 Hz by the manager.
#
# Vanilla runs 1000 random-cell rolls per frame in a 16-block cube
# centered on the player (nextInt(16) - nextInt(16) yields a triangular
# distribution ±15, mode 0). At 60 FPS that's ~60k rolls/sec across
# ~32k cells. We hit the same density at 10 Hz by rolling 1000
# cells/scan = 10k/sec, enough to fire sparks within a second or two
# when a small lava pour sits next to the player.

const _CELLS_PER_SCAN: int = 1000
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
	# Net: ~1500-2000 dict lookups → 9 dict lookups per tick.
	var nine_chunks: Array = []
	nine_chunks.resize(9)
	for dcz in range(-1, 2):
		for dcx in range(-1, 2):
			var cc := Vector2i(pcx + dcx, pcz + dcz)
			var c: Chunk = null
			if chunks.has(cc):
				c = (chunks[cc] as Node3D).chunk
			nine_chunks[(dcz + 1) * 3 + (dcx + 1)] = c
	for _i in range(_CELLS_PER_SCAN):
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


# Lava-cell ambient: only fires when the cell directly above is AIR
# (matches vanilla ld.java:193 `f(x, y+1, z) == hb.a`). Vanilla ld.java:193
# rolls `nextInt(100) == 0` (1/100 per cell per scan). We previously used
# 1/4 which produced ~25× too many sparks for large pools — visual was a
# "fountain of specks" instead of vanilla's occasional lazy popper.
static func _lava(manager: Node, wx: int, wy: int, wz: int) -> void:
	var above: int = manager.call("get_world_block", Vector3i(wx, wy + 1, wz)) as int
	if above != Blocks.AIR:
		return
	# Vanilla ld.java:197 rolls 1/100 at 60 FPS = 60k rolls/sec; we run
	# at 10 Hz × 1000 rolls = 10k rolls/sec, so 1/100 here gives 6× LESS
	# spark density than vanilla. 1/16 lands close to vanilla's effective
	# per-second rate without becoming the prior "fountain."
	if randi() % 16 != 0:
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
	if randi() % 4 == 0:
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
# torches' particles end up on the leaning side. Mirrors `bk.b`
# (BlockTorch.randomDisplayTick) which spawns one smoke + one flame per
# roll. Vanilla rolls 1/anything-low here since torches are common; we
# gate at 1-in-3 so a 10 Hz × 1000-cell scan with a few torches in range
# produces roughly the vanilla density without flooding the pool.
static func _torch(manager: Node, wx: int, wy: int, wz: int) -> void:
	if randi() % 3 != 0:
		return
	var meta: int = manager.call("get_world_block_meta", Vector3i(wx, wy, wz)) as int
	FluidFx.spawn_torch_particles(manager, Vector3i(wx, wy, wz), meta)
