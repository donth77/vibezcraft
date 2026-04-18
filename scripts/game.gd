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
	var resolved_pack: String = _resolve_str("MC_CLONE_TEXTURE_PACK", texture_pack)
	BlockAtlas.active_pack = resolved_pack
	BlockAtlas.build()
	debug_enabled = _resolve_bool("MC_CLONE_DEBUG_MODE", false)
	print("[Game] texture_pack=%s debug_enabled=%s" % [resolved_pack, str(debug_enabled)])
	# Warm the worldgen noise on the main thread before any worker can hit it,
	# so workers never race on the lazy-init.
	Worldgen.surface_height(0, 0)
	print("[Game] autoload ready — Minecraft Alpha Clone")
