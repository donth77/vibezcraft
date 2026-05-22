class_name TestMob
extends "res://scripts/entities/mob_base.gd"

# Placeholder mob entity for validating the M0 base end-to-end before
# real mobs (Pig, Cow, etc.) ship. Renders as a 0.8-m magenta cube so
# it's instantly distinguishable from any vanilla block / mob.
#
# Spawn via DebugItemSpawner (F4) or any caller that does:
#   var m := TestMob.new()
#   chunk_manager.add_child(m)
#   m.global_position = ...
#
# Drops a single stick on death so the drop pipeline gets exercised
# (sticks already render + pickup correctly via DroppedItem).

const _BODY_SIZE: float = 0.8
const _BODY_COLOR := Color(1.0, 0.2, 1.0, 1.0)  # magenta, intentionally loud


func _ready() -> void:
	max_health = 4
	drop_item_id = Items.STICK
	drop_count_min = 1
	drop_count_max = 1
	# Collision shape — a 0.8 m cube. CharacterBody3D needs a child
	# CollisionShape3D for is_on_floor + move_and_slide to work.
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(_BODY_SIZE, _BODY_SIZE, _BODY_SIZE)
	col.shape = box
	add_child(col)
	# Mesh — same 0.8 m cube with an unshaded magenta material so we
	# can spot the entity at any light level and the hurt-flash tint
	# is unambiguous.
	var mesh := MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = Vector3(_BODY_SIZE, _BODY_SIZE, _BODY_SIZE)
	mesh.mesh = cube
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _BODY_COLOR
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	add_child(mesh)
	# Run the rest of MobBase._ready (sets health + chunk_manager).
	super._ready()
