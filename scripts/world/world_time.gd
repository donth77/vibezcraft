extends Node

# World time + day/night cycle. Vanilla Alpha runs on a 24000-tick day at
# 20 TPS = 1200 seconds (20 minutes) per cycle. Tick 0 is sunrise, 6000
# noon, 12000 sunset, 18000 midnight. We expose:
#   • `time_ticks` (0..23999) — current cycle position, wraps.
#   • `phase()` — normalized 0..1 around the day.
#   • `sun_elevation()` — -1 (nadir) .. +1 (zenith).
#   • `sky_factor()` — 0.05 (midnight) .. 1.0 (noon). Slice-1's
#     `Chunk.effective_light(...)` consumes this to scale sky_light.
#   • `sky_color()` / `ambient_color()` / `sun_direction()` — driven by
#     phase, used by the WorldEnvironment + DirectionalLight in main.tscn.
#
# Vanilla reference (Bukkit/mc-dev `WorldProvider.a` and `World.j`): vanilla
# uses a smoothstep'd celestial angle and a 0.2 sky-floor. We use a simpler
# elevation = sin(2π·phase) and a 0.05 floor — caves stay dark enough that
# torches will matter once they ship in slice 6, while vanilla's 0.2 floor
# made caves "indoor visible" (designed for the food/hunger era, not Alpha).

# Vanilla constants. Day length is the standard "20 ticks per second × 24000
# ticks per day = 1200s real time". Set DAY_LENGTH_SEC at runtime via
# `set_day_length` (debug speed-up) — never mutate this const.
const TICKS_PER_DAY: int = 24000
const VANILLA_DAY_SECONDS: float = 1200.0  # 20 minutes — shipped value

# Sky-light multiplier floor at midnight. Vanilla Alpha's "moonlight"
# baseline kept sky-lit terrain barely visible at night — vanilla source
# floors around 0.2.
#
# We use 0.10 here as a gamma-compensated equivalent of vanilla's 0.2 floor:
# vanilla rendered in raw sRGB end-to-end on 2010-era displays where 0.2
# crushed to ~10% perceived. Godot 4 does lighting math in linear space
# with sRGB encode on output, which displays the same 0.2 multiplier as
# visibly lighter than vanilla looked. Dropping to 0.10 puts perceived
# midnight brightness back where it belongs (paired with the brightness
# LUT's gamma-compensated 0.02 cave floor in chunk.gdshader). At light
# index 1.5 (sky × 0.10 → 1.5), the LUT outputs ~4.5% — "you need a torch
# even on the surface at night," which matches the actual vanilla feel.
const SKY_FACTOR_MIN: float = 0.10
const SKY_FACTOR_MAX: float = 1.0

# Tick offset so "real noon" lines up with phase = 0.25 (sin(π/2) = +1 sun
# elevation). With this offset, time_ticks=0 reads as sunrise (sun on east
# horizon, elevation 0) and the sin curve peaks at tick 6000.
const _SUNRISE_TICK: int = 0

# Sky-color stops keyed by phase. Lerp happens per-frame in `sky_color()`.
# Noon color ported byte-for-byte from vanilla Alpha 1.2.6's plains-biome
# sky (oz.java:87-90): (0.7529412, 0.84705883, 1.0) * f4 where f4 ≈ 1.0
# near noon. Earlier (0.50, 0.70, 0.95) was our best-guess approximation
# but read as "too blue / too deep" compared to vanilla's airy cyan.
# Dawn/dusk/night values kept — vanilla modulates these via f4 in
# oz.java:80-90 (sin-based elevation curve); our phased constants
# approximate the peak of each phase to avoid per-frame biome sampling.
const _SKY_NIGHT: Color = Color(0.02, 0.02, 0.06, 1.0)
const _SKY_DAWN: Color = Color(0.85, 0.55, 0.40, 1.0)
const _SKY_DAY: Color = Color(0.7529412, 0.84705883, 1.0, 1.0)
const _SKY_DUSK: Color = Color(0.90, 0.45, 0.30, 1.0)

# Ambient stops — slightly darker than sky so the world isn't washed out.
const _AMBIENT_NIGHT: Color = Color(0.10, 0.12, 0.20, 1.0)
const _AMBIENT_DAY: Color = Color(1.0, 1.0, 1.0, 1.0)

# Wall-clock seconds per in-game day. Default = vanilla 1200s. Override via
# `set_day_length(sec)` for debug fast-forward. Clamp to a sane minimum so
# nothing divides by zero or burns the CPU per-frame computing 9000 ticks.
var day_length_seconds: float = VANILLA_DAY_SECONDS

# Current cycle position. Stored as a float so partial-tick advancement
# accumulates without rounding error; consumers that want an int call
# `current_tick()`.
var _time_ticks: float = float(_SUNRISE_TICK)


func _ready() -> void:
	# Start the world at 6000 (vanilla noon) so the player's first frame
	# is well-lit. Without this, a player who dies to a fall before the
	# sun rises would be staring at a black world.
	_time_ticks = 6000.0


func _process(delta: float) -> void:
	var ticks_per_sec: float = float(TICKS_PER_DAY) / day_length_seconds
	_time_ticks = fmod(_time_ticks + delta * ticks_per_sec, float(TICKS_PER_DAY))


# Integer tick (0..TICKS_PER_DAY-1). Most consumers should prefer phase()
# / sun_elevation() / sky_factor() — this is here for debug/display.
func current_tick() -> int:
	return int(_time_ticks) % TICKS_PER_DAY


# Normalized day position 0..1 (0 = sunrise, 0.25 = noon, 0.5 = sunset,
# 0.75 = midnight). Wraps continuously; consumers can use it as a phase.
func phase() -> float:
	return _time_ticks / float(TICKS_PER_DAY)


# Sun elevation: -1 at nadir (midnight), 0 at horizon (sunrise / sunset),
# +1 at zenith (noon). Used by sky_factor + sun_direction.
func sun_elevation() -> float:
	return sin(phase() * TAU)


# Multiplier applied to sky_light when computing effective brightness.
# Smoothly transitions from SKY_FACTOR_MIN (midnight) to SKY_FACTOR_MAX
# (noon). The +0.2 horizon offset keeps a brief dawn glow before the sun
# clears the horizon — matches vanilla's pre-sunrise twilight.
func sky_factor() -> float:
	var t: float = clampf((sun_elevation() + 0.2) / 1.2, 0.0, 1.0)
	return lerpf(SKY_FACTOR_MIN, SKY_FACTOR_MAX, t)


# Sky background color. 4-stop gradient (night → dawn → day → dusk → night)
# keyed by phase so dawn/dusk get visible orange tints regardless of the
# sun-elevation curve.
# gdlint: disable=max-returns
func sky_color() -> Color:
	var p: float = phase()
	# Stops with explicit plateaus around noon and dusk peaks so the sky
	# doesn't immediately start lerping the moment the player spawns:
	#   0.00 - 0.05  night → dawn lerp
	#   0.05 - 0.10  dawn peak (5% plateau ≈ 60s of orange dawn)
	#   0.10 - 0.20  dawn → day lerp
	#   0.20 - 0.30  pure noon plateau (10% = ~120s of stable cyan day)
	#   0.30 - 0.40  day → dusk lerp
	#   0.40 - 0.45  dusk peak plateau (5% ≈ 60s)
	#   0.45 - 0.55  dusk → night lerp
	#   0.55 - 1.00  pure night
	# Earlier impl had no plateaus, so noon was a single-point lerp peak —
	# the sky started transitioning to dusk-pink within seconds of spawn,
	# giving the world a perpetual "almost sunset" look during the day.
	if p < 0.05:
		return _SKY_NIGHT.lerp(_SKY_DAWN, p / 0.05)
	if p < 0.10:
		return _SKY_DAWN
	if p < 0.20:
		return _SKY_DAWN.lerp(_SKY_DAY, (p - 0.10) / 0.10)
	if p < 0.30:
		return _SKY_DAY
	if p < 0.40:
		return _SKY_DAY.lerp(_SKY_DUSK, (p - 0.30) / 0.10)
	if p < 0.45:
		return _SKY_DUSK
	if p < 0.55:
		return _SKY_DUSK.lerp(_SKY_NIGHT, (p - 0.45) / 0.10)
	return _SKY_NIGHT


# Ambient (unshadowed) light tint. Same shape as sky_factor — bright noon,
# dim midnight — but interpolates colors so night tinges blue rather than
# just darkening the day color.
func ambient_color() -> Color:
	var t: float = clampf((sun_elevation() + 0.2) / 1.2, 0.0, 1.0)
	return _AMBIENT_NIGHT.lerp(_AMBIENT_DAY, t)


# Direction the sunlight TRAVELS (not the direction TO the sun). Suitable
# for `DirectionalLight3D.transform.basis = Basis.looking_at(direction)`.
# Sun rises in +X, sets in -X, slight Z tilt so the light direction isn't
# perfectly axis-aligned (avoids the "everything is shadow OR full-lit"
# binary look at noon).
func sun_direction() -> Vector3:
	var angle: float = phase() * TAU
	# Sun arc: east(+X) at sunrise, up(+Y) at noon, west(-X) at sunset,
	# down(-Y) at midnight. Light direction = -position so we flip signs.
	var sun_pos := Vector3(cos(angle), sin(angle), 0.2)
	return -sun_pos.normalized()


# Energy multiplier for the directional light — peaks at noon, zero when
# the sun is below the horizon (no negative-elevation light direction).
func sun_energy(noon_max: float = 1.5) -> float:
	return maxf(0.0, sun_elevation()) * noon_max


# --- Debug knobs ---


# Override the wall-clock day length. Vanilla = 1200s; pick 60s or 30s for
# fast iteration. Clamped so we don't divide by zero or burn the CPU
# advancing >1 day per frame.
func set_day_length(sec: float) -> void:
	day_length_seconds = maxf(sec, 1.0)


# Jump the clock to a specific tick. Wraps into 0..TICKS_PER_DAY-1.
func set_time_ticks(t: int) -> void:
	_time_ticks = float(((t % TICKS_PER_DAY) + TICKS_PER_DAY) % TICKS_PER_DAY)
