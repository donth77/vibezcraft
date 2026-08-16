class_name WorldProvider
extends RefCounted

# Per-dimension policy object (docs/nether-alpha-1.2.6-implementation-plan.md
# §5, Batch 1).
#
# The plan is explicit that the Nether must not arrive as `if nether`
# branches sprinkled through unrelated systems. Instead each dimension
# owns one of these, and the systems that differ ask the provider.
#
# This is a data object with one behavioural hook (`generate_chunk`)
# rather than a class hierarchy: the dimensions differ in their VALUES,
# not in their structure, and a flat object keeps the whole policy
# surface readable in one place. `NetherProvider` overrides only what it
# must.
#
# Worker-thread contract: `generate_chunk` runs on a WorkerThreadPool
# task, so a provider must never touch scene nodes, autoloads or
# resources from it. Everything else here is read-only configuration.
#
# The base class IS the Overworld. Its values are the constants the
# engine already used, moved behind the provider without changing any of
# them — see tests/test_dimension_context.gd, which pins that.

# Vanilla dimension ids. Alpha's `om.java` is the Nether provider and
# reports -1; the Overworld is 0.
const OVERWORLD_ID: int = 0
const NETHER_ID: int = -1

# --- Identity and persistence ---

# Dimension id, as persisted in player.bin.
var id: int = OVERWORLD_ID

# Human-readable name for logs and loading screens.
var display_name: String = "Overworld"

# Sub-directory under `user://WorldN/` that owns this dimension's region
# files and entity store. Empty means "the world root", which is what
# keeps every existing Overworld save byte-compatible — the plan forbids
# moving old files.
var save_namespace: String = ""

# --- Environment (consumed from Batch 6 onward) ---

# Whether the dimension propagates a sky-light channel at all. The Nether
# has no sky, so it generates and propagates none.
var has_sky_light: bool = true

# Ambient floor for the brightness table. Alpha uses 0.05 in the
# Overworld and 0.1 in the Nether (§5.1).
var ambient_light_floor: float = 0.05

# Whether the sky dome, sun, moon, stars, clouds and weather render.
var renders_sky: bool = true

# Fixed celestial angle for source-compatible queries when `renders_sky`
# is false. Alpha's Nether reports 0.5 regardless of world time.
var fixed_celestial_angle: float = -1.0

# Fog colour before engine colour-space conversion. Overworld leaves this
# to the day/night driver, signalled by the negative alpha.
var fog_color: Color = Color(0.0, 0.0, 0.0, -1.0)

# --- Rules ---

# Horizontal coordinate divisor when ENTERING this dimension from the
# Overworld. Alpha scales 8:1 into the Nether.
var coordinate_scale: float = 1.0

# Whether a placed water bucket produces water. False makes it evaporate
# with the fizz effect (§5.2).
var allows_water_placement: bool = true

# Horizontal decay increment for flowing lava. Alpha v1.2.2+ uses 1 in
# the Nether against 2 in the Overworld, which is what gives Nether lava
# its longer reach. NOT a tick-rate change.
var lava_horizontal_decay: int = 2

# Whether a bed can be slept in here.
var allows_sleeping: bool = true

# Whether terrain in this dimension may define a player spawn point.
var provides_player_spawn: bool = true

# Natural hostile spawn table. The Overworld pool lives in
# NaturalMobSpawner today; the Nether's is exactly ghast + zombie pigman.
# Empty means "use the existing Overworld path" until Batch 10 wires the
# single authoritative controller.
var natural_hostile_species: PackedStringArray = PackedStringArray()


# Generate one chunk of this dimension's terrain.
#
# Runs on a worker thread. The Overworld routes to the existing
# `Worldgen`, unchanged — the whole point of Batch 1 is that dimension 0
# still produces byte-identical output.
func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	return Worldgen.generate_chunk(chunk_x, chunk_z)


# Directory that owns this dimension's chunks and entities, given a world
# directory. Kept here rather than in SaveLoad so the namespace and the
# id can never disagree.
func dimension_dir(world_dir: String) -> String:
	if save_namespace == "":
		return world_dir
	return "%s/%s" % [world_dir, save_namespace]
