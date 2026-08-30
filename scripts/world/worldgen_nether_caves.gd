class_name WorldgenNetherCaves
extends RefCounted

# Alpha 1.2.6 Nether caves — a port of `ju.java` plus the `dl.java`
# (MapGenBase) driver it extends. See the plan's §6.4.
#
# Unlike the Overworld cave port in worldgen_caves.gd, which follows the
# shape of the algorithm with double-precision trig, this one is
# BIT-EXACT against the source, because the plan gates Nether terrain on
# full-chunk hashes matching an oracle that runs the real `ju.java`.
#
# Two things make that harder than it looks, and both are load-bearing:
#
#   1. Alpha does not call Math.sin. `fi.java` builds a 65536-entry table
#      of FLOAT sines once and indexes it with `(int)(angle * 10430.378f)
#      & 0xFFFF`. The table's quantisation is coarse enough to change
#      which blocks a tunnel clips.
#   2. The worm's yaw, pitch and drift are Java `float`s. Every multiply
#      and add rounds to 32 bits. Carrying them as GDScript doubles
#      accumulates a different path within a few dozen steps.
#
# `_f32` pins every float expression; `_sin` / `_cos` are the table.
# Where the source uses doubles (positions, radii) this port does too.

const _CHUNK_VOLUME: int = 32768

# Raw Alpha ids — caves run before the project remap, on the source's own
# byte values. Mirrors WorldgenNether's constants.
const _ALPHA_AIR: int = 0
const _ALPHA_GRASS: int = 2
const _ALPHA_DIRT: int = 3
const _ALPHA_LAVA_FLOWING: int = 10
const _ALPHA_LAVA_STILL: int = 11
const _ALPHA_NETHERRACK: int = 87

# dl.java:6 — the neighbourhood radius in chunks. Every chunk within 8 of
# the target contributes its own worms, which is what makes tunnels cross
# chunk borders seamlessly and independently of load order.
const _NEIGHBOURHOOD: int = 8

# ju.java:110 — carving stops at this Y, and at 1 below. Keeps the
# bedrock shell intact.
const _MAX_CARVE_Y: int = 120
const _MIN_CARVE_Y: int = 1

# Alpha's MathHelper lives in AlphaMath now — Batch 7 extracted it so the
# portal texture could share the same table. These thin aliases keep the
# call sites below reading like the Java they mirror.


static func _sin(angle: float) -> float:
	return AlphaMath.sin_table(angle)


static func _cos(angle: float) -> float:
	return AlphaMath.cos_table(angle)


static func _floor(v: float) -> int:
	return AlphaMath.floor_int(v)


static func _f32(v: float) -> float:
	return AlphaMath.f32(v)


static func _fmul(a: float, b: float) -> float:
	return AlphaMath.fmul(a, b)


static func _fdiv(a: float, b: float) -> float:
	return AlphaMath.fdiv(a, b)


static func _fadd(a: float, b: float) -> float:
	return AlphaMath.fadd(a, b)


static func _fsub(a: float, b: float) -> float:
	return AlphaMath.fsub(a, b)


# --- dl.java: the per-neighbourhood driver ---


# Carve every worm that reaches this chunk. `blocks` is a raw Alpha-layout
# chunk array, mutated in place.
#
# Order independence comes straight from the source: the seed for each
# contributing chunk is derived from its own coordinates, so the result
# depends only on (world seed, target chunk), never on what has been
# generated already.
static func carve(blocks: PackedByteArray, chunk_x: int, chunk_z: int) -> void:
	var world_seed: int = Worldgen.WORLD_SEED
	var rng := JavaRandom.new(world_seed)
	# dl.java:12-13. next_long, NOT the legacy unsigned-low variant the
	# Overworld caves are pinned to — this is new code, so it uses the
	# Alpha-correct nextLong (see java_random.gd).
	var mul_x: int = rng.next_long() / 2 * 2 + 1
	var mul_z: int = rng.next_long() / 2 * 2 + 1
	for source_x: int in range(chunk_x - _NEIGHBOURHOOD, chunk_x + _NEIGHBOURHOOD + 1):
		for source_z: int in range(chunk_z - _NEIGHBOURHOOD, chunk_z + _NEIGHBOURHOOD + 1):
			rng.set_seed(source_x * mul_x + source_z * mul_z ^ world_seed)
			_spawn_from_source_chunk(rng, blocks, source_x, source_z, chunk_x, chunk_z)


# ju.java:117-146 — how many worms one source chunk contributes.
static func _spawn_from_source_chunk(
	rng: JavaRandom,
	blocks: PackedByteArray,
	source_x: int,
	source_z: int,
	target_x: int,
	target_z: int
) -> void:
	# Triple-nested nextInt: heavily short-biased, so most chunks spawn
	# nothing at all even before the 1-in-5 gate below.
	var count: int = rng.next_int_bounded(rng.next_int_bounded(rng.next_int_bounded(10) + 1) + 1)
	if rng.next_int_bounded(5) != 0:
		count = 0
	for _i: int in range(count):
		var x: float = float(source_x * 16 + rng.next_int_bounded(16))
		var y: float = float(rng.next_int_bounded(128))
		var z: float = float(source_z * 16 + rng.next_int_bounded(16))
		var branches: int = 1
		if rng.next_int_bounded(4) == 0:
			# ju.java:9 — the wide "room" variant, width 1 + nextFloat * 6,
			# no pitch, and the -1 step marker that makes it stop after one
			# carve.
			_carve_worm(
				rng,
				blocks,
				target_x,
				target_z,
				x,
				y,
				z,
				_fadd(1.0, _fmul(rng.next_float(), 6.0)),
				0.0,
				0.0,
				-1,
				-1,
				0.5
			)
			branches += rng.next_int_bounded(4)
		for _b: int in range(branches):
			# ju.java:139-141 — `nextFloat() * (float)PI * 2.0f`,
			# `(nextFloat() - 0.5f) * 2.0f / 8.0f`, and
			# `nextFloat() * 2.0f + nextFloat()`, each rounded per operation.
			var yaw: float = _fmul(_fmul(rng.next_float(), AlphaMath.PI_F32), 2.0)
			var pitch: float = _fdiv(_fmul(_fsub(rng.next_float(), 0.5), 2.0), 8.0)
			var width: float = _fadd(_fmul(rng.next_float(), 2.0), rng.next_float())
			_carve_worm(
				rng, blocks, target_x, target_z, x, y, z, _fmul(width, 2.0), yaw, pitch, 0, 0, 0.5
			)


# --- ju.java:16-115 — one tunnel ---


# gdlint: disable=max-line-length
static func _carve_worm(
	outer_rng: JavaRandom,
	blocks: PackedByteArray,
	chunk_x: int,
	chunk_z: int,
	pos_x: float,
	pos_y: float,
	pos_z: float,
	width: float,
	yaw: float,
	pitch: float,
	step: int,
	length: int,
	vertical_scale: float
) -> void:
	var centre_x: float = float(chunk_x * 16 + 8)
	var centre_z: float = float(chunk_z * 16 + 8)
	var yaw_drift: float = 0.0
	var pitch_drift: float = 0.0
	# ju.java:22 — the worm gets its OWN Random, seeded from the outer
	# stream. That decouples its path noise from the chunk-decoration
	# sequence, so a longer worm cannot shift what the next one does.
	var rng := JavaRandom.new(outer_rng.next_long())
	if length <= 0:
		var span: int = _NEIGHBOURHOOD * 16 - 16
		length = span - rng.next_int_bounded(span / 4)
	var is_room: bool = false
	if step == -1:
		step = length / 2
		is_room = true
	var branch_step: int = rng.next_int_bounded(length / 2) + length / 4
	# ju.java:30 — a 1-in-6 flag that decays yaw more slowly, giving long
	# straight tunnels instead of tight curls.
	var wide_turn: bool = rng.next_int_bounded(6) == 0

	while step < length:
		# ju.java:32-33 — radius peaks at mid-path.
		# ju.java:32 — `1.5 + (double)(fi.a((float)n4 * (float)PI /
		# (float)n5) * f2 * 1.0f)`. The trig argument and the product are
		# float; only the leading `1.5 +` happens in double.
		var phase: float = _fdiv(_fmul(float(step), AlphaMath.PI_F32), float(length))
		var horiz_radius: float = 1.5 + _fmul(_fmul(_sin(phase), width), 1.0)
		var vert_radius: float = horiz_radius * vertical_scale
		var cos_pitch: float = _cos(pitch)
		var sin_pitch: float = _sin(pitch)
		pos_x += _fmul(_cos(yaw), cos_pitch)
		pos_y += sin_pitch
		pos_z += _fmul(_sin(yaw), cos_pitch)
		# ju.java:38-45, in this exact order. Pitch decays, then picks up its
		# drift; yaw picks up its drift; both drifts decay; then both gain
		# fresh wobble. Reordering any pair changes the tunnel.
		pitch = _fmul(pitch, 0.92 if wide_turn else 0.7)
		pitch = _fadd(pitch, _fmul(pitch_drift, 0.1))
		yaw = _fadd(yaw, _fmul(yaw_drift, 0.1))
		pitch_drift = _fmul(pitch_drift, 0.9)
		yaw_drift = _fmul(yaw_drift, 0.75)
		pitch_drift = _fadd(
			pitch_drift,
			_fmul(_fmul(_fsub(rng.next_float(), rng.next_float()), rng.next_float()), 2.0)
		)
		yaw_drift = _fadd(
			yaw_drift,
			_fmul(_fmul(_fsub(rng.next_float(), rng.next_float()), rng.next_float()), 4.0)
		)

		# ju.java:46-50 — mid-path fork into two narrower tunnels, then
		# stop. Only for non-room worms wide enough to be worth splitting.
		if not is_room and step == branch_step and width > 1.0:
			# The two sub-tunnels take their WIDTH from the worm's own rng
			# but are seeded from the OUTER one: ju.java's recursive call is
			# `this.a(...)`, whose first act is `new Random(this.b.nextLong())`
			# — `this.b` being MapGenBase's class-level Random, not the local
			# `random` that shadows it inside the loop. Threading the worm's
			# rng here instead sends both branches down different tunnels.
			_carve_worm(
				outer_rng,
				blocks,
				chunk_x,
				chunk_z,
				pos_x,
				pos_y,
				pos_z,
				_fadd(_fmul(rng.next_float(), 0.5), 0.5),
				_fsub(yaw, 1.5707964),
				_fdiv(pitch, 3.0),
				step,
				length,
				1.0
			)
			_carve_worm(
				outer_rng,
				blocks,
				chunk_x,
				chunk_z,
				pos_x,
				pos_y,
				pos_z,
				_fadd(_fmul(rng.next_float(), 0.5), 0.5),
				_fadd(yaw, 1.5707964),
				_fdiv(pitch, 3.0),
				step,
				length,
				1.0
			)
			return

		# ju.java:52 — non-room worms skip 3 steps in 4. Rooms never skip.
		if is_room or rng.next_int_bounded(4) != 0:
			var dx: float = pos_x - centre_x
			var dz: float = pos_z - centre_z
			var remaining: float = float(length - step)
			# ju.java:56 — `f2 + 2.0f + 16.0f`, float arithmetic widened.
			var reach: float = _fadd(_fadd(width, 2.0), 16.0)
			# Give up once the worm can no longer reach this chunk even
			# travelling straight at it.
			if dx * dx + dz * dz - remaining * remaining > reach * reach:
				return
			if (
				pos_x >= centre_x - 16.0 - horiz_radius * 2.0
				and pos_z >= centre_z - 16.0 - horiz_radius * 2.0
				and pos_x <= centre_x + 16.0 + horiz_radius * 2.0
				and pos_z <= centre_z + 16.0 + horiz_radius * 2.0
			):
				var x0: int = maxi(_floor(pos_x - horiz_radius) - chunk_x * 16 - 1, 0)
				var x1: int = mini(_floor(pos_x + horiz_radius) - chunk_x * 16 + 1, 16)
				var y0: int = maxi(_floor(pos_y - vert_radius) - 1, _MIN_CARVE_Y)
				var y1: int = mini(_floor(pos_y + vert_radius) + 1, _MAX_CARVE_Y)
				var z0: int = maxi(_floor(pos_z - horiz_radius) - chunk_z * 16 - 1, 0)
				var z1: int = mini(_floor(pos_z + horiz_radius) - chunk_z * 16 + 1, 16)
				if not _touches_lava(blocks, x0, x1, y0, y1, z0, z1):
					_carve_ellipsoid(
						blocks,
						chunk_x,
						chunk_z,
						pos_x,
						pos_y,
						pos_z,
						horiz_radius,
						vert_radius,
						x0,
						x1,
						y0,
						y1,
						z0,
						z1
					)
					if is_room:
						break
		step += 1


# ju.java:81-94 — the lava safety scan. A candidate segment is abandoned
# entirely if any lava sits in its bounding box, which is what stops
# tunnels from draining the lava sea into themselves.
#
# The scan is deliberately sparse: the inner loop jumps straight to the
# bottom of the box unless it is on a boundary face, so it walks the SHELL
# rather than the volume. Reproducing that exactly matters — a dense scan
# would abort more often and carve fewer caves.
static func _touches_lava(
	blocks: PackedByteArray, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int
) -> bool:
	for x: int in range(x0, x1):
		for z: int in range(z0, z1):
			var y: int = y1 + 1
			while y >= y0 - 1:
				if y >= 0 and y < 128:
					var id: int = blocks[WorldgenNether.alpha_index(x, y, z)]
					if id == _ALPHA_LAVA_FLOWING or id == _ALPHA_LAVA_STILL:
						return true
					# On a boundary face the scan walks every Y; inside the
					# box it drops straight to the floor.
					if not (y == y0 - 1 or x == x0 or x == x1 - 1 or z == z0 or z == z1 - 1):
						y = y0
				y -= 1
	return false


# ju.java:96-113 — hollow out the ellipsoid. Only netherrack, dirt and
# grass are carveable, so a tunnel that reaches bedrock or lava stops at
# it instead of punching through.
static func _carve_ellipsoid(
	blocks: PackedByteArray,
	chunk_x: int,
	chunk_z: int,
	pos_x: float,
	pos_y: float,
	pos_z: float,
	horiz_radius: float,
	vert_radius: float,
	x0: int,
	x1: int,
	y0: int,
	y1: int,
	z0: int,
	z1: int
) -> void:
	for x: int in range(x0, x1):
		var nx: float = (float(x + chunk_x * 16) + 0.5 - pos_x) / horiz_radius
		for z: int in range(z0, z1):
			var nz: float = (float(z + chunk_z * 16) + 0.5 - pos_z) / horiz_radius
			# ju.java:100-112 — the write index starts at y1 while the loop
			# counter starts at y1 - 1, and the index is decremented at the
			# END of the body. The block that gets cleared is therefore
			# always ONE Y ABOVE the cell the ellipsoid test used.
			#
			# That reads like a bug in the source and very likely is one,
			# but it is the shipped behaviour: reproducing the test and the
			# write at the same Y carves visibly different caves, which is
			# how the oracle caught it. Keep the skew.
			for y: int in range(y1 - 1, y0 - 1, -1):
				var ny: float = (float(y) + 0.5 - pos_y) / vert_radius
				if ny <= -0.7:
					continue
				if nx * nx + ny * ny + nz * nz >= 1.0:
					continue
				var idx: int = WorldgenNether.alpha_index(x, y + 1, z)
				var id: int = blocks[idx]
				if id == _ALPHA_NETHERRACK or id == _ALPHA_DIRT or id == _ALPHA_GRASS:
					blocks[idx] = _ALPHA_AIR
