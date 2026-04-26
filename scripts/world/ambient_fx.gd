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
# `manager` is the ChunkManager (exposes `get_world_block`); `player_pos`
# is the player's world position (floored to block coords per axis).
static func tick(manager: Node, _player_coord: Vector2i, player_y: int) -> void:
	var player: Node = manager.get("_player") as Node
	if player == null:
		return
	var px: int = int(floor((player as Node3D).global_position.x))
	var pz: int = int(floor((player as Node3D).global_position.z))
	for _i in range(_CELLS_PER_SCAN):
		var dx: int = randi_range(0, _SCAN_RADIUS) - randi_range(0, _SCAN_RADIUS)
		var dy: int = randi_range(0, _SCAN_RADIUS) - randi_range(0, _SCAN_RADIUS)
		var dz: int = randi_range(0, _SCAN_RADIUS) - randi_range(0, _SCAN_RADIUS)
		var wx: int = px + dx
		var wy: int = player_y + dy
		var wz: int = pz + dz
		if wy < 1 or wy >= Chunk.SIZE_Y - 1:
			continue
		var id: int = manager.call("get_world_block", Vector3i(wx, wy, wz)) as int
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
# 1-in-24 for the sound.
static func _fire(manager: Node, wx: int, wy: int, wz: int) -> void:
	if randi() % 4 == 0:
		SFX.play_fire_crackle()
	if randi() % 2 == 0:
		FluidFx.spawn_fire_smoke(manager, Vector3i(wx, wy, wz))


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
