class_name BiomeClimate
extends RefCounted

# Vanilla Alpha 1.2.6 biome climate noise — port of `po.java`
# (WorldChunkManager). Three independent Perlin noise stacks per world
# determine temperature and rainfall at every (x, z) world position;
# the (temp, rain) pair is then dispatched through the biome decision
# tree (`gg.java:71-104`) to select one of 11 biomes.
#
# Vanilla source (po.java:18-22):
#   this.e = new ng(new Random(world_seed * 9871L), 4);   // temp, 4-octave
#   this.f = new ng(new Random(world_seed * 39811L), 4);  // rain, 4-octave
#   this.g = new ng(new Random(world_seed * 543321L), 2); // extreme mod, 2-octave
#
# Vanilla uses `ng.java` (a Perlin variant — slightly different from
# the `nf.java` reverse-FBM stack we ported as NoiseOctaves). We
# substitute FastNoiseLite with FBM fractal type since the precise
# noise math doesn't need to match — we just need similar shape
# characteristics (low-freq dominance for slow climate transitions,
# octave variance for some texture).
#
# Per-(x,z) climate computation (po.java:42-66):
#   d2 = g_noise * 1.1 + 0.5            // extreme modifier
#   d5 = (e_noise * 0.15 + 0.7) * 0.99 + d2 * 0.01    // temp
#   d6 = (f_noise * 0.15 + 0.5) * 0.998 + d2 * 0.002  // rain
#   d5 = 1 - (1 - d5)²   // S-curve toward 1
#   clamp d5, d6 → [0, 1]
#
# Biome dispatch (gg.java:71-104) — decision tree on (temp, rain*temp).

# Noise scales mirror vanilla (po.java:42-47):
#   e: 0.025/0.025 horizontal, 0.25 vertical (we ignore vertical for 2D)
#   f: 0.05/0.05  horizontal, 0.333 vertical
#   g: 0.25/0.25  horizontal, 0.588 vertical
const _TEMP_NOISE_FREQUENCY: float = 0.025
const _RAIN_NOISE_FREQUENCY: float = 0.05
const _EXTREME_NOISE_FREQUENCY: float = 0.25

# Vanilla seed multipliers (po.java:19-21).
const _TEMP_SEED_FACTOR: int = 9871
const _RAIN_SEED_FACTOR: int = 39811
const _EXTREME_SEED_FACTOR: int = 543321

# Octave counts per vanilla.
const _TEMP_OCTAVES: int = 4
const _RAIN_OCTAVES: int = 4
const _EXTREME_OCTAVES: int = 2

# Cached noise instances. Built once via _get_*_noise — re-init only
# on apply_world_seed (BiomeClimate.reset called from Worldgen).
static var _temp_noise: FastNoiseLite
static var _rain_noise: FastNoiseLite
static var _extreme_noise: FastNoiseLite


# Reset on seed change. Worldgen.apply_world_seed() calls this so the
# next biome lookup uses the new seed.
static func reset() -> void:
	_temp_noise = null
	_rain_noise = null
	_extreme_noise = null


# Pre-create noise singletons on the main thread. Worker chunk gens
# would otherwise lazy-init FastNoiseLite, which propagates a /root
# notification Godot 4 forbids on non-main threads → chunks fail to
# mesh. Same pattern as WorldgenDensity.warm_main_thread().
static func warm_main_thread() -> void:
	_get_temp_noise()
	_get_rain_noise()
	_get_extreme_noise()


# Sample temperature [0, 1] at (world_x, world_z). 0 = freezing tundra,
# 1 = hot desert.
static func temperature_at(world_x: int, world_z: int) -> float:
	var climate: Vector2 = climate_at(world_x, world_z)
	return climate.x


# Sample rainfall [0, 1] at (world_x, world_z). 0 = arid, 1 = swamp.
static func rainfall_at(world_x: int, world_z: int) -> float:
	var climate: Vector2 = climate_at(world_x, world_z)
	return climate.y


# Sample (temperature, rainfall) at (world_x, world_z). Single
# combined call avoids re-sampling the e/f/g noises three times.
# Mirrors vanilla po.a(double[], int, int, int, int) inner loop.
static func climate_at(world_x: int, world_z: int) -> Vector2:
	var fx: float = float(world_x)
	var fz: float = float(world_z)
	var e: float = _get_temp_noise().get_noise_2d(fx, fz)
	var f: float = _get_rain_noise().get_noise_2d(fx, fz)
	var g: float = _get_extreme_noise().get_noise_2d(fx, fz)
	# Vanilla po.java:51-66 — climate combine + S-curve.
	# Vanilla noise output spans [-1, 1] from the e/f/g samples;
	# FastNoiseLite Perlin returns roughly the same range.
	# Vanilla's `ng.java` Perlin output can span wider than FastNoiseLite's
	# typical [-0.5, 0.5]. Vanilla coefficients (e * 0.15 + 0.7) compress
	# to ~[0.55, 0.85] which after S-curve always lands in Forest range
	# (5000-sample test confirmed 100% Forest). Tuning: give noise more
	# authority (multiplier 0.5 instead of 0.15) so temp/rain span the
	# full biome decision-tree range.
	# `g` extreme modifier with bigger authority — pushes temp/rain toward
	# the tails of [0, 1] so Desert/Plains/Rainforest/Tundra biomes appear.
	# Without this, all noise clusters in the [0.4, 0.9] mid-range and
	# every world is Forest/Shrubland.
	var d2: float = g * 0.5 + 0.5
	var temp: float = (e * 0.7 + 0.5) + (d2 - 0.5) * 0.3
	var rain: float = (f * 0.7 + 0.5) + (d2 - 0.5) * 0.3
	# Vanilla: d5 = 1 - (1 - d5)²  → S-curve toward 1, makes hot regions hotter
	temp = 1.0 - (1.0 - temp) * (1.0 - temp)
	temp = clampf(temp, 0.0, 1.0)
	rain = clampf(rain, 0.0, 1.0)
	return Vector2(temp, rain)


# Look up the biome for a single (world_x, world_z) column. Mirrors
# vanilla `BiomeBase.a(temp, rain)` decision tree (gg.java:71-104).
static func biome_at(world_x: int, world_z: int) -> int:
	var climate: Vector2 = climate_at(world_x, world_z)
	return _biome_for_climate(climate.x, climate.y)


# Vanilla decision tree. Inputs in [0, 1].
# Tree branches on (temp, rain*temp) — vanilla "rain" parameter is
# scaled by temperature here, so the secondary axis is "effective
# rainfall given temperature" rather than raw rainfall.
static func _biome_for_climate(temp: float, rain: float) -> int:
	var rt: float = rain * temp  # vanilla `f3 *= f2`
	if temp < 0.1:
		return Biomes.Biome.TUNDRA
	if rt < 0.2:
		if temp < 0.5:
			return Biomes.Biome.TUNDRA
		if temp < 0.95:
			return Biomes.Biome.SAVANNA
		return Biomes.Biome.DESERT
	if rt > 0.5 and temp < 0.7:
		return Biomes.Biome.SWAMPLAND
	if temp < 0.5:
		return Biomes.Biome.TAIGA
	if temp < 0.97:
		if rt < 0.35:
			return Biomes.Biome.SHRUBLAND
		return Biomes.Biome.FOREST
	# temp >= 0.97
	if rt < 0.45:
		return Biomes.Biome.PLAINS
	if rt < 0.9:
		return Biomes.Biome.SEASONAL_FOREST
	return Biomes.Biome.RAINFOREST


# Per-octave seed offsets keep climate noises independent of each
# other AND of the worldgen heightmap noises (which use base WORLD_SEED
# offsets +0/+1/+2/+101/+102/+103). Multiplicative factors mirror
# vanilla's `world_seed * 9871L` etc.
static func _get_temp_noise() -> FastNoiseLite:
	if _temp_noise == null:
		_temp_noise = FastNoiseLite.new()
		_temp_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_temp_noise.frequency = _TEMP_NOISE_FREQUENCY
		_temp_noise.seed = (Worldgen.WORLD_SEED * _TEMP_SEED_FACTOR) & 0x7FFFFFFF
		_temp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_temp_noise.fractal_octaves = _TEMP_OCTAVES
		_temp_noise.fractal_gain = 0.5
	return _temp_noise


static func _get_rain_noise() -> FastNoiseLite:
	if _rain_noise == null:
		_rain_noise = FastNoiseLite.new()
		_rain_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_rain_noise.frequency = _RAIN_NOISE_FREQUENCY
		_rain_noise.seed = (Worldgen.WORLD_SEED * _RAIN_SEED_FACTOR) & 0x7FFFFFFF
		_rain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_rain_noise.fractal_octaves = _RAIN_OCTAVES
		_rain_noise.fractal_gain = 0.5
	return _rain_noise


static func _get_extreme_noise() -> FastNoiseLite:
	if _extreme_noise == null:
		_extreme_noise = FastNoiseLite.new()
		_extreme_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_extreme_noise.frequency = _EXTREME_NOISE_FREQUENCY
		_extreme_noise.seed = (Worldgen.WORLD_SEED * _EXTREME_SEED_FACTOR) & 0x7FFFFFFF
		_extreme_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_extreme_noise.fractal_octaves = _EXTREME_OCTAVES
		_extreme_noise.fractal_gain = 0.5
	return _extreme_noise
