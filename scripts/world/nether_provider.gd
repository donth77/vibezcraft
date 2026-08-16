class_name NetherProvider
extends WorldProvider

# Alpha Nether policy (docs/nether-alpha-1.2.6-implementation-plan.md §5,
# Batch 1).
#
# Values are source-derived from `om.java` (the Nether provider) and the
# plan's §5.1/§5.2; the systems that read them land in Batch 6. Batch 1
# only needs the provider to exist, to own a distinct save namespace, and
# to generate SOMETHING so the dimension-isolation tests can prove that
# the same chunk coordinate stores different bytes in each dimension.

# Placeholder terrain constants. Deliberately crude and deliberately made
# of already-registered blocks: netherrack (97), soul sand (98) and
# glowstone (99) do not exist until Batch 2, and Batch 3 replaces this
# whole function with the real `kj.java` port.
const _PLACEHOLDER_FLOOR_TOP: int = 4
const _PLACEHOLDER_FILL_TOP: int = 30
const _PLACEHOLDER_CEILING_BOTTOM: int = 124


func _init() -> void:
	id = NETHER_ID
	display_name = "Nether"
	# Everything for dimension -1 lives under this sub-directory, so the
	# Overworld's existing region/ and entities.bin stay exactly where
	# they are and keep loading unchanged.
	save_namespace = "DIM-1"

	# §5.1 — no sky, no skylight channel, ambient floor 0.1 rather than
	# the Overworld's 0.05, and a celestial angle pinned at 0.5 for
	# source-compatible queries even though nothing celestial renders.
	has_sky_light = false
	ambient_light_floor = 0.1
	renders_sky = false
	fixed_celestial_angle = 0.5
	fog_color = Color(0.2, 0.03, 0.03, 1.0)

	# §7.2 — entering divides X/Z by 8; returning multiplies by 8.
	coordinate_scale = 8.0

	# §5.2 — water evaporates, lava reaches further via a decay increment
	# of 1 (not a faster tick), beds are denied, and Nether terrain never
	# defines a spawn point.
	allows_water_placement = false
	lava_horizontal_decay = 1
	allows_sleeping = false
	provides_player_spawn = false

	# §8.4 — the Hell biome list is exactly these two, with no passive
	# list at all.
	natural_hostile_species = PackedStringArray(["zombie_pigman", "ghast"])


# PLACEHOLDER terrain — replaced wholesale by WorldgenNether in Batch 3.
#
# A bedrock shell with a stone floor slab. It exists so that a dimension
# switch lands the player on something solid instead of dropping them
# through the void, and so the Batch 1 isolation tests compare real,
# clearly-different bytes rather than two empty chunks. It intentionally
# does NOT consume any Nether RNG or noise; Batch 3 owns all of that.
func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	var chunk := Chunk.new()
	for y: int in range(Chunk.SIZE_Y):
		var id_for_layer: int = Blocks.AIR
		if y <= _PLACEHOLDER_FLOOR_TOP or y >= _PLACEHOLDER_CEILING_BOTTOM:
			id_for_layer = Blocks.BEDROCK
		elif y <= _PLACEHOLDER_FILL_TOP:
			id_for_layer = Blocks.STONE
		if id_for_layer == Blocks.AIR:
			continue
		for z: int in range(Chunk.SIZE_Z):
			for x: int in range(Chunk.SIZE_X):
				chunk.set_block_unchecked(x, y, z, id_for_layer)
	chunk.max_y = Chunk.SIZE_Y - 1
	# Vary one column by chunk coordinate so neighbouring chunks are not
	# byte-identical to each other — otherwise a seam bug in Batch 3 could
	# hide behind uniform placeholder terrain.
	var marker_y: int = _PLACEHOLDER_FILL_TOP + 1 + posmod(chunk_x * 31 + chunk_z * 17, 8)
	chunk.set_block_unchecked(0, marker_y, 0, Blocks.STONE)
	return chunk
