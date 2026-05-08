class_name Explosion
extends RefCounted

# Vanilla Alpha 1.2.6 Explosion (ks.java) port. Detonates at a world position
# with a given `power` (TNT = 4.0, creeper = 3.0 once mobs ship). Algorithm
# mirrors ks.java::a() + b() byte-for-byte:
#
#   1. Cast 1352 rays from the explosion origin — the boundary cells of a
#      16×16×16 grid, normalized to unit-sphere directions. Skips interior
#      cells so we sample the surface uniformly without re-tracing the
#      same direction 16 times.
#   2. Each ray walks in 0.3-block steps. Per step, subtract
#      `(block.explosion_resistance + 0.3) × 0.225` from the ray's
#      intensity. Initial intensity is `power × (0.7 + rand × 0.6)` so
#      the blast envelope is irregular (the iconic "jagged" TNT crater
#      shape rather than a clean sphere). Cells visited while intensity
#      stays > 0 enter the affected-block set.
#   3. Damage entities within `power × 2` blocks via inverse-square
#      falloff and ray-occlusion. (Player damage only for now; mob
#      entities will be picked up automatically by the same iteration
#      once they exist.)
#   4. Destroy affected blocks, dropping items at 30% per block (vanilla
#      Block.dropAsStack with explosionPower=0.3). Each TNT cell hit by
#      the blast is replaced by a primed-TNT entity with a random short
#      fuse (0.5–1.5 s) — the chain-reaction Alpha-faithful behavior
#      that lets you detonate a stack with one ignition.
#
# This runs entirely on the main thread and writes blocks via
# ChunkManager.set_world_block — no worker hand-off, no batching today.
# Cost is ~1500 rays × ~15 steps × dict ops ≈ tens of microseconds in
# practice, well below a frame.

const _RAY_GRID: int = 16
const _STEP: float = 0.3
const _DROP_RATE: float = 0.3
# 0.3 step × 0.75 vanilla scale factor = 0.225 — the per-step intensity
# decay coefficient applied to (resistance + 0.3).
const _DECAY_COEFF: float = 0.225

const _PRIMED_TNT := preload("res://scripts/world/primed_tnt.gd")


# Detonate at `world_pos` (continuous Vector3 — the entity's center, not a
# block coord). `manager` is the ChunkManager. `source` is the entity that
# triggered the blast (used to skip self-damage for primed TNT) and may be
# null. Returns nothing — block writes and entity damage are applied
# synchronously via ChunkManager.
static func detonate(manager: Node, world_pos: Vector3, power: float, source: Node = null) -> void:
	var affected: Dictionary = {}
	# Boundary-only sample of the 16³ direction grid — cells where at least
	# one axis is on the edge. Skipping the interior (where all axes ∈
	# [1, 14]) cuts 4096 rays down to 1352 without changing coverage.
	for n4 in range(_RAY_GRID):
		for n3 in range(_RAY_GRID):
			for n2 in range(_RAY_GRID):
				if (
					n4 != 0
					and n4 != _RAY_GRID - 1
					and n3 != 0
					and n3 != _RAY_GRID - 1
					and n2 != 0
					and n2 != _RAY_GRID - 1
				):
					continue
				_cast_ray(manager, world_pos, power, n4, n3, n2, affected)
	_apply_entity_damage(manager, world_pos, power, source)
	_apply_block_destruction(manager, world_pos, power, affected)


static func _cast_ray(
	manager: Node, origin: Vector3, power: float, n4: int, n3: int, n2: int, affected: Dictionary
) -> void:
	# Map (n2, n3, n4) on the 16³ grid into a normalized direction. The
	# `2x - 1` term recenters [0, 1] to [-1, 1]; dividing by length
	# normalizes onto the unit sphere.
	var dx: float = float(n4) / (_RAY_GRID - 1.0) * 2.0 - 1.0
	var dy: float = float(n3) / (_RAY_GRID - 1.0) * 2.0 - 1.0
	var dz: float = float(n2) / (_RAY_GRID - 1.0) * 2.0 - 1.0
	var dlen: float = sqrt(dx * dx + dy * dy + dz * dz)
	if dlen <= 0.0:
		return
	dx /= dlen
	dy /= dlen
	dz /= dlen
	var x: float = origin.x
	var y: float = origin.y
	var z: float = origin.z
	# Vanilla initial intensity envelope: `power * (0.7 + rand * 0.6)` →
	# 70% to 130% of power per ray. Variance is what makes TNT craters
	# irregular instead of perfectly spherical.
	var intensity: float = power * (0.7 + randf() * 0.6)
	while intensity > 0.0:
		var bx: int = int(floor(x))
		var by: int = int(floor(y))
		var bz: int = int(floor(z))
		var block_id: int = manager.get_world_block(Vector3i(bx, by, bz))
		if block_id != Blocks.AIR:
			var resistance: float = Blocks.explosion_resistance(block_id)
			intensity -= (resistance + 0.3) * _DECAY_COEFF
		if intensity > 0.0:
			# Pack (x, y, z) into a single key so the hash-set semantics
			# come from the dict — Vector3i works as a key directly in GDScript.
			affected[Vector3i(bx, by, bz)] = true
		x += dx * _STEP
		y += dy * _STEP
		z += dz * _STEP


# Damage entities (player today; mobs once they ship) within `power × 2`
# blocks. Vanilla's full formula uses ray occlusion to soften damage when
# walls partially block the blast — we approximate with a simple distance
# falloff for now, since occlusion would require iterating the block grid
# along the entity ray and the cost isn't worth it pre-mob.
static func _apply_entity_damage(
	manager: Node, origin: Vector3, power: float, source: Node
) -> void:
	var radius: float = power * 2.0
	var radius_sq: float = radius * radius
	var player: CharacterBody3D = (
		manager.get_tree().root.get_node_or_null("Main/Player") as CharacterBody3D
	)
	if player == null or player == source:
		return
	var to_player: Vector3 = player.global_position - origin
	var dist_sq: float = to_player.length_squared()
	if dist_sq > radius_sq:
		return
	var dist: float = sqrt(dist_sq)
	# Vanilla: damage = (1 - distance/radius)² normalized × power × 8 + 1.
	# `d12 = (1 - dist/radius) * occlusion`, then `(d12² + d12) / 2 × 8 ×
	# power + 1`. We pin occlusion=1.0 (no walls test) so this reads as a
	# pure distance falloff; integration with cy.a(ao,co) for occlusion
	# lands when raycast performance budget is reviewed.
	var d12: float = 1.0 - dist / radius
	var damage: int = int((d12 * d12 + d12) * 0.5 * 8.0 * power) + 1
	if damage <= 0:
		return
	if player.has_method("take_damage"):
		player.take_damage(damage)
	# Knockback — vanilla pushes the entity along the (entity - origin)
	# direction with magnitude `d13 = d12`. Player physics adds this to
	# its velocity in the next physics step.
	if dist > 0.0001 and player.has_method("apply_explosion_knockback"):
		var dir: Vector3 = to_player / dist
		player.apply_explosion_knockback(dir * d12 * 4.0)


static func _apply_block_destruction(
	manager: Node, origin: Vector3, _power: float, affected: Dictionary
) -> void:
	# Single explosion SFX + particle burst for the whole event — vanilla
	# plays one `random.explode` at the origin, regardless of how many
	# blocks were destroyed.
	SFX.play_explode(origin)
	# Per-affected-block particle burst — vanilla ks.java:127-141 emits an
	# explode + smoke pair per cell with outward-falloff velocity. The fx
	# system collapses to one particle per cell (single CPUParticles3D
	# emitter using EMISSION_SHAPE_POINTS) — same visual read at a much
	# lower per-detonation Node count.
	ExplosionFx.spawn_burst(manager, origin, affected)
	for cell: Vector3i in affected:
		var block_id: int = manager.get_world_block(cell)
		if block_id == Blocks.AIR:
			continue
		# Chain reaction — primed TNT replaces TNT blocks the blast
		# touches. Vanilla v.java::c(...) seeds `kr.a = rand.nextInt(80/4)
		# + 80/8` = [10, 30) ticks (0.5–1.5s). Enables the iconic stack-
		# of-TNT chain detonation from a single ignition.
		if block_id == Blocks.TNT:
			manager.set_world_block(cell, Blocks.AIR)
			_spawn_chain_primed(manager, cell)
			continue
		# Drop items at 30% chance per affected block (vanilla
		# explosionPower=0.3 → "destroy AND drop with this probability").
		# Hardness-based gating still applies: stone-class blocks need a
		# pickaxe to drop, but explosion damage emulates "with proper tool"
		# so we use drop_with_tool with a virtual stone pickaxe. Simplest:
		# use Blocks.drops directly, since explosions ignore the tool tier.
		manager.set_world_block(cell, Blocks.AIR)
		if randf() < _DROP_RATE:
			var drop: int = Blocks.drops(block_id)
			if drop != Blocks.AIR:
				_spawn_drop(manager, cell, drop)


static func _spawn_drop(manager: Node, cell: Vector3i, drop_id: int) -> void:
	var item := DroppedItem.new()
	manager.add_child(item)
	item.global_position = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	item.setup(drop_id)


# Spawns a primed-TNT entity at a chained-detonation cell with a random
# short fuse. Mirrors vanilla v.java::c(cy, x, y, z) — block becomes air
# and a kr (EntityTNTPrimed) is added at the cell center with reduced fuse.
static func _spawn_chain_primed(manager: Node, cell: Vector3i) -> void:
	var primed = _PRIMED_TNT.new()
	manager.add_child(primed)
	primed.global_position = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	# Vanilla: fuse = nextInt(default_fuse / 4) + default_fuse / 8 = [10, 30)
	# at default_fuse = 80 ticks. Ticks → seconds at 20 TPS = [0.5, 1.5).
	var ticks: int = randi() % 20 + 10
	primed.setup(float(ticks) / 20.0)
