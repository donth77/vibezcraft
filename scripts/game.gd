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
	_apply_resolution_override()
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
	# Terrain mode toggle — `MC_CLONE_TERRAIN_MODE` env var picks between
	# the 2D heightmap and the 3D density path. 2026-05-10: defaulted
	# to 2D heightmap because 3D density has known shape issues (visible
	# chunk seams, missing mountains, narrow beaches) that several rounds
	# of empirical tuning haven't resolved. 2D mode produces a working
	# Minecraft-like world today. 3D opt-in via env var while we figure
	# out the structural fix.
	var terrain_mode_raw: String = _resolve_str("MC_CLONE_TERRAIN_MODE", "2d_heightmap")
	var terrain_mode_lower: String = terrain_mode_raw.to_lower()
	if terrain_mode_lower == "2d_heightmap":
		Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP
	elif terrain_mode_lower == "3d_density":
		Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	else:
		push_warning(
			(
				"[Game] MC_CLONE_TERRAIN_MODE expected '3d_density' or '2d_heightmap', got: %s"
				% terrain_mode_raw
			)
		)
		Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP
	print("[Game] terrain_mode=%s" % terrain_mode_lower)
	# Biome system toggle — orthogonal to terrain mode. When enabled,
	# surface block selection becomes biome-driven (Desert columns are
	# SAND, Plains are GRASS, etc.). Recommended combo for Alpha parity:
	# MC_CLONE_TERRAIN_MODE=3d_density MC_CLONE_BIOMES=1.
	var biomes_raw: String = _resolve_str("MC_CLONE_BIOMES", "0")
	Worldgen.biomes_enabled = biomes_raw == "1" or biomes_raw.to_lower() == "true"
	print("[Game] biomes_enabled=%s" % Worldgen.biomes_enabled)
	# Vanilla noise toggle — replaces our FastNoiseLite-based per-octave
	# noise with the proper Java-Random Perlin port (vanilla nf.java +
	# z.java pattern). Wider variance + correlated octaves produce
	# vanilla-shape terrain. Trade: ~2× slower per noise sample (GDScript
	# Perlin vs C++ FastNoiseLite). Only affects 3D density mode.
	var vnoise_raw: String = _resolve_str("MC_CLONE_VANILLA_NOISE", "0")
	WorldgenDensity.vanilla_noise_enabled = (vnoise_raw == "1" or vnoise_raw.to_lower() == "true")
	print("[Game] vanilla_noise_enabled=%s" % WorldgenDensity.vanilla_noise_enabled)
	# Warm the worldgen noise on the main thread before any worker can hit it,
	# so workers never race on the lazy-init.
	Worldgen.surface_height(0, 0)
	# Warm the 3D-density noise stack on the main thread. Without this,
	# the first chunk gen on a worker thread would call FastNoiseLite.new()
	# inside NoiseOctaves.create, which triggers a /root propagate_notification
	# Godot forbids from non-main threads → chunks fail to mesh.
	if Worldgen.terrain_mode == Worldgen.TerrainMode.MODE_3D_DENSITY:
		WorldgenDensity.warm_main_thread()
	# Same warming pattern for biome climate noise — 3 FastNoiseLite
	# constructors that workers can't safely create.
	if Worldgen.biomes_enabled:
		BiomeClimate.warm_main_thread()
	# Worldgen audit dump — `MC_CLONE_WORLDGEN_AUDIT=1` prints a per-chunk
	# block / surface / decoration breakdown vs vanilla expected values
	# right after init. Useful for catching tuning regressions (e.g.,
	# sand-mid-forest, missing mountains) without screenshots. Generates
	# a fresh 5×5 chunk sample (slow — ~half a second) so do NOT enable
	# in normal play; it's a dev tool.
	var audit_flag: String = _resolve_str("MC_CLONE_WORLDGEN_AUDIT", "0")
	if audit_flag == "1" or audit_flag.to_lower() == "true":
		# Radius 5 = 11×11 chunks ≈ 176 blocks; bigger than the
		# elevation-modulator wavelength (~250 blocks) so the sample
		# spans at least one continental high/low transition.
		WorldgenAudit.print_report(0, 0, 5)
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
