extends CanvasLayer

# Alpha-style startup loading screen. Mirrors vendor/alpha-1.2.6-src/src/hu.java
# (Minecraft's pre-Beta progress UI): tiled dirt background tinted 0x404040,
# centered two-line title + status, and a 100×2-unit progress bar drawn at
# 0x808080 border / 0x80FF80 fill. Vanilla's Minecraft.java:1012 calls it
# with status = "Building terrain" during initial chunk population, which is
# exactly when we need it — the synchronous pre-gen of 49 chunks at boot
# was showing up as a gray-screen freeze.
#
# The scene sits at a very high CanvasLayer so it draws over the 3D world,
# and self-frees when ChunkManager emits initial_chunks_ready with the final
# count.

const _BG_TINT: Color = Color(0x40 / 255.0, 0x40 / 255.0, 0x40 / 255.0, 1.0)
const _BAR_BORDER: Color = Color(0x80 / 255.0, 0x80 / 255.0, 0x80 / 255.0, 1.0)
const _BAR_FILL: Color = Color(0x80 / 255.0, 0xFF / 255.0, 0x80 / 255.0, 1.0)
# Vanilla's bar is 100 px wide × 2 px tall in pre-scaled GUI space; scaled
# 4× for modern displays (1080p+) so it's readable at a glance instead of
# rendering as a 2-px sliver.
const _BAR_WIDTH: float = 400.0
const _BAR_HEIGHT: float = 10.0

var _status_label: Label
var _bar_fill_rect: ColorRect


func _ready() -> void:
	# Set the global loading flag — gates in-game SFX (footsteps, block
	# break/place, ambience) so the chunk-gen player physics doesn't
	# leak audio through the loading screen.
	Game.is_loading = true
	# Reset the day/night clock to noon for each new world. WorldTime is
	# an autoload, so its own _ready only fires once per Godot session;
	# without this, loading a new seed inherits whatever time the prior
	# session left it at (could be midnight) and the player drops into
	# darkness on a fresh world.
	WorldTime.set_time_ticks(6000)
	layer = 100
	var root := Control.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	_build_background(root)
	_build_title(root)
	_build_status(root)
	_build_progress_bar(root)
	# ChunkManager lives next to us under Main. Connect deferred so we
	# still get the final-emit even if the manager's _ready fired before
	# this scene was reachable.
	var mgr: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if mgr != null and mgr.has_signal("initial_chunks_ready"):
		mgr.connect("initial_chunks_ready", _on_chunk_progress)


func _build_background(root: Control) -> void:
	var bg := TextureRect.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.modulate = _BG_TINT
	# Pull the dirt tile from the active block pack; matches the runtime
	# texture-pack setting so the loading screen feels of-a-piece with the
	# world that loads behind it.
	# 4× upscale so STRETCH_TILE gives 64-px tiles instead of 16-px
	# micro-tiles — matches vanilla's `f2 = 32.0f` tile-size math.
	var dirt: Texture2D = VanillaButton.make_scaled_dirt_texture(4)
	if dirt != null:
		bg.texture = dirt
	root.add_child(bg)


func _build_title(root: Control) -> void:
	var title := Label.new()
	title.text = "VibezCraft"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.5
	title.anchor_bottom = 0.5
	title.offset_top = -100
	title.offset_bottom = -20
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	root.add_child(title)


func _build_status(root: Control) -> void:
	_status_label = Label.new()
	_status_label.text = _initial_status_text()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.anchor_left = 0.0
	_status_label.anchor_right = 1.0
	_status_label.anchor_top = 0.5
	_status_label.anchor_bottom = 0.5
	_status_label.offset_top = 8
	_status_label.offset_bottom = 56
	_status_label.add_theme_font_size_override("font_size", 36)
	_status_label.add_theme_color_override("font_color", Color.WHITE)
	_status_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_status_label.add_theme_constant_override("shadow_offset_x", 2)
	_status_label.add_theme_constant_override("shadow_offset_y", 2)
	root.add_child(_status_label)


# Vanilla draws border + green-filled interior in the same coordinate box;
# we model it as a ColorRect "border" with a child ColorRect "fill" that
# grows rightward as progress climbs.
func _build_progress_bar(root: Control) -> void:
	var bar_bg := ColorRect.new()
	bar_bg.color = _BAR_BORDER
	bar_bg.anchor_left = 0.5
	bar_bg.anchor_right = 0.5
	bar_bg.anchor_top = 0.5
	bar_bg.anchor_bottom = 0.5
	bar_bg.offset_left = -_BAR_WIDTH / 2
	bar_bg.offset_right = _BAR_WIDTH / 2
	bar_bg.offset_top = 88
	bar_bg.offset_bottom = 88 + _BAR_HEIGHT
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar_bg)
	_bar_fill_rect = ColorRect.new()
	_bar_fill_rect.color = _BAR_FILL
	_bar_fill_rect.anchor_bottom = 1.0
	_bar_fill_rect.offset_right = 0.0
	_bar_fill_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.add_child(_bar_fill_rect)


func _on_chunk_progress(loaded: int, total: int) -> void:
	var pct: float = 0.0 if total <= 0 else clampf(float(loaded) / float(total), 0.0, 1.0)
	if _status_label != null:
		_status_label.text = "%s  (%d / %d)" % [_initial_status_text(), loaded, total]
	if _bar_fill_rect != null:
		_bar_fill_rect.offset_right = pct * _BAR_WIDTH
	if loaded >= total:
		_restore_world_state()
		# Clear the loading-screen flag so in-game SFX (footsteps, block
		# break/place, ambience) start playing only after world is ready.
		Game.is_loading = false
		queue_free()


# Step 7.9 of the save/load plan. Runs after all initial chunks have
# materialized so the player has terrain to stand on before we move them
# to their saved position. Restores in dependency order:
#
#   1. WorldMeta.time_ticks (overrides the noon default set in _ready
#      so a saved world resumes at whatever time it was paused).
#   2. PlayerSave (position, head, health, inventory).
#   3. EntitySave (dropped items respawn with their original age, so the
#      5-min despawn timer keeps counting forward).
#
# Fresh worlds (no save files yet) silently keep the defaults — each
# load_* call returns 0/false and the player drops in at the spawn
# coord that ChunkManager / Worldgen already picked.
# "Building terrain" for fresh slots (matches Alpha hu.java's status
# verbatim), "Loading World N" for existing slots so the player gets a
# visual confirmation that disk read is happening. Picks based on
# Game.world_is_fresh, which Select-World sets before scene-change.
# Slot number is parsed off the active_world name ("World3" → 3).
func _initial_status_text() -> String:
	if Game.world_is_fresh:
		return "Building terrain"
	var slot: String = Game.active_world.replace("World", "")
	return "Loading World %s" % slot


func _restore_world_state() -> void:
	if _status_label != null:
		_status_label.text = "Restoring world..."
	var meta: Dictionary = WorldMeta.load_meta()
	if not meta.is_empty():
		WorldTime.set_time_ticks(int(meta.get("time_ticks", WorldTime.current_tick())))
	var player: Node3D = get_tree().get_root().find_child("Player", true, false) as Node3D
	if player != null:
		PlayerSave.load_player(player)
	var chunk_manager: Node = get_tree().get_root().find_child("ChunkManager", true, false)
	if chunk_manager != null:
		EntitySave.load_all(chunk_manager)
