extends Node

# Active block-texture pack. Change this string to swap packs; the value
# corresponds to a folder name under assets/textures/blocks/packs/.
# Available: "pixellab" (our AI-generated 32x32), "programmer_art" (CC-BY 4.0
# from github.com/deathcap/ProgrammerArt, vanilla 16x16).
@export var texture_pack: String = "programmer_art"

# Global debug-mode flag. When false, debug hotkeys (Creative toggle, hotbar
# fill, etc.) are inert. Toggle via the backtick key.
var debug_enabled: bool = false


# Same precedence rule used by every config var below: OS env > .env > default.
func _resolve_str(key: String, default_val: String) -> String:
	var os_val: String = OS.get_environment(key)
	if os_val != "":
		return os_val
	var dotenv := _read_dotenv()
	if dotenv.has(key) and (dotenv[key] as String) != "":
		return dotenv[key]
	return default_val


func _resolve_bool(key: String, default_val: bool) -> bool:
	var raw := _resolve_str(key, "")
	if raw == "":
		return default_val
	var lower := raw.to_lower()
	return lower in ["1", "true", "yes", "on"]


# MC_CLONE_RESOLUTION overrides the default window size at startup.
# Accepts "WIDTHxHEIGHT" (e.g. "2560x1440") or "fullscreen". The default in
# project.godot is 1920x1080; set this env var to deviate without editing it.
func _apply_resolution_override() -> void:
	var raw: String = _resolve_str("MC_CLONE_RESOLUTION", "")
	if raw == "":
		return
	if raw.to_lower() == "fullscreen":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		print("[Game] resolution override: fullscreen")
		return
	var parts: PackedStringArray = raw.to_lower().split("x")
	if parts.size() != 2:
		push_warning("[Game] MC_CLONE_RESOLUTION must be WIDTHxHEIGHT or 'fullscreen'; got: " + raw)
		return
	var w: int = int(parts[0])
	var h: int = int(parts[1])
	if w < 320 or h < 240:
		push_warning("[Game] MC_CLONE_RESOLUTION too small: %dx%d" % [w, h])
		return
	DisplayServer.window_set_size(Vector2i(w, h))
	# Re-center on screen since changing size leaves the top-left anchored.
	var screen_size: Vector2i = DisplayServer.screen_get_size()
	var window_size: Vector2i = DisplayServer.window_get_size()
	DisplayServer.window_set_position((screen_size - window_size) / 2)
	print("[Game] resolution override: %dx%d" % [w, h])


func _read_dotenv() -> Dictionary:
	var path := "res://.env"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var result: Dictionary = {}
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var eq: int = line.find("=")
		if eq <= 0:
			continue
		var key_name: String = line.substr(0, eq).strip_edges()
		var value: String = line.substr(eq + 1).strip_edges()
		# Strip optional surrounding quotes
		if (
			value.length() >= 2
			and (
				(value.begins_with('"') and value.ends_with('"'))
				or (value.begins_with("'") and value.ends_with("'"))
			)
		):
			value = value.substr(1, value.length() - 2)
		result[key_name] = value
	return result


func _ready() -> void:
	InputActions.register_defaults()
	_apply_resolution_override()
	var resolved_pack: String = _resolve_str("MC_CLONE_TEXTURE_PACK", texture_pack)
	BlockAtlas.active_pack = resolved_pack
	BlockAtlas.build()
	debug_enabled = _resolve_bool("MC_CLONE_DEBUG_MODE", false)
	print("[Game] texture_pack=%s debug_enabled=%s" % [resolved_pack, str(debug_enabled)])
	# Warm the worldgen noise on the main thread before any worker can hit it,
	# so workers never race on the lazy-init.
	Worldgen.surface_height(0, 0)
	# Load crafting recipes from disk once at boot.
	Recipes.ensure_loaded()
	# Bake 3D-isometric block icons for the inventory. Setup is sync; the
	# render loop is async (one frame per block) and runs in the background
	# without awaiting — the inventory falls back to flat textures until
	# each baked icon is ready.
	BlockIconRenderer.setup_renderer(self)
	BlockIconRenderer.render_all(self)
	# Build the inventory's live avatar viewport. The inventory's TextureRect
	# binds directly to this viewport's render texture — any change to
	# CharacterPreview.get_model() (armor, head rotation, etc.) auto-updates.
	CharacterPreview.setup_renderer(self)
	print("[Game] autoload ready — Minecraft Alpha Clone")
