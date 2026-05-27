extends Control

# Custom boot splash: holds a pre-composited image (tiled stone + logo,
# matching the title screen's hu.java treatment) for a minimum duration
# then cross-fades to the main menu. Godot's built-in boot splash can't
# do timing or animation since it runs before the engine boots — this
# scene is the first thing loaded once Godot is ready, so we get
# scriptable control over the splash UX.
#
# To avoid a black flash + pop on transition, we instantiate the main
# menu beneath the splash and fade the splash out, revealing the menu
# directly. change_scene_to_file would give an instant cut with a
# visible black moment between scenes.

const _NEXT_SCENE_PATH: String = "res://scenes/ui/main_menu.tscn"
const _MIN_DISPLAY_SECONDS: float = 1.0
const _FADE_SECONDS: float = 0.25


func _ready() -> void:
	await get_tree().create_timer(_MIN_DISPLAY_SECONDS).timeout

	# Instantiate main_menu as a sibling and move it BEFORE the splash so
	# it renders underneath. As the splash modulate fades to 0, the menu
	# becomes visible without any frame of pure black.
	var menu_scene: PackedScene = load(_NEXT_SCENE_PATH) as PackedScene
	if menu_scene == null:
		push_error("[BootSplash] could not load %s" % _NEXT_SCENE_PATH)
		return
	var menu: Node = menu_scene.instantiate()
	var parent: Node = get_parent()
	parent.add_child(menu)
	parent.move_child(menu, get_index())

	var tween: Tween = create_tween()
	tween.tween_property(self, "modulate:a", 0.0, _FADE_SECONDS)
	await tween.finished

	# Promote main_menu to current_scene BEFORE freeing the splash.
	# Required because we manually sibling-mounted the menu instead of
	# going through change_scene_to_file — get_tree().current_scene
	# still points at this splash node. Any subsequent change_scene_*
	# call (Play → world load, Settings → back) replaces current_scene,
	# so it must point at the menu before we queue_free the splash,
	# otherwise current_scene becomes a freed reference.
	get_tree().current_scene = menu
	queue_free()
