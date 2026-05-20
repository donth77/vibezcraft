extends Node

# Cloud rendering quality — mirrors vanilla's `Options.fancyGraphics`
# split (vendor/alpha-1.2.6-src/src/f.java:b vs c). 0=off (no clouds),
# 1=fast (single flat textured plane, low cost), 2=fancy (3D box clouds
# with per-face shading — the iconic look). SkyDome reads this on _ready.
const CLOUD_QUALITY_OFF: int = 0
const CLOUD_QUALITY_FAST: int = 1
const CLOUD_QUALITY_FANCY: int = 2

# Active texture pack. Covers blocks, per-pack item sprites (if any), and
# Steve's skin. Value corresponds to a folder name under
# `assets/textures/blocks/packs/` (items live in the `items/` subdir of each
# pack, Steve in `assets/textures/entities/packs/{pack}/`). Available:
#   • "alpha_vanilla"   — extracted from Mojang Alpha 1.2.6 (default)
#   • "pixel_perfection" — HD community vanilla style
#   • "pixellab"         — AI-generated 32x32
#   • "programmer_art"   — CC-BY 4.0 from github.com/deathcap/ProgrammerArt
@export var texture_pack: String = "alpha_vanilla"
@export_enum("Off", "Fast", "Fancy") var cloud_quality: int = CLOUD_QUALITY_FANCY
@export var fog_enabled: bool = true
@export var sfx_enabled: bool = true

# Active world slot for this session. Set by the Select World screen
# (step 7.6) when the player clicks a slot; persistence modules
# (SaveLoad / EntitySave / PlayerSave / WorldMeta) default to this when
# no explicit world_name is passed. Stays on World1 until the multi-
# world UI lands so single-world testing keeps working today.
var active_world: String = "World1"
# True when the active world had no data on disk before this session
# (player clicked an empty slot). LoadingScreen reads this to pick
# between "Building terrain" (fresh) and "Loading World N" (existing).
# Reset to true when ChunkManager exits so the next world load defaults
# correctly even if Select World didn't run (dev cold-boot into main.tscn).
var world_is_fresh: bool = true

# True only while the in-game LoadingScreen (chunk-gen progress bar)
# is displayed. Defaults to false so the main menu, settings, etc.
# can play SFX normally. LoadingScreen sets this true in its _ready,
# false when chunk-gen completes (loaded >= total).
var is_loading: bool = false

# Global debug-mode flag. When false, debug hotkeys (Creative toggle, hotbar
# fill, etc.) are inert. Toggle via the backtick key.
var debug_enabled: bool = false

# Per-category logging flags. Independent of `debug_enabled` so a dev can
# tail one subsystem (e.g. mining timing) without flipping every debug
# hotkey on. Set via env / .env: MC_CLONE_DEBUG_MINING, _LIGHTING, _MESH,
# _WORLDGEN. Pattern at call sites is `if Game.debug_mining: print(...)`
# so the gating cost is one bool load when the flag is off.
var debug_mining: bool = false
var debug_lighting: bool = false
var debug_mesh: bool = false
var debug_worldgen: bool = false
var debug_clouds: bool = false


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
	# One-shot migration of any pre-7.5 single-world data layout
	# (user://world/) to the multi-world layout (user://World1/). Idempotent.
	SaveLoad.migrate_legacy_world()
	# Install the bitmap MC font as the global fallback so every Control that
	# doesn't override its font picks it up automatically — no per-scene wiring.
	var mc_font := MinecraftFont.get_font()
	if mc_font != null:
		ThemeDB.fallback_font = mc_font
		ThemeDB.fallback_font_size = MinecraftFont.CELL
	# Frame-rate cap from user settings (default 90). Perceived smoothness
	# depends on frame-time variance, not peak fps — an uncapped 120 fps
	# with dips to 100 during chunk streaming reads as stuttery; a steady
	# 90 fps with the same absolute spike (fits in 11.1 ms vs 8.3 ms) reads
	# as smooth. Loaded later in _ready via SettingsMenu.apply_config, but
	# we set an interim value here so the early-boot scene doesn't run
	# uncapped while the config is still being parsed.
	Engine.max_fps = 90
	# Precedence: env > .env > user://settings.cfg > @export default. The
	# settings file is what the Main-Menu → Settings screen writes, so it
	# survives relaunches; env / .env still win so devs can override without
	# editing the saved profile.
	var cfg := SettingsMenu.load_config()
	# Resolution: apply the cfg-saved value first, then env override wins.
	# Order matters — _apply_resolution_override is a no-op when the env var
	# isn't set, so cfg always lands; when it IS set, the env call overrides.
	var cfg_resolution: String = cfg.get_value("graphics", "resolution", "")
	if cfg_resolution != "":
		SettingsMenu.apply_resolution_value(cfg_resolution)
	_apply_resolution_override()
	var settings_pack: String = cfg.get_value("graphics", "texture_pack", texture_pack)
	var resolved_pack: String = _resolve_str("MC_CLONE_TEXTURE_PACK", settings_pack)
	BlockAtlas.active_pack = resolved_pack
	BlockAtlas.build()
	# Cloud quality from settings.cfg (set via Main-Menu → Options).
	# Defaults to the @export value (FANCY) on first launch.
	cloud_quality = int(cfg.get_value("graphics", "cloud_quality", cloud_quality))
	fog_enabled = bool(cfg.get_value("graphics", "fog_enabled", fog_enabled))
	sfx_enabled = bool(cfg.get_value("audio", "sfx_enabled", sfx_enabled))
	# FPS cap + vsync are independent user settings. Default vsync = Off
	# (VSYNC_DISABLED) so fps_cap is the actual ceiling out-of-the-box —
	# Godot's native vsync default of ENABLED would clamp to display
	# refresh and silently override the cap.
	Engine.max_fps = int(cfg.get_value("graphics", "fps_cap", 90))
	DisplayServer.window_set_vsync_mode(
		int(cfg.get_value("graphics", "vsync", DisplayServer.VSYNC_DISABLED))
	)
	debug_enabled = _resolve_bool("MC_CLONE_DEBUG_MODE", false)
	debug_mining = _resolve_bool("MC_CLONE_DEBUG_MINING", false)
	debug_lighting = _resolve_bool("MC_CLONE_DEBUG_LIGHTING", false)
	debug_mesh = _resolve_bool("MC_CLONE_DEBUG_MESH", false)
	debug_worldgen = _resolve_bool("MC_CLONE_DEBUG_WORLDGEN", false)
	debug_clouds = _resolve_bool("MC_CLONE_DEBUG_CLOUDS", false)
	# World seed: read from settings.cfg [world] seed, OR randomize on
	# first run and persist so the same seed loads on every relaunch
	# (matches vanilla, where level.dat pins the seed once a world is
	# created). MUST run before Worldgen.surface_height below — that call
	# warms the noise generator with the current seed; if we apply the
	# seed after, the warmed noise stays on whatever the default was.
	#
	# Headless mode = running under GUT (godot --headless -s gut_cmdln).
	# Tests pin terrain assertions to the default seed 12345; randomizing
	# would re-seed the world per test run and explode every layout-
	# dependent assertion. Production / interactive runs always randomize
	# on first launch.
	var headless: bool = DisplayServer.get_name() == "headless"
	var world_seed: int = int(cfg.get_value("world", "seed", 0))
	if not headless:
		if world_seed == 0:
			# 0 sentinel = unset. Randomize across the full positive int
			# range (avoid 0 itself so we don't loop). Persist so future
			# launches stay on the same world.
			randomize()
			world_seed = randi_range(1, 0x7FFFFFFF)
			cfg.set_value("world", "seed", world_seed)
			cfg.save("user://settings.cfg")
		Worldgen.apply_world_seed(world_seed)
	else:
		# Headless: leave Worldgen.WORLD_SEED at the 12345 default so
		# layout-dependent tests stay deterministic regardless of any
		# user://settings.cfg the dev's interactive runs may have left
		# behind. Tests that want a different seed must apply it
		# explicitly via Worldgen.apply_world_seed in their setup.
		world_seed = Worldgen.WORLD_SEED
	print(
		(
			"[Game] texture_pack=%s cloud_quality=%d world_seed=%d debug_enabled=%s"
			% [resolved_pack, cloud_quality, world_seed, str(debug_enabled)]
		)
	)
	# Only mention category flags when at least one is on — otherwise the
	# extra line is noise on every launch.
	if debug_mining or debug_lighting or debug_mesh or debug_worldgen:
		print(
			(
				"[Game] debug categories: mining=%s lighting=%s mesh=%s worldgen=%s"
				% [str(debug_mining), str(debug_lighting), str(debug_mesh), str(debug_worldgen)]
			)
		)
	# Warm the worldgen noise on the main thread before any worker can hit it,
	# so workers never race on the lazy-init.
	Worldgen.surface_height(0, 0)
	# Opt in to the native mesher + worldgen base-terrain fill (GDExtension).
	# Silently falls back to GDScript if the extension isn't loaded.
	# Parity enforced by tests/test_mesher_native.gd and
	# tests/test_worldgen_native.gd.
	if Mesher.enable_native():
		print("[Game] using native MesherNative (GDExtension)")
	else:
		print("[Game] using GDScript Mesher")
	if Worldgen.enable_native():
		print("[Game] using native WorldgenNative (GDExtension)")
	else:
		print("[Game] using GDScript Worldgen")
	if Lighting.enable_native():
		print("[Game] using native LightingNative (GDExtension)")
	else:
		print("[Game] using GDScript Lighting")
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
