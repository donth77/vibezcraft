extends GutTest

# SignNode signal-driven label refresh tests. Locks in the contract
# that SignNode.world_pos exactly matches the Vector3i key used by
# SignStorage so the text_changed signal updates labels live.
#
# Regression for the editor-text-doesn't-appear bug, where SignNode
# used to derive world_pos from `global_position` with a `-0.5`
# offset + round(), which silently went off-by-one at coord 0 and
# negative coords (Godot's round() rounds half away from zero).

const _SIGN_NODE_SCRIPT: GDScript = preload("res://scripts/entities/sign_node.gd")


func before_each() -> void:
	for pos in SignStorage._signs.keys():
		SignStorage._signs.erase(pos)


# Build a SignNode wired to a given world_pos, simulating what
# chunk_node._sync_sign_entities does on the live path.
func _spawn_sign_node(world_pos: Vector3i, is_wall: bool, meta: int) -> Node3D:
	var node: Node3D = _SIGN_NODE_SCRIPT.new()
	node.world_pos = world_pos
	node.is_wall_sign = is_wall
	node.meta = meta
	add_child_autofree(node)
	# _ready ran on add_child, so labels exist + signal connected.
	return node


func _label_texts(node: Node3D) -> Array:
	var out: Array = []
	for i in range(SignStorage.LINES_PER_SIGN):
		out.append(node._labels[i].text)
	return out


func test_refresh_picks_up_existing_text_on_spawn() -> void:
	var pos := Vector3i(7, 64, 3)
	SignStorage.set_text(pos, 0, "preexisting")
	var node: Node3D = _spawn_sign_node(pos, false, 0)
	assert_eq(_label_texts(node)[0], "preexisting")


func test_signal_updates_labels_on_text_change() -> void:
	var pos := Vector3i(5, 70, 9)
	var node: Node3D = _spawn_sign_node(pos, false, 0)
	assert_eq(_label_texts(node)[0], "")
	SignStorage.set_text(pos, 0, "live update")
	assert_eq(_label_texts(node)[0], "live update")


# Regression: zero-coord signs used to silently mismatch because
# round(global_position.x - 0.5) for x=0 rounds to -1, not 0.
func test_signal_refresh_works_at_zero_coord() -> void:
	var pos := Vector3i(0, 64, 0)
	var node: Node3D = _spawn_sign_node(pos, false, 0)
	SignStorage.set_text(pos, 0, "zero coord")
	assert_eq(_label_texts(node)[0], "zero coord")


# Regression: negative-coord signs mismatched similarly — round(-1.5)
# is -2, off-by-one in the negative direction.
func test_signal_refresh_works_at_negative_coord() -> void:
	var pos := Vector3i(-3, 64, -7)
	var node: Node3D = _spawn_sign_node(pos, false, 0)
	SignStorage.set_text(pos, 0, "negative coord")
	assert_eq(_label_texts(node)[0], "negative coord")


# A signal for a different position must NOT trigger refresh.
func test_signal_for_other_position_ignored() -> void:
	var mine := Vector3i(1, 64, 1)
	var other := Vector3i(2, 64, 2)
	var node: Node3D = _spawn_sign_node(mine, false, 0)
	SignStorage.set_text(other, 0, "not mine")
	assert_eq(_label_texts(node)[0], "")


func test_update_orientation_relayouts_when_meta_changes() -> void:
	var pos := Vector3i(4, 64, 4)
	var node: Node3D = _spawn_sign_node(pos, false, 0)
	var pos0: Vector3 = node._labels[0].position
	node.update_orientation(false, 4)  # 90° rotation
	var pos1: Vector3 = node._labels[0].position
	assert_ne(pos0, pos1, "label position should shift when meta changes")
