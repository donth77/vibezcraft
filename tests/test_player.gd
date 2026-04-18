extends GutTest


func test_input_actions_register() -> void:
	InputActions.register_defaults()
	for action: String in [
		"move_forward", "move_back", "move_left", "move_right", "jump", "sneak", "pause"
	]:
		assert_true(InputMap.has_action(action), "%s registered" % action)


func test_player_scene_instantiates_as_character_body() -> void:
	var packed: PackedScene = load("res://scenes/player/player.tscn") as PackedScene
	assert_not_null(packed, "player.tscn loads")
	var inst: Node = packed.instantiate()
	assert_not_null(inst, "player instantiates")
	assert_true(inst is CharacterBody3D, "player is CharacterBody3D")
	assert_not_null(inst.get_node_or_null("Camera3D"), "player has Camera3D child")
	assert_not_null(inst.get_node_or_null("CollisionShape3D"), "player has CollisionShape3D child")
	inst.queue_free()


func test_chunk_scene_instantiates() -> void:
	var packed: PackedScene = load("res://scenes/world/chunk.tscn") as PackedScene
	assert_not_null(packed, "chunk.tscn loads")
	var inst: Node = packed.instantiate()
	assert_not_null(inst, "chunk instantiates")
	inst.queue_free()
