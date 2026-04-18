class_name Worldgen
extends RefCounted

# Phase 3 MVP worldgen: 2D Perlin heightmap, simple stratified layering.
# No caves, no ores, no biomes, no trees — those land in later phases.

const WORLD_SEED: int = 12345
const SEA_LEVEL: int = 32
const HEIGHT_AMPLITUDE: int = 12
const NOISE_FREQUENCY: float = 0.018

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
				var id: int = _block_at(y, h)
				chunk.set_block(x, y, z, id)
	chunk.dirty = true
	return chunk


static func _block_at(y: int, surface_y: int) -> int:
	if y == 0:
		return Blocks.BEDROCK
	if y == surface_y:
		return Blocks.GRASS
	if y >= surface_y - 3:
		return Blocks.DIRT
	return Blocks.STONE
