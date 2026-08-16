extends Node

signal alpha_vintage_foliage_changed(enabled: bool)

# Cloud rendering quality — mirrors vanilla's `Options.fancyGraphics`
# split (vendor/alpha-1.2.6-src/src/f.java:b vs c). 0=off (no clouds),
# 1=fast (single flat textured plane, low cost), 2=fancy (3D box clouds
# with per-face shading — the iconic look). SkyDome reads this on _ready.
const CLOUD_QUALITY_OFF: int = 0
const CLOUD_QUALITY_FAST: int = 1
const CLOUD_QUALITY_FANCY: int = 2

# Browsers only honor fullscreen + orientation lock from inside a user
# gesture (a Godot input callback or button press qualifies). iOS
# Safari has neither API on iPhone — the promise rejects and the
# RotateOverlay carries the UX instead; web_fullscreen_available()
# returns false there so settings can hide the toggle.
const _JS_FULLSCREEN_ENTER: String = """
(function () {
	if (document.fullscreenElement) { return; }
	var el = document.documentElement;
	if (!el.requestFullscreen) { return; }
	el.requestFullscreen({ navigationUI: "hide" }).then(function () {
		if (screen.orientation && screen.orientation.lock) {
			screen.orientation.lock("landscape").catch(function () {});
		}
	}).catch(function () {});
})();
"""

# Cached result of touch_controls_enabled() — feature tags and the env
# override can't change mid-session, and the helper is polled from input
# paths (player capture branch, interaction gate) where a per-call
# OS.has_feature would be waste. -1 = not yet computed.
static var _touch_controls_cached: int = -1

# Active texture pack. Covers blocks, per-pack item sprites (if any), and
# Steve's skin. Value corresponds to a folder name under
# `assets/textures/packs/` (items live in the `items/` subdir of each
# pack, Steve in `assets/textures/entities/packs/{pack}/`). Available:
#   • "pixel_perfection" — HD community vanilla style (default)
#   • "alpha_vanilla"   — extracted from Mojang Alpha 1.2.6
#   • "programmer_art"   — CC-BY 4.0 from github.com/deathcap/ProgrammerArt
# Non-vanilla packs only ship a subset of textures; BlockAtlas falls back
# to alpha_vanilla per-tile for anything they're missing (chests + beds
# use entity models in modern MC, so PP won't have them).
@export var texture_pack: String = "pixel_perfection"
@export_enum("Off", "Fast", "Fancy") var cloud_quality: int = CLOUD_QUALITY_FANCY
@export var fog_enabled: bool = true
@export var sfx_enabled: bool = true

# Opt-in "Alpha 1.1.2 foliage" tint. Settings UI surfaces this only when
# the active pack is `alpha_vanilla` (the only pack the calibrated values
# target). OFF (default) leaves the current vivid screenshot-derived
# tints in place; ON swaps grass + leaves to values sampled directly from
# the alpha 1.1.2 grass tile in the user's foliage-color reference image.
# BlockAtlas + ChunkNode read this flag at material build / chunk creation
# and listen on `alpha_vintage_foliage_changed` to re-push tints live.
var alpha_vintage_foliage: bool = false

# Mobile-web auto-fullscreen. Browsers only grant requestFullscreen
# inside a user gesture, and the title screen has no TouchControls to
# hook — so the autoload watches every touch press (see _input) from
# the first menu tap onward. Set true when the player explicitly exits
# fullscreen via the HUD button or the options checkbox, so the auto
# path never fights a deliberate choice. Session-scoped on purpose.
var fullscreen_user_opt_out: bool = false

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
# hotkey on. Set via env / .env: MC_CLONE_DEBUG_MINING, _LIGHTING,
# _WORLDGEN, _CLOUDS. Pattern at call sites is `if Game.debug_mining:
# print(...)` so the gating cost is one bool load when the flag is off.
var debug_mining: bool = false
var debug_lighting: bool = false
var debug_worldgen: bool = false
var debug_clouds: bool = false

# Auto-fullscreen internals (see fullscreen_user_opt_out above).
var _fs_auto_watch: bool = false
var _fs_last_attempt_ms: int = -10000


# True when running as a web export on a phone/tablet browser. Drives the
# rotate-to-landscape overlay and the fullscreen+orientation-lock request
# (both meaningless on desktop web, where the window just is what it is).
static func is_mobile_web() -> bool:
	return OS.has_feature("web_android") or OS.has_feature("web_ios")


# True when the on-screen touch HUD should exist. Deliberately DEVICE
# gated, not size or capability gated: only phone/tablet browsers
# (web_android / web_ios feature tags, which Godot derives from the OS,
# never from window dimensions) plus the MC_CLONE_FORCE_TOUCH=1 dev
# override for desktop preview. A desktop browser resized to phone
# proportions — or a touchscreen laptop — keeps the desktop experience.
# Also the gate for hiding keyboard-only UI (the Controls rebind menu).
static func touch_controls_enabled() -> bool:
	if _touch_controls_cached >= 0:
		return _touch_controls_cached == 1
	var enabled: bool = is_mobile_web() or OS.get_environment("MC_CLONE_FORCE_TOUCH") == "1"
	_touch_controls_cached = 1 if enabled else 0
	return enabled


static func web_fullscreen_available() -> bool:
	if not OS.has_feature("web"):
		return false
	var result: Variant = JavaScriptBridge.eval(
		"!!(document.fullscreenEnabled && document.documentElement.requestFullscreen)", true
	)
	return bool(result)


static func web_is_fullscreen() -> bool:
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval("!!document.fullscreenElement", true))


static func web_set_fullscreen(enable: bool) -> void:
	if not OS.has_feature("web"):
		return
	if enable:
		JavaScriptBridge.eval(_JS_FULLSCREEN_ENTER, true)
	else:
		JavaScriptBridge.eval("if (document.exitFullscreen) { document.exitFullscreen(); }", true)


# Re-capture the mouse after a UI screen closes — the ONLY sanctioned
# way for gameplay code to enter MOUSE_MODE_CAPTURED. Touch mode must
# never capture: Android Chrome will happily grant pointer lock inside
# the closing tap's gesture window, and from then on Godot's emulated-
# mouse-from-touch feeds the player's mouse-look path — when the look
# finger lifts and another finger lands, the synthesized mouse jump
# between the two positions yaws the camera by the inverse of the drag
# ("my view snaps back when I start walking"). Screens saw this because
# each close path called Input.mouse_mode = CAPTURED directly.
static func recapture_mouse() -> void:
	if touch_controls_enabled():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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


func set_alpha_vintage_foliage(enabled: bool) -> void:
	if alpha_vintage_foliage == enabled:
		return
	alpha_vintage_foliage = enabled
	alpha_vintage_foliage_changed.emit(enabled)


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
	# Runtime window icon. `application/config/icon` only sets the
	# editor icon + the icon baked into exported builds — in dev mode
	# the OS sees the Godot engine binary, not our project, so the
	# window/dock shows the Godot icon. Setting it explicitly here
	# overrides that for both dev runs and exports.
	var icon_img: Texture2D = load("res://assets/icon/app_icon.png") as Texture2D
	if icon_img != null:
		DisplayServer.set_icon(icon_img.get_image())
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
	# Apply any user keybinding overrides from [controls]. Has to come
	# after register_defaults so cleared bindings (saved as "") actually
	# clear, and before any scene that reads InputMap (HUDs, player).
	InputActions.apply_saved_overrides(cfg)
	# Resolution: apply the cfg-saved value first, then env override wins.
	# Order matters — _apply_resolution_override is a no-op when the env var
	# isn't set, so cfg always lands; when it IS set, the env call overrides.
	var cfg_resolution: String = cfg.get_value("graphics", "resolution", "")
	if cfg_resolution != "":
		SettingsMenu.apply_resolution_value(cfg_resolution)
	_apply_resolution_override()
	# Mobile web: render 3D below the device's native pixel density. Godot
	# sizes the canvas at CSS-size × devicePixelRatio (2.6-3 on phones →
	# 2.5+ Mpx on a 6" screen), and fragment cost is the first thing a
	# phone GPU thermal-throttles on. Target ~1.5× CSS resolution: DPR 3
	# → 0.5 scale, DPR 2 → 0.75, DPR 1 → untouched. 2D UI (HUD, menus,
	# text) is unaffected — only the 3D buffer scales, then bilinear-
	# upscales, which this blocky art style hides well. Desktop (native
	# and web) keeps full resolution.
	if is_mobile_web():
		var dpr: float = DisplayServer.screen_get_scale()
		if dpr > 1.0:
			var scale_3d: float = clampf(1.5 / dpr, 0.5, 1.0)
			get_viewport().scaling_3d_scale = scale_3d
			print("[Game] mobile-web 3D scale=%.2f (devicePixelRatio=%.2f)" % [scale_3d, dpr])
	var settings_pack: String = cfg.get_value("graphics", "texture_pack", texture_pack)
	var resolved_pack: String = _resolve_str("MC_CLONE_TEXTURE_PACK", settings_pack)
	BlockAtlas.active_pack = resolved_pack
	# Has to land BEFORE BlockAtlas.build() so the overlay + entity
	# materials' initial grass/leaves tints reflect the saved choice.
	alpha_vintage_foliage = bool(cfg.get_value("graphics", "alpha_vintage_foliage", false))
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
	if debug_mining or debug_lighting or debug_worldgen:
		print(
			(
				"[Game] debug categories: mining=%s lighting=%s worldgen=%s"
				% [str(debug_mining), str(debug_lighting), str(debug_worldgen)]
			)
		)
	# Warm the worldgen noise on the main thread before any worker can hit it,
	# so workers never race on the lazy-init.
	Worldgen.surface_height(0, 0)
	# Same reason, for the Nether: WorldgenNether builds seven octave
	# generators from a shared JavaRandom on first use, and a chunk worker
	# reaching that lazy step first would race another worker.
	WorldgenNether.warm(Worldgen.WORLD_SEED)
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
	if WorldgenNether.enable_native():
		print("[Game] using native WorldgenNetherNative (GDExtension)")
	else:
		print("[Game] using GDScript WorldgenNether")
	if Lighting.enable_native():
		print("[Game] using native LightingNative (GDExtension)")
	else:
		print("[Game] using GDScript Lighting")
	if VoxelCollider.enable_native():
		print("[Game] using native VoxelColliderNative (GDExtension)")
	else:
		print("[Game] using GDScript VoxelCollider")
	if Pathfinder.enable_native():
		print("[Game] using native PathfinderNative (GDExtension)")
	else:
		print("[Game] using GDScript Pathfinder")
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
	# Mobile web: portrait phones get a full-screen "rotate your device"
	# prompt (iOS Safari has no orientation-lock API, so asking the player
	# is the only option there; Android additionally gets a real lock from
	# the first-touch fullscreen request below). Lives on the Game
	# autoload so it covers the main menu too, not just gameplay.
	if is_mobile_web():
		var overlay_script: GDScript = load("res://scripts/ui/rotate_overlay.gd")
		add_child(overlay_script.new())
	# Arm first-gesture auto-fullscreen from the title screen onward —
	# phones with the API only (Android Chrome; iPhone Safari has none).
	_fs_auto_watch = is_mobile_web() and web_fullscreen_available()
	print("[Game] autoload ready — Minecraft Alpha Clone")


# Drive the per-frame texture tick for animated item icons (compass
# needle, clock dial). Without this the hotbar's TextureRect would
# show a stale image until the next inventory `changed` signal fires.
# Vanilla MC ticks its TextureFX subclasses from the render loop;
# this is our equivalent. ItemIcons.tick_dynamic_icons is a no-op
# until compass / clock has actually been rendered once.
func _process(_delta: float) -> void:
	ItemIcons.tick_dynamic_icons()


# First-gesture auto-fullscreen (mobile web). Any touch press — title
# screen buttons included — carries the gesture grant the Fullscreen API
# needs. Throttled so a denied request doesn't re-fire every tap frame,
# and disarmed entirely once the player opts out via the HUD/settings
# toggle. Zero-cost elsewhere: _fs_auto_watch is false off mobile web.
func _input(event: InputEvent) -> void:
	if not _fs_auto_watch or fullscreen_user_opt_out:
		return
	if not (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed):
		return
	var now: int = Time.get_ticks_msec()
	if now - _fs_last_attempt_ms < 3000:
		return
	_fs_last_attempt_ms = now
	if web_is_fullscreen():
		return
	web_set_fullscreen(true)
