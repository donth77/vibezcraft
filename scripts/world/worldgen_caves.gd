# NOTE: no `class_name` — loaded via preload() in worldgen.gd to avoid the
# circular class_name cycle (Worldgen ↔ this file).
extends RefCounted

# Alpha 1.2.6 cave generator. Bit-exact port of:
#   vendor/alpha-1.2.6-src/src/lx.java (MapGenCaves)
#   vendor/alpha-1.2.6-src/src/dl.java (MapGenBase — radius=8 cross-chunk loop
#                                         with per-chunk Random re-seeding)
#
# SEEDING RITUAL (dl.java:10-20)
#   random.setSeed(worldSeed)
#   l2 = random.nextLong() / 2L * 2L + 1L   // odd multiplier
#   l3 = random.nextLong() / 2L * 2L + 1L
#   for each (i2, i3) in the 17×17 chunk square around the target:
#     random.setSeed((long)i2 * l2 + (long)i3 * l3 ^ worldSeed)
#     a(world, i2, i3, targetX, targetZ, blocks)  // inner generator
#
# Using our JavaRandom port (scripts/world/java_random.gd) this is
# bit-exact with vanilla — same worldSeed → same caves as Java Minecraft
# Alpha 1.2.6. Earlier hash-based PRNG produced ~7% cave coverage across
# chunks; JavaRandom produces Alpha's ~50%.
#
# Lava-fill below y=10 is live (lx.java:115-116) — carves at ay<10 write
# LAVA_STILL instead of AIR so deep caves have hazardous lava pools.

const _RADIUS_CHUNKS: int = 8  # dl.java:7 `this.a = 8`
# Vanilla `_CAVE_MAX_Y = 120` (lx.java:83). Cap at SEA_LEVEL - 5 = 59 so
# caves stay underground and don't break through ocean floors. Tried
# raising to 76 to allow surface caves but that re-introduced the
# underwater cave openings users found visually jarring. To restore
# vanilla (with surface caves and underwater entrances), set to 120.
const _CAVE_MAX_Y: int = 59


# Entry point called from worldgen.generate_chunk.
static func scatter(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.caves")
	# Port of dl.java:10-20 — seed multipliers derived from world seed,
	# then per-chunk re-seeding for each contributing seed chunk.
	var rng: JavaRandom = JavaRandom.new(Worldgen.WORLD_SEED)
	var l2: int = rng.next_long() / 2 * 2 + 1  # force odd
	var l3: int = rng.next_long() / 2 * 2 + 1
	for seed_cx in range(chunk_x - _RADIUS_CHUNKS, chunk_x + _RADIUS_CHUNKS + 1):
		for seed_cz in range(chunk_z - _RADIUS_CHUNKS, chunk_z + _RADIUS_CHUNKS + 1):
			rng.set_seed(seed_cx * l2 + seed_cz * l3 ^ Worldgen.WORLD_SEED)
			_spawn_from_seed_chunk(rng, chunk, chunk_x, chunk_z, seed_cx, seed_cz)
	PerfProbe.end("worldgen.caves", probe_token)


# lx.java:137-158 — the inner generator. `rng` is already seeded for
# (seed_cx, seed_cz) by the caller; we consume its sequence in the exact
# same order as Alpha so our output matches bit-for-bit.
static func _spawn_from_seed_chunk(
	rng: JavaRandom, chunk: Chunk, chunk_x: int, chunk_z: int, seed_cx: int, seed_cz: int
) -> void:
	# lx.java:138-141:
	#   n6 = b.nextInt(b.nextInt(b.nextInt(40)+1)+1)
	#   if (b.nextInt(15) != 0) n6 = 0
	var n_outer: int = rng.next_int_bounded(40) + 1
	var n_mid: int = rng.next_int_bounded(n_outer) + 1
	var cave_count: int = rng.next_int_bounded(n_mid)
	if rng.next_int_bounded(15) != 0:
		cave_count = 0
	for i in range(cave_count):
		# lx.java:143-145:
		#   d2 = n2*16 + b.nextInt(16)
		#   d3 = b.nextInt(b.nextInt(120)+8)
		#   d4 = n3*16 + b.nextInt(16)
		var x: float = float(seed_cx * 16 + rng.next_int_bounded(16))
		var y_outer: int = rng.next_int_bounded(120) + 8
		var y: float = float(rng.next_int_bounded(y_outer))
		var z: float = float(seed_cz * 16 + rng.next_int_bounded(16))
		# lx.java:146-150:
		#   n7 = 1
		#   if (b.nextInt(4) == 0) { a(small-room); n7 += b.nextInt(4) }
		var worm_count: int = 1
		if rng.next_int_bounded(4) == 0:
			# Room variant — the 6-arg `a()` call, lx.java:148 via lx.java:8-9.
			_carve_worm(
				rng,
				chunk,
				chunk_x,
				chunk_z,
				x,
				y,
				z,
				1.0 + rng.next_float() * 6.0,
				0.0,
				0.0,
				-1,
				-1,
				0.5
			)
			worm_count += rng.next_int_bounded(4)
		# lx.java:151-156:
		#   for (i3 = 0; i3 < n7; ++i3) {
		#     f2 = b.nextFloat() * PI * 2
		#     f3 = (b.nextFloat() - 0.5) * 2 / 8
		#     f4 = b.nextFloat() * 2 + b.nextFloat()
		#     a(full-worm, f2 yaw, f3 pitch, f4 width)
		#   }
		for w in range(worm_count):
			var yaw: float = rng.next_float() * TAU
			var pitch: float = (rng.next_float() - 0.5) * 2.0 / 8.0
			var width: float = rng.next_float() * 2.0 + rng.next_float()
			_carve_worm(rng, chunk, chunk_x, chunk_z, x, y, z, width, yaw, pitch, 0, 0, 1.0)


# Random-walk worm carve. Port of lx.java:10-135 —
#   a(int n2, int n3, byte[] byArray, double d2, double d3, double d4,
#     float f2, float f3, float f4, int n4, int n5, double d5)
# Arg mapping:
#   width (f2) = ellipsoid radius scalar
#   yaw (f3), pitch (f4) = direction with brownian drift per step
#   step (n4), length (n5) = progress; pass (-1, -1) for room variant
#   vertical_scale (d5) = vertical-radius multiplier (1.0 or 0.5)
static func _carve_worm(
	rng: JavaRandom,
	chunk: Chunk,
	chunk_x: int,
	chunk_z: int,
	init_x: float,
	init_y: float,
	init_z: float,
	width: float,
	init_yaw: float,
	init_pitch: float,
	init_step: int,
	init_length: int,
	vertical_scale: float
) -> void:
	# lx.java:12-20 — the inner `a(...)`'s preamble: new Random seeded
	# from the OUTER random's nextLong(), shadowing the class random.
	# The worm uses ITS OWN Random for path noise. This is Alpha's
	# mechanism for decoupling the worm's per-step drift from the
	# outer chunk-decoration stream.
	var worm_rng: JavaRandom = JavaRandom.new(rng.next_long())
	var origin_x: float = float(chunk_x * 16 + 8)
	var origin_z: float = float(chunk_z * 16 + 8)
	# lx.java:22-23 — length when unset. `this.a = 8` in dl.java, so
	# a*16 = 128, the base length, minus a small random offset.
	var length: int = init_length
	if length <= 0:
		var base: int = 128 - 16  # = 112
		length = base - worm_rng.next_int_bounded(base / 4)
	# lx.java:25-28 — room variant marker + mid-worm branch roll.
	var step: int = init_step
	var is_room: bool = false
	if step == -1:
		step = length / 2
		is_room = true
	var branch_step: int = worm_rng.next_int_bounded(length / 2) + length / 4
	# lx.java:30 — a 1-in-6 "tight drift" flag that makes the worm
	# turn more slowly (0.92 vs 0.7 decay on yaw).
	var tight_drift: bool = worm_rng.next_int_bounded(6) == 0
	var yaw_accel: float = 0.0
	var pitch_accel: float = 0.0
	var pos_x: float = init_x
	var pos_y: float = init_y
	var pos_z: float = init_z
	var yaw: float = init_yaw
	var pitch: float = init_pitch
	# lx.java:32-134 — the step loop.
	while step < length:
		# lx.java:33-34 — ellipsoid radii peak at mid-path.
		var horiz_radius: float = 1.5 + sin(float(step) * PI / float(length)) * width
		var vert_radius: float = horiz_radius * vertical_scale
		# lx.java:36-40 — walk forward in direction (yaw, pitch).
		var cos_p: float = cos(pitch)
		pos_x += cos(yaw) * cos_p
		pos_y += sin(pitch)
		pos_z += sin(yaw) * cos_p
		# lx.java:41-47 — brownian drift on yaw + pitch. The *= 0.92 or
		# *= 0.7 decays drift magnitude; the random addends inject new
		# wobble each step.
		pitch *= 0.92 if tight_drift else 0.7
		pitch += pitch_accel * 0.1
		yaw += yaw_accel * 0.1
		pitch_accel *= 0.9
		yaw_accel *= 0.75
		pitch_accel += (
			(worm_rng.next_float() - worm_rng.next_float()) * worm_rng.next_float() * 2.0
		)
		yaw_accel += ((worm_rng.next_float() - worm_rng.next_float()) * worm_rng.next_float() * 4.0)
		# lx.java:49-57 — at the mid-point, non-room main worms with
		# width>1 spawn two branches at ±π/2 yaw and terminate.
		if not is_room and step == branch_step and width > 1.0:
			_carve_worm(
				rng,
				chunk,
				chunk_x,
				chunk_z,
				pos_x,
				pos_y,
				pos_z,
				worm_rng.next_float() * 0.5 + 0.5,
				yaw - PI / 2.0,
				pitch / 3.0,
				step,
				length,
				1.0
			)
			_carve_worm(
				rng,
				chunk,
				chunk_x,
				chunk_z,
				pos_x,
				pos_y,
				pos_z,
				worm_rng.next_float() * 0.5 + 0.5,
				yaw + PI / 2.0,
				pitch / 3.0,
				step,
				length,
				1.0
			)
			return
		# lx.java:58 — 3-in-4 steps carve; the other 1-in-4 just walk.
		# Room variants always carve (`n6 != 0` in Alpha — here is_room).
		if not is_room and worm_rng.next_int_bounded(4) == 0:
			step += 1
			continue
		# lx.java:59-63 — early-abort if the cave has wandered too far
		# to reach the target chunk even with all remaining steps.
		var dx: float = pos_x - origin_x
		var dz: float = pos_z - origin_z
		var steps_remaining: float = float(length - step)
		var max_reach: float = width + 2.0 + 16.0
		if dx * dx + dz * dz - steps_remaining * steps_remaining > max_reach * max_reach:
			return
		# lx.java:65-68 — quick AABB bounds test: if the carve sphere is
		# entirely outside the target chunk, skip carving but keep walking.
		if (
			pos_x < origin_x - 16.0 - horiz_radius * 2.0
			or pos_z < origin_z - 16.0 - horiz_radius * 2.0
			or pos_x > origin_x + 16.0 + horiz_radius * 2.0
			or pos_z > origin_z + 16.0 + horiz_radius * 2.0
		):
			step += 1
			continue
		# lx.java:69-85 — compute carve AABB in local chunk coords, clip.
		var carve_min_x: int = maxi(int(floor(pos_x - horiz_radius)) - chunk_x * 16 - 1, 0)
		var carve_max_x: int = mini(
			int(floor(pos_x + horiz_radius)) - chunk_x * 16 + 1, Chunk.SIZE_X
		)
		var carve_min_y: int = maxi(int(floor(pos_y - vert_radius)) - 1, 1)
		var carve_max_y: int = mini(int(floor(pos_y + vert_radius)) + 1, _CAVE_MAX_Y)
		var carve_min_z: int = maxi(int(floor(pos_z - horiz_radius)) - chunk_z * 16 - 1, 0)
		var carve_max_z: int = mini(
			int(floor(pos_z + horiz_radius)) - chunk_z * 16 + 1, Chunk.SIZE_Z
		)
		# lx.java:86-99 — water-abort scan. If any cell in the carve AABB
		# is already water (from lakes or ocean fill), skip the carve
		# entirely to avoid punching into water volumes.
		if _aabb_touches_water(
			chunk, carve_min_x, carve_max_x, carve_min_y, carve_max_y, carve_min_z, carve_max_z
		):
			step += 1
			continue
		_carve_ellipsoid(
			chunk,
			chunk_x,
			chunk_z,
			pos_x,
			pos_y,
			pos_z,
			horiz_radius,
			vert_radius,
			carve_min_x,
			carve_max_x,
			carve_min_y,
			carve_max_y,
			carve_min_z,
			carve_max_z
		)
		if is_room:
			break
		step += 1


static func _aabb_touches_water(
	chunk: Chunk, mnx: int, mxx: int, mny: int, mxy: int, mnz: int, mxz: int
) -> bool:
	for ax in range(mnx, mxx):
		for az in range(mnz, mxz):
			for ay in range(maxi(mny, 0), mini(mxy + 1, Chunk.SIZE_Y)):
				if Blocks.is_water(chunk.get_block_unchecked(ax, ay, az)):
					return true
	return false


# lx.java:101-128 — carve cells inside the ellipsoid defined by (pos,
# horiz_r, vert_r). The `d16 > -0.7` clip leaves a thin floor strip at
# the bottom of each carve, so caves never have dead-flat floors.
static func _carve_ellipsoid(
	chunk: Chunk,
	chunk_x: int,
	chunk_z: int,
	pos_x: float,
	pos_y: float,
	pos_z: float,
	horiz_r: float,
	vert_r: float,
	mnx: int,
	mxx: int,
	mny: int,
	mxy: int,
	mnz: int,
	mxz: int
) -> void:
	for ax in range(mnx, mxx):
		var nx: float = (float(ax + chunk_x * 16) + 0.5 - pos_x) / horiz_r
		var nx2: float = nx * nx
		for az in range(mnz, mxz):
			var nz: float = (float(az + chunk_z * 16) + 0.5 - pos_z) / horiz_r
			var nz2: float = nz * nz
			var saw_grass: bool = false
			# Top-down scan so we detect GRASS before the DIRT below it.
			for ay in range(mxy - 1, mny - 1, -1):
				if ay < 1 or ay >= _CAVE_MAX_Y:
					continue
				var ny: float = (float(ay) + 0.5 - pos_y) / vert_r
				if ny <= -0.7:
					continue
				if nx2 + ny * ny + nz2 >= 1.0:
					continue
				var id: int = chunk.get_block_unchecked(ax, ay, az)
				if id == Blocks.GRASS:
					saw_grass = true
				if id != Blocks.STONE and id != Blocks.DIRT and id != Blocks.GRASS:
					continue
				# lx.java:115-116 — ay=10 is the vanilla lava-floor
				# threshold: strictly below that, the carve writes
				# LAVA_STILL instead of AIR, producing the cave-floor
				# lava pools that are the main hazard in early-game
				# exploration. Everything above stays AIR.
				if ay < 10:
					chunk.set_block_unchecked(ax, ay, az, Blocks.LAVA_STILL)
				else:
					chunk.set_block_unchecked(ax, ay, az, Blocks.AIR)
				if saw_grass and ay > 0:
					if chunk.get_block_unchecked(ax, ay - 1, az) == Blocks.DIRT:
						chunk.set_block_unchecked(ax, ay - 1, az, Blocks.GRASS)
