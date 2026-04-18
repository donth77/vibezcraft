class_name Worldgen
extends RefCounted

# Phase 3 MVP worldgen: 2D Perlin heightmap, simple stratified layering.
# No caves, no ores, no biomes, no trees — those land in later phases.

const WORLD_SEED: int = 12345
# Alpha-canonical sea level. Surface terrain peaks ~SEA_LEVEL+amplitude,
# leaving ~60 blocks of stone below for caving/ore generation later.
const SEA_LEVEL: int = 63
const HEIGHT_AMPLITUDE: int = 10
const NOISE_FREQUENCY: float = 0.018

# Probability of bedrock at each layer in the bottom band, expressed in eighths.
# Y=0 is always bedrock; Y=1..3 fade out chaotically; Y>3 never bedrock.
const _BEDROCK_THRESHOLDS_EIGHTHS: Array = [8, 5, 3, 1]

static var _noise: FastNoiseLite


static func _get_noise() -> FastNoiseLite:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_noise.frequency = NOISE_FREQUENCY
		_noise.seed = WORLD_SEED
	return _noise


static func surface_height(world_x: int, world_z: int) -> int:
	var n: float = _get_noise().get_noise_2d(float(world_x), float(world_z))
	return SEA_LEVEL + int(round(n * float(HEIGHT_AMPLITUDE)))


static func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	var chunk := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var world_x: int = chunk_x * Chunk.SIZE_X + x
			var world_z: int = chunk_z * Chunk.SIZE_Z + z
			var h: int = surface_height(world_x, world_z)
			for y in range(h + 1):
				var id: int = _block_at(world_x, y, world_z, h)
				chunk.set_block(x, y, z, id)
	chunk.dirty = true
	return chunk


static func _block_at(world_x: int, y: int, world_z: int, surface_y: int) -> int:
	# Alpha-style bedrock band: deterministic per-coord random pattern in y=1..3
	if y == 0:
		return Blocks.BEDROCK
	if y <= 3 and _is_bedrock_at(world_x, y, world_z):
		return Blocks.BEDROCK
	if y == surface_y:
		return Blocks.GRASS
	if y >= surface_y - 3:
		return Blocks.DIRT
	return Blocks.STONE


static func _is_bedrock_at(world_x: int, y: int, world_z: int) -> bool:
	if y < 1 or y > 3:
		return false
	var threshold: int = _BEDROCK_THRESHOLDS_EIGHTHS[y]
	return (_hash3(world_x, y, world_z) & 7) < threshold


# Cheap deterministic hash per (x, y, z, seed). Three large primes + XOR
# scramble — random-enough for visual chaos, no allocations.
static func _hash3(x: int, y: int, z: int) -> int:
	var h: int = WORLD_SEED
	h = (h * 73856093) ^ x
	h = (h * 19349663) ^ y
	h = (h * 83492791) ^ z
	return absi(h)
