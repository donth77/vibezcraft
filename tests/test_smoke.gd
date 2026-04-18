extends GutTest


func test_truth() -> void:
	assert_true(true, "true is true")


func test_main_scene_loads() -> void:
	var scene: PackedScene = load("res://main.tscn") as PackedScene
	assert_not_null(scene, "main.tscn loads as PackedScene")


func test_game_autoload_script_exists() -> void:
	var script: Script = load("res://scripts/game.gd") as Script
	assert_not_null(script, "Game autoload script loads")
