class_name Arrow
extends Node3D

# Beta-era EntityArrow port. Spawned by bow release with the player's
# look direction × bow-charge velocity. Travels with vanilla per-tick
# gravity (0.05 motY/tick) and air drag (0.99/tick); converted to per-
# second so we can run on Godot's variable delta without surprises.
#
# Hit flow mirrors EntityArrow.h() (Bukkit Beta) in spirit, not bit-
# parity:
#   1. Sweep velocity × delta. Raycast block hit → stick, expose
#      pickup. Sphere check vs mobs in the swept segment → damage.
#   2. Damage = ceil(speed × BASE_DAMAGE) + critical_bonus (full-charge
#      arrows roll random(k/2+2) extra, vanilla critical formula).
#   3. Stuck arrows survive 60s before despawning; pickup-on-walk-over
#      transfers ARROW into the player's inventory.
#
# Out of scope for the first projectile pass:
#   * Knockback on hit (vanilla adds horizontal impulse; we just damage)
#   * Fire arrows (no enchantment system yet)
#   * Skeleton-shot arrows (no skeleton mob yet — only player shoots)
#   * Multishot / piercing (Beta+ enchant infra)

const GRAVITY_PER_TICK: float = 0.05  # vanilla EntityArrow f1
const AIR_DRAG_PER_TICK: float = 0.99  # vanilla EntityArrow f4
const TICKS_PER_SEC: float = 20.0
const LIFETIME_SEC: float = 60.0
const PICKUP_RADIUS: float = 1.5
# Vanilla `EntityArrow.b(2.0)` — damage = ceil(velocity * this.damage).
# A full-charge arrow lands ~6 damage (3 blocks/tick speed × 2.0).
const BASE_DAMAGE: float = 2.0
# Quad dimensions for the arrow billboard mesh. 16×16 sprite at the
# extruder's 1/16 scale → 1.0 cell wide isn't right; vanilla draws the
# arrow at roughly 0.5 m long visually. Keep a single quad with the
# arrow sprite — orientation is set per frame to point along velocity.
const VISUAL_SCALE: float = 0.5
# Sprite-extrusion visual constants. The arrow.png is drawn
# diagonally with the head cluster at top-right (image (12-14, 2-3),
# mesh-centered (+6, +5)) and fletching at bottom-left. We rotate the
# extruded mesh by `-atan2(tip_y, tip_x)` around its Z axis so the
# tip-direction lines up with mesh +X, then shift along -X by the
# distance-from-center so the tip lands at the Arrow Node3D's origin.
const _SPRITE_TIP_PX_X: float = 6.0
const _SPRITE_TIP_PX_Y: float = 5.0
const _PIXEL_SCALE: float = 0.03  # 16-px diagonal sprite ≈ 0.5 m arrow

var _velocity: Vector3 = Vector3.ZERO
var _stuck: bool = false
var _spawn_time: float = 0.0
var _is_critical: bool = false
var _shooter: Node = null
var _chunk_manager: Node = null
var _player: Node = null
var _mesh: MeshInstance3D


# Caller (interaction.gd._fire_bow) sets initial velocity from
# (camera_forward × charge × MAX_SPEED) and passes the shooter so we
# can exclude them from the entity-hit sweep.
func setup(shooter: Node, vel: Vector3, is_critical: bool) -> void:
	_shooter = shooter
	_velocity = vel
	_is_critical = is_critical
	_spawn_time = Time.get_ticks_msec() / 1000.0


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_player = get_tree().root.get_node_or_null("Main/Player")
	_build_mesh()
	_update_orientation()


# Vanilla-faithful arrow visual — pixel-extruded from arrow.png via
# SpriteExtruder, same path the held tools use. Each opaque pixel of
# the canonical 16×16 arrow sprite becomes a voxel cube, giving a
# coherent arrowhead → shaft → fletching profile rather than the
# previous disconnected head-cube + shaft-box approximation.
#
# See `_SPRITE_TIP_PX_*` and `_PIXEL_SCALE` at the top of the file for
# the constants this function uses to position the extruded sprite.
func _build_mesh() -> void:
	_mesh = MeshInstance3D.new()
	add_child(_mesh)
	var tex: Texture2D = ItemIcons.icon_for(Items.ARROW)
	if tex == null:
		_build_fallback_mesh()
		return
	var arrow_mi := MeshInstance3D.new()
	arrow_mi.mesh = SpriteExtruder.build(tex)
	if arrow_mi.mesh == null:
		_build_fallback_mesh()
		return
	arrow_mi.scale = Vector3(_PIXEL_SCALE, _PIXEL_SCALE, _PIXEL_SCALE)
	# Rotate around mesh-local Z so the diagonal tip-direction lands on
	# mesh +X. Using atan2 (not a fixed -45°) is closer-to-perfect:
	# the actual tip pixel isn't exactly on the 45° line.
	var tip_angle: float = atan2(_SPRITE_TIP_PX_Y, _SPRITE_TIP_PX_X)
	arrow_mi.rotation = Vector3(0.0, 0.0, -tip_angle)
	# Slide the mesh along -X so the rotated tip lands on the Arrow's
	# origin. Distance from sprite center to tip (= the pythag of the
	# pixel offsets), times the pixel scale.
	var tip_distance_px: float = sqrt(
		_SPRITE_TIP_PX_X * _SPRITE_TIP_PX_X + _SPRITE_TIP_PX_Y * _SPRITE_TIP_PX_Y
	)
	arrow_mi.position = Vector3(-tip_distance_px * _PIXEL_SCALE, 0.0, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mi.material_override = mat
	_mesh.add_child(arrow_mi)


# Used only if the arrow.png didn't load (atlas wasn't ready). Same
# layout as the previous box-shaft + box-head fallback so the arrow
# is at least visible.
func _build_fallback_mesh() -> void:
	var shaft_mi := MeshInstance3D.new()
	var shaft := BoxMesh.new()
	shaft.size = Vector3(0.4, 0.04, 0.04)
	shaft_mi.mesh = shaft
	shaft_mi.position = Vector3(-0.32, 0.0, 0.0)
	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(0.55, 0.40, 0.25)
	shaft_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shaft_mi.material_override = shaft_mat
	_mesh.add_child(shaft_mi)
	var head_mi := MeshInstance3D.new()
	var head := BoxMesh.new()
	head.size = Vector3(0.08, 0.08, 0.08)
	head_mi.mesh = head
	head_mi.position = Vector3(-0.04, 0.0, 0.0)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.65, 0.65, 0.70)
	head_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	head_mi.material_override = head_mat
	_mesh.add_child(head_mi)


# Orient the Arrow so local +X points along velocity (= forward). The
# shaft + head meshes live at NEGATIVE local X so they trail back from
# the tip; with the right rotation sign, "back" = away from velocity
# = into the air cell behind the arrow. Earlier `-90°` here flipped
# local +X to point BACKWARD which buried the geometry in the block —
# `+90°` is the correct direction (verified against the Y-rotation
# matrix: at +π/2 the basis maps (0,0,-1) → (1,0,0), so after the
# look_at puts local -Z on velocity, +π/2 around local Y aligns local
# +X with velocity).
func _update_orientation() -> void:
	var dir: Vector3 = _velocity
	if dir.length_squared() < 0.001:
		return
	look_at(global_position + dir.normalized(), Vector3.UP)
	rotate_object_local(Vector3.UP, deg_to_rad(90.0))


func _physics_process(delta: float) -> void:
	if _stuck:
		_check_pickup()
		_tick_lifetime()
		return
	if _tick_lifetime():
		return
	# Per-tick constants → per-second: drag^(ticks/sec*delta) is
	# Godot's correct continuous form, and gravity becomes (per-tick *
	# ticks/sec²) m/s².
	var gravity_accel: float = GRAVITY_PER_TICK * TICKS_PER_SEC * TICKS_PER_SEC
	var drag_factor: float = pow(AIR_DRAG_PER_TICK, delta * TICKS_PER_SEC)
	_velocity *= drag_factor
	_velocity.y -= gravity_accel * delta
	var step: Vector3 = _velocity * delta
	var new_pos: Vector3 = global_position + step
	# Block sweep — returns the precise point just OUTSIDE the first
	# solid cell along the path, not the cell index. Stick there so the
	# arrowhead lands flush with the block face instead of phasing into
	# the cell. Entity sweep runs against the remaining (or full) step.
	var stick_point: Variant = _sweep_block_hit_point(global_position, new_pos)
	if stick_point != null:
		_stick_at(stick_point)
		return
	if _sweep_entity_hit(global_position, new_pos):
		return
	global_position = new_pos
	_update_orientation()


# Returns true if despawned (caller stops further processing).
func _tick_lifetime() -> bool:
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > LIFETIME_SEC:
		queue_free()
		return true
	return false


# Walks the segment in fine substeps; on the first sample that lands
# in a solid cell, returns the PREVIOUS substep position (= last AIR
# point before entering the block). Caller plants the arrow there, so
# the tip lands just outside the block face instead of clipping into
# it. `null` return means no hit — arrow advances normally.
# Fluids (water / lava) don't count as a stop — arrows fly through.
func _sweep_block_hit_point(from: Vector3, to: Vector3) -> Variant:
	if _chunk_manager == null:
		return null
	var segment_len: float = (to - from).length()
	if segment_len < 0.001:
		return null
	# 16 substeps per block keeps the resolution tight (~0.06 m) so the
	# stick point is visually flush with the face.
	var samples: int = maxi(1, int(ceil(segment_len * 16.0)))
	for i in range(1, samples + 1):
		var t: float = float(i) / float(samples)
		var p: Vector3 = from.lerp(to, t)
		var cell := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
		var id: int = _chunk_manager.get_world_block(cell)
		if id == Blocks.AIR or Blocks.is_water(id) or Blocks.is_lava(id):
			continue
		# Step back to the previous substep — that's the last point
		# inside an open cell before the arrowhead crossed the block
		# face. Caller treats this as the impact pose.
		var prev_t: float = float(i - 1) / float(samples)
		return from.lerp(to, prev_t)
	return null


# Find mobs along the velocity segment using Godot's physics raycast.
# Each mob's actual `CollisionShape3D` (in its real world transform
# including rotation) is what the physics engine sees, so this avoids
# the AABB-vs-rotated-box / head-sticks-out / Y-offset edge cases
# that the earlier manual AABB approach kept tripping over.
#
# The raycast hits the CLOSEST collider on any layer. Blocks live on
# the same layers as mobs, so we just walk the result's parent chain:
# if a MobBase ancestor exists, that's our hit; otherwise (block /
# chest / non-mob) we leave it alone and let `_sweep_block_hit_point`
# handle the stick.
func _sweep_entity_hit(from: Vector3, to: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(from, to)
	# Layer 1 = mob bodies (CharacterBody3D capsules) + solid blocks.
	# Layer 3 = mob hit-only Area3Ds (head/snout/horn boxes, see
	# MobBase._build_head_hit_area). Skip layer 2 — that's selection-
	# only shapes (paintings, plants, boats) which arrows shouldn't
	# treat as mob hits. Same parent-walk filter below covers both
	# body and area cases since head_area's parent IS the mob.
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 0b101
	if _shooter != null and _shooter is CollisionObject3D:
		query.exclude = [(_shooter as CollisionObject3D).get_rid()]
	var result: Dictionary = space.intersect_ray(query)
	if result.is_empty():
		return false
	var node: Node = result.get("collider") as Node
	# Capture the exact intersection point on the hit collider's surface.
	# Passed through to _hit_mob → mob.add_stuck_arrow so the visible
	# stuck arrow lands AT the actual impact pose (head-shot looks like a
	# head-shot) instead of an RNG-random spot on the body.
	var hit_pos: Vector3 = result.get("position", to) as Vector3
	while node != null:
		if node is MobBase:
			_hit_mob(node, hit_pos)
			return true
		node = node.get_parent()
	return false


func _hit_mob(mob: Node, hit_pos: Vector3) -> void:
	if not mob.has_method("take_damage"):
		queue_free()
		return
	# Vanilla EntityArrow damage = `ceil(speed_per_TICK × damage)`. Our
	# velocity is m/s = blocks/SECOND; divide by ticks-per-second to
	# get blocks/tick before scaling. Without this, a full-charge 60
	# m/s arrow dealt 60 × 2 = 120 damage — instakilled every mob.
	# Full-charge in vanilla units: 3 blocks/tick × 2.0 base = 6 dmg.
	var speed_per_tick: float = _velocity.length() / TICKS_PER_SEC
	var raw: float = speed_per_tick * BASE_DAMAGE
	var dmg: int = maxi(1, int(ceil(raw)))
	if _is_critical:
		dmg += randi() % (dmg / 2 + 2)
	# Knockback scales with arrow speed so a fully-drawn shot punches
	# harder than a half-charge tap. Reference: a 60 m/s full-charge
	# arrow → 2× multiplier; a slow 15 m/s low-charge release → 0.5×.
	# Clamped 0.5..2.5 so even minimum-charge arrows feel like they
	# land and crit speeds don't fling mobs off the map.
	var kb_strength: float = clampf(_velocity.length() / 30.0, 0.5, 2.5)
	var landed: bool = mob.call("take_damage", dmg, _velocity.normalized(), kb_strength)
	# Vanilla cosmetic: increment the mob's "arrows stuck in body"
	# counter so a visible arrow stays embedded for ~30 s. Only fires
	# on a landed hit (mob.take_damage returns true) — bouncing off
	# invuln-cooldown mobs shouldn't add a stuck arrow.
	if landed and mob.has_method("add_stuck_arrow"):
		mob.call("add_stuck_arrow", hit_pos, _velocity.normalized())
	SFX.play_arrow_hit()
	queue_free()


func _stick_at(p: Vector3) -> void:
	# `p` is the last-air point just before the arrow's tip would have
	# crossed the block face (see _sweep_block_hit_point). The mesh's
	# origin is at the arrowhead tip (see _build_mesh) so placing the
	# Arrow node here lands the head flush with the block surface and
	# the shaft trails back into the open cell — no clipping.
	global_position = p
	_velocity = Vector3.ZERO
	_stuck = true
	SFX.play_arrow_hit()


func _check_pickup() -> void:
	if _player == null:
		_player = get_tree().root.get_node_or_null("Main/Player")
	if _player == null:
		return
	if global_position.distance_to(_player.global_position) > PICKUP_RADIUS:
		return
	var inv: Inventory = _player.get("inventory") as Inventory
	if inv == null:
		return
	var remaining: int = inv.add_item(Items.ARROW, 1)
	if remaining == 0:
		SFX.play_pickup()
		queue_free()
