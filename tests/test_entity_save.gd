extends GutTest

# EntitySave round-trip — step 7.3 of the save/load plan. Spawn a
# DroppedItem, save_all → free → load_all → verify it came back with
# the same item_id / position / age remaining.
#
# Tests use a throwaway parent Node per test so child enumeration in
# save_all doesn't see siblings from other tests. Each test also picks
# its own world name + tears it down in after_each.

var _current_world: String = ""
var _parent: Node = null


func before_each() -> void:
	_current_world = ""
	_parent = Node.new()
	add_child_autofree(_parent)


func after_each() -> void:
	if _current_world != "":
		# delete_world recursively removes everything under user://<world>
		# including the entities file we wrote here.
		SaveLoad.delete_world(_current_world)


func _world(slug: String) -> String:
	_current_world = "test_entity_save_" + slug
	SaveLoad.delete_world(_current_world)
	return _current_world


# Spawn a DroppedItem at a known position with a known item_id. Returns
# the live entity so the test can assert on its state pre-save.
func _spawn(pos: Vector3, item_id: int) -> DroppedItem:
	var item := DroppedItem.new()
	_parent.add_child(item)
	item.global_position = pos
	item.setup(item_id)
	return item


# --- Empty world ---


func test_save_empty_world_writes_file_but_zero_entries() -> void:
	var world := _world("empty")
	var written: int = EntitySave.save_all(_parent, world)
	assert_eq(written, 0)
	# File still gets created with header + empty array — load returns 0.
	assert_true(FileAccess.file_exists(EntitySave.entities_path(world)))
	var loaded: int = EntitySave.load_all(_parent, world)
	assert_eq(loaded, 0)


func test_load_when_no_file_returns_zero() -> void:
	var world := _world("no_file")
	# Don't save anything. load_all should return 0 cleanly with no warning
	# spam (just the "no such file" silent return).
	var loaded: int = EntitySave.load_all(_parent, world)
	assert_eq(loaded, 0)


# --- Round-trip ---


func test_single_dropped_item_round_trip_preserves_position_and_id() -> void:
	var world := _world("single")
	var pos := Vector3(42.5, 70.0, -13.25)
	_spawn(pos, Blocks.STONE)
	var written: int = EntitySave.save_all(_parent, world)
	assert_eq(written, 1)
	# Free the live item so load can prove it actually came from disk.
	for child: Node in _parent.get_children():
		child.queue_free()
	await get_tree().process_frame
	assert_eq(_parent.get_child_count(), 0, "all entities freed before load")
	var loaded: int = EntitySave.load_all(_parent, world)
	assert_eq(loaded, 1)
	var restored: DroppedItem = _parent.get_child(0) as DroppedItem
	assert_not_null(restored)
	assert_eq(restored.item_id, Blocks.STONE)
	assert_almost_eq(restored.global_position.x, pos.x, 0.001)
	assert_almost_eq(restored.global_position.y, pos.y, 0.001)
	assert_almost_eq(restored.global_position.z, pos.z, 0.001)


func test_multiple_items_round_trip() -> void:
	var world := _world("multi")
	_spawn(Vector3(0, 64, 0), Blocks.STONE)
	_spawn(Vector3(5, 64, 5), Blocks.DIRT)
	_spawn(Vector3(-3, 80, 11), Items.STICK)
	var written: int = EntitySave.save_all(_parent, world)
	assert_eq(written, 3)
	for child: Node in _parent.get_children():
		child.queue_free()
	await get_tree().process_frame
	var loaded: int = EntitySave.load_all(_parent, world)
	assert_eq(loaded, 3)
	# Collect ids — order isn't guaranteed across save/load, so test by set.
	var ids: Array = []
	for child: Node in _parent.get_children():
		ids.append((child as DroppedItem).item_id)
	ids.sort()
	var expected: Array = [Blocks.STONE, Blocks.DIRT, Items.STICK]
	expected.sort()
	assert_eq(ids, expected)


# Age survives the save/load cycle so the 5-minute despawn timer keeps
# counting forward instead of restarting. Mutate _spawn_time directly to
# simulate 180 seconds having elapsed without having to actually wait.
func test_age_seconds_carries_through_save_load() -> void:
	var world := _world("age")
	var item: DroppedItem = _spawn(Vector3(0, 64, 0), Blocks.STONE)
	# Rewind _spawn_time so the item reports as ~180s old without sleeping.
	var fake_elapsed: float = 180.0
	item._spawn_time = Time.get_ticks_msec() / 1000.0 - fake_elapsed
	# Verify to_save_dict captures the age (sanity check before round-trip).
	var packed: Dictionary = item.to_save_dict()
	assert_almost_eq(float(packed.age_seconds), fake_elapsed, 0.5)
	EntitySave.save_all(_parent, world)
	for child: Node in _parent.get_children():
		child.queue_free()
	await get_tree().process_frame
	EntitySave.load_all(_parent, world)
	var restored: DroppedItem = _parent.get_child(0) as DroppedItem
	var now: float = Time.get_ticks_msec() / 1000.0
	var restored_elapsed: float = now - restored._spawn_time
	# Within 1s — accounts for the wall-clock drift between save_all and
	# load_all + the test's own frame timing.
	assert_almost_eq(restored_elapsed, fake_elapsed, 1.0)


# --- Format guards ---


func test_unknown_type_id_skips_with_warning() -> void:
	var world := _world("unknown_type")
	# Build a file by hand with an unknown type id.
	var entries: Array = [{"type": 99, "payload": {"foo": "bar"}}]
	var body: PackedByteArray = var_to_bytes(entries)
	var out: PackedByteArray = PackedByteArray()
	out.resize(8 + body.size())
	out[0] = 0x4D
	out[1] = 0x43
	out[2] = 0x41
	out[3] = 0x45
	out.encode_u32(4, 1)
	for i in range(body.size()):
		out[8 + i] = body[i]
	# Write directly so we bypass save_all's safety net.
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(world))
	var f: FileAccess = FileAccess.open(EntitySave.entities_path(world), FileAccess.WRITE)
	f.store_buffer(out)
	f.close()
	# load_all should return 0 (no known entities) without crashing.
	var loaded: int = EntitySave.load_all(_parent, world)
	assert_eq(loaded, 0)
