extends GutTest

# PlayerSave round-trip (step 7.4 of the save/load plan).
#
# Uses a stub Node3D that exposes the same `inventory` + `health` fields
# the real Player exports — PlayerSave only reads via `.get("inventory")`
# + `.get("health")` so the stub satisfies the contract without dragging
# in player.gd's huge dependency surface (physics, mining, audio).

var _current_world: String = ""
var _player: Node3D = null


func before_each() -> void:
	_current_world = ""
	_player = _make_stub_player()
	add_child_autofree(_player)


func after_each() -> void:
	if _current_world != "":
		SaveLoad.delete_world(_current_world)


func _world(slug: String) -> String:
	_current_world = "test_player_save_" + slug
	SaveLoad.delete_world(_current_world)
	return _current_world


# Build a minimal Player-shaped Node3D: position + rotation + a real
# Inventory + a health int. Has a "Head" child Node3D for pitch round-
# trip. PlayerSave reads everything through `.get(...)` so duck-typed
# fields are all we need.
func _make_stub_player() -> Node3D:
	var p := Node3D.new()
	p.set_script(GDScript.new())
	# Inject fields via direct dict mutation since GDScript's `set()` on
	# a bare Node3D would fail for undeclared props.
	p.set_meta("inventory", Inventory.new())
	p.set_meta("health", 20)
	var head := Node3D.new()
	head.name = "Head"
	p.add_child(head)
	return p


# PlayerSave._build_payload reads via `player.get("inventory")` /
# `player.get("health")` — for our stub, route those to the meta dict so
# the API contract is satisfied without subclassing Node3D.
func _patch_for_get(player: Node3D, inv: Inventory, health: int) -> void:
	player.set_script(_build_stub_player_script())
	player.set("inventory", inv)
	player.set("health", health)


# Dynamically-built GDScript that adds the two fields PlayerSave needs.
# Defined as a function so we can attach it per-test without polluting
# the file with a top-level extra class.
func _build_stub_player_script() -> GDScript:  # gdlint: disable=function-name
	var src := "extends Node3D\nvar inventory: Inventory\nvar health: int = 20\n"
	var s := GDScript.new()
	s.source_code = src
	s.reload()
	return s


# --- Tests ---


func test_save_then_load_returns_true_and_restores_position() -> void:
	var world := _world("pos")
	var inv := Inventory.new()
	_patch_for_get(_player, inv, 20)
	_player.global_position = Vector3(101.5, 70.0, -23.25)
	_player.rotation.y = 0.75
	(_player.get_node("Head") as Node3D).rotation.x = -0.3
	assert_true(PlayerSave.save_player(_player, world))
	# Move the player + zap inventory between save and load to prove
	# load actually mutates state instead of just no-oping.
	_player.global_position = Vector3.ZERO
	_player.rotation.y = 0.0
	(_player.get_node("Head") as Node3D).rotation.x = 0.0
	assert_true(PlayerSave.load_player(_player, world))
	assert_almost_eq(_player.global_position.x, 101.5, 0.001)
	assert_almost_eq(_player.global_position.y, 70.0, 0.001)
	assert_almost_eq(_player.global_position.z, -23.25, 0.001)
	assert_almost_eq(_player.rotation.y, 0.75, 0.001)
	assert_almost_eq((_player.get_node("Head") as Node3D).rotation.x, -0.3, 0.001)


func test_load_when_no_file_returns_false_and_leaves_state_unchanged() -> void:
	var world := _world("missing")
	var inv := Inventory.new()
	_patch_for_get(_player, inv, 20)
	_player.global_position = Vector3(50, 50, 50)
	assert_false(PlayerSave.load_player(_player, world))
	# Position untouched.
	assert_eq(_player.global_position, Vector3(50, 50, 50))


func test_inventory_round_trip_preserves_item_id_count_damage() -> void:
	var world := _world("inv")
	var inv := Inventory.new()
	# Hotbar slot 0: 32 stone.
	inv.slots[0] = ItemStack.new(Blocks.STONE, 32)
	# Hotbar slot 3: 1 wood pickaxe with 17 used durability (damage>0
	# proves the tool wear survives).
	var pick := ItemStack.new(Items.WOODEN_PICKAXE, 1)
	pick.damage = 17
	inv.slots[3] = pick
	# Main slot 9: 64 dirt.
	inv.slots[Inventory.MAIN_START] = ItemStack.new(Blocks.DIRT, 64)
	inv.selected_slot = 5
	_patch_for_get(_player, inv, 15)
	PlayerSave.save_player(_player, world)
	# Wipe inventory between save and load.
	var fresh_inv := Inventory.new()
	_patch_for_get(_player, fresh_inv, 20)
	PlayerSave.load_player(_player, world)
	assert_eq((fresh_inv.slots[0] as ItemStack).item_id, Blocks.STONE)
	assert_eq((fresh_inv.slots[0] as ItemStack).count, 32)
	assert_eq((fresh_inv.slots[3] as ItemStack).item_id, Items.WOODEN_PICKAXE)
	assert_eq((fresh_inv.slots[3] as ItemStack).damage, 17)
	assert_eq((fresh_inv.slots[Inventory.MAIN_START] as ItemStack).item_id, Blocks.DIRT)
	assert_eq((fresh_inv.slots[Inventory.MAIN_START] as ItemStack).count, 64)
	assert_eq(fresh_inv.selected_slot, 5)
	assert_eq(int(_player.get("health")), 15)


func test_bad_magic_returns_false() -> void:
	var world := _world("bad_magic")
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(world))
	var f: FileAccess = FileAccess.open(PlayerSave.player_path(world), FileAccess.WRITE)
	f.store_string("OOPS bad file")
	f.close()
	var inv := Inventory.new()
	_patch_for_get(_player, inv, 20)
	assert_false(PlayerSave.load_player(_player, world))
