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
	instruments_wander = true

	# §8.4 — the Hell biome list is exactly these two, with no passive
	# list at all. `k.java` is two lines: `r = {am.class, pt.class}` and
	# `s = new Class[0]`.
	natural_hostile_species = PackedStringArray(["zombie_pigman", "ghast"])
	has_passive_spawns = false
	# Neither Nether species inherits EntityMonster's light gate — see
	# WorldProvider.hostile_spawns_use_light_gate.
	hostile_spawns_use_light_gate = false
	# `gy.java` gives hostiles a factor of 100.
	hostile_cap_per_256_chunks = 100


# Alpha Nether terrain. `WorldgenNether` is a bit-exact port of
# `kj.java` (density, lava sea, surface replacement, bedrock) plus
# `ju.java` (caves), verified against fixtures produced by running the
# real decompiled classes — see tests/test_nether_worldgen_oracle.gd.
#
# Batch 3 replaced the bedrock-shell placeholder this used to return.
# Population (lava springs, fire, glowstone, mushrooms) lands in Batch 4.
func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	return WorldgenNether.generate_chunk(chunk_x, chunk_z)
