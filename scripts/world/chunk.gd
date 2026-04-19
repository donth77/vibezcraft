class_name Chunk
extends RefCounted

# Pure block-data container. Visualization is handled by chunk_node.gd.

const SIZE_X := 16
const SIZE_Y := 128
const SIZE_Z := 16
const TOTAL_BLOCKS := SIZE_X * SIZE_Y * SIZE_Z

var blocks: PackedByteArray
var dirty: bool = true
# Highest Y at which a non-AIR block exists. Lets the mesher skip the empty
# upper layers entirely. Monotonically increases — a player breaking the
# topmost block won't shrink it, but the cost of meshing 1 extra layer is
# negligible.
var max_y: int = 0


func _init() -> void:
	blocks = PackedByteArray()
	blocks.resize(TOTAL_BLOCKS)


# Y-major indexing for cache-friendly vertical scans during meshing/lighting.
static func index(x: int, y: int, z: int) -> int:
	return y * SIZE_X * SIZE_Z + z * SIZE_X + x


func get_block(x: int, y: int, z: int) -> int:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return Blocks.AIR
	return blocks[index(x, y, z)]


func set_block(x: int, y: int, z: int, id: int) -> void:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return
	blocks[index(x, y, z)] = id
	if id != Blocks.AIR and y > max_y:
		max_y = y
	dirty = true


# Trusted-coord variants for worldgen / mesher inner loops. Callers guarantee
# 0 <= x,z < SIZE_X/Z and 0 <= y < SIZE_Y. Skips ~6 bounds conditionals per
# call, which is meaningful in the ~18k calls/chunk surface pass.
func get_block_unchecked(x: int, y: int, z: int) -> int:
	return blocks[index(x, y, z)]


func set_block_unchecked(x: int, y: int, z: int, id: int) -> void:
	blocks[index(x, y, z)] = id
	if id != Blocks.AIR and y > max_y:
		max_y = y
	dirty = true
