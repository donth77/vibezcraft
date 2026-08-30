# gdlint: disable=max-public-methods
extends GutTest

# Nether natural spawning — vanilla `bg.java` and `k.java`
# (docs/nether-alpha-1.2.6-implementation-plan.md §8.4, Batch 10).
#
# `k.java` is two lines and they are the whole spawn table:
#
#     this.r = new Class[]{am.class, pt.class};   // hostile
#     this.s = new Class[0];                       // passive
#
# So: ghast and zombie pigman, and NO passive list at all — not an empty
# one, none. A pig can never appear in the Nether by any natural route.
#
# The other three Nether-specific rules all come from the species rather
# than the spawner. Neither `pt.a()` nor `am.a()` calls `super.a()`, so
# neither inherits EntityMonster's light gate; both require difficulty
# above Peaceful; and `am.i()` returns 1 where the default is 4, which is
# why ghasts are always alone.

const _SPAWNER_SCRIPT: GDScript = preload("res://scripts/world/natural_mob_spawner.gd")
const _GHAST_SCRIPT: GDScript = preload("res://scripts/entities/ghast.gd")
const _PIGMAN_SCRIPT: GDScript = preload("res://scripts/entities/zombie_pigman.gd")

const _OVERWORLD := 0
const _NETHER := -1

var _dimension_was: int = 0
var _difficulty_was: int = 0
var _parent: Node = null


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}
	var chunks: Dictionary = {Vector2i(0, 0): true}
	var light: int = 0

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func fill(from: Vector3i, to: Vector3i, id: int) -> void:
		for x: int in range(from.x, to.x + 1):
			for y: int in range(from.y, to.y + 1):
				for z: int in range(from.z, to.z + 1):
					blocks[Vector3i(x, y, z)] = id

	func get_chunk_at_coord(coord: Vector2i) -> Variant:
		return true if chunks.has(coord) else null

	func get_world_effective_light(_pos: Vector3i) -> int:
		return light

	func iter_loaded_chunks() -> Array:
		return chunks.keys()


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	_difficulty_was = Game.difficulty
	Game.difficulty = Game.DIFFICULTY_NORMAL
	_parent = Node.new()
	add_child_autofree(_parent)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)
	Game.difficulty = _difficulty_was


func _spawner() -> Node:
	var node: Node = _SPAWNER_SCRIPT.new()
	_parent.add_child(node)
	return node


func _fake_world() -> FakeWorld:
	var w := FakeWorld.new()
	_parent.add_child(w)
	# A generous open cavern with a floor, which passes both the
	# humanoid and the ghast pocket checks.
	w.fill(Vector3i(-32, 63, -32), Vector3i(32, 63, 32), Blocks.NETHERRACK)
	for cx: int in range(-3, 4):
		for cz: int in range(-3, 4):
			w.chunks[Vector2i(cx, cz)] = true
	return w


func _names_in(pool: Array) -> Array:
	var out: Array = []
	for script: Script in pool:
		out.append(MobRegistry.name_for_script_path(script.resource_path))
	out.sort()
	return out


# --- The spawn table ---


func test_the_nether_pool_is_exactly_ghast_and_pigman() -> void:
	DimensionContext.set_active(_NETHER)
	var spawner: Node = _spawner()
	assert_eq(
		_names_in(spawner.call("_get_hostile_script_pool")),
		["ghast", "zombie_pigman"],
		"k.java names these two and nothing else"
	)


func test_the_overworld_pool_is_untouched() -> void:
	DimensionContext.set_active(_OVERWORLD)
	var spawner: Node = _spawner()
	assert_eq(
		_names_in(spawner.call("_get_hostile_script_pool")),
		["creeper", "skeleton", "spider", "zombie"],
		"the shipped Overworld list, unchanged"
	)


func test_no_overworld_hostile_can_spawn_in_the_nether() -> void:
	DimensionContext.set_active(_NETHER)
	var spawner: Node = _spawner()
	var names: Array = _names_in(spawner.call("_get_hostile_script_pool"))
	for forbidden: String in ["zombie", "skeleton", "spider", "creeper", "slime"]:
		assert_does_not_have(names, forbidden, "%s is not a Nether mob" % forbidden)


func test_the_pool_follows_the_player_through_a_portal() -> void:
	# The cache is keyed by dimension. A single-slot cache would have
	# carried Overworld mobs into the Nether on the first trip.
	var spawner: Node = _spawner()
	DimensionContext.set_active(_OVERWORLD)
	assert_has(_names_in(spawner.call("_get_hostile_script_pool")), "zombie")
	DimensionContext.set_active(_NETHER)
	assert_does_not_have(
		_names_in(spawner.call("_get_hostile_script_pool")), "zombie", "no stale pool"
	)
	DimensionContext.set_active(_OVERWORLD)
	assert_has(_names_in(spawner.call("_get_hostile_script_pool")), "zombie", "and back again")


func test_the_nether_has_no_passive_list_at_all() -> void:
	assert_false(
		DimensionContext.provider(_NETHER).has_passive_spawns,
		"k.java's `s = new Class[0]` — no passive spawns"
	)
	assert_true(
		DimensionContext.provider(_OVERWORLD).has_passive_spawns, "the Overworld still has them"
	)
	# Slimes are their own path (no light gate, no pool) and their own
	# flag — an explicit declaration, not the "species list is empty"
	# convention that would have broken the day the Overworld gained an
	# explicit list (audit finding #15).
	assert_false(DimensionContext.provider(_NETHER).has_slime_spawns, "no Nether slimes")
	assert_true(DimensionContext.provider(_OVERWORLD).has_slime_spawns, "Overworld slimes intact")


func test_the_passive_spawner_refuses_to_tick_in_the_nether() -> void:
	# Gated inside the spawner rather than at its two call sites, so
	# neither the per-frame tick nor the worldgen seed pass can forget.
	DimensionContext.set_active(_NETHER)
	var spawner := PassiveSpawner.new()
	var w: FakeWorld = _fake_world()
	var player := Node3D.new()
	_parent.add_child(player)
	var before: int = MobBase.active_mobs().size()
	for _i: int in range(40):
		spawner.tick(1.0, w, player)
		spawner.populate_chunk_at_gen(w, Vector2i(0, 0))
	assert_eq(MobBase.active_mobs().size(), before, "not one passive mob appeared")


# --- Peaceful ---


func test_peaceful_stops_the_whole_pass() -> void:
	DimensionContext.set_active(_NETHER)
	Game.difficulty = Game.DIFFICULTY_PEACEFUL
	var spawner: Node = _spawner()
	var before: int = MobBase.active_mobs().size()
	for _i: int in range(20):
		spawner.call("_run_spawn_pass")
	assert_eq(MobBase.active_mobs().size(), before, "nothing spawns on Peaceful")


func test_peaceful_stops_the_overworld_pass_too() -> void:
	# `ef.e_()` kills every hostile on Peaceful, not just the Nether's.
	DimensionContext.set_active(_OVERWORLD)
	Game.difficulty = Game.DIFFICULTY_PEACEFUL
	var spawner: Node = _spawner()
	var before: int = MobBase.active_mobs().size()
	for _i: int in range(20):
		spawner.call("_run_spawn_pass")
	assert_eq(MobBase.active_mobs().size(), before, "same rule, both dimensions")


# --- The light gate ---


func test_the_nether_skips_the_light_gate() -> void:
	# `pt.a()` and `am.a()` both reimplement the predicate from `hf.a()`
	# upward and never call `super.a()`, so EntityMonster's light check
	# never runs for either. A pigman is as happy in a lava-lit hall as
	# in a dark one.
	assert_false(
		DimensionContext.provider(_NETHER).hostile_spawns_use_light_gate,
		"no light gate in the Nether"
	)
	assert_true(
		DimensionContext.provider(_OVERWORLD).hostile_spawns_use_light_gate,
		"but every Overworld hostile inherits ef.a()'s"
	)


func test_a_brightly_lit_nether_cell_is_still_valid() -> void:
	DimensionContext.set_active(_NETHER)
	var spawner: Node = _spawner()
	var w: FakeWorld = _fake_world()
	w.light = 15  # as bright as a cell can be
	assert_true(
		spawner.call("_is_valid_hostile_spawn_cell", w, Vector3i(0, 64, 0)),
		"full brightness does not block a Nether spawn"
	)


func test_the_same_cell_is_rejected_in_the_overworld() -> void:
	DimensionContext.set_active(_OVERWORLD)
	var spawner: Node = _spawner()
	var w: FakeWorld = _fake_world()
	w.light = 15
	assert_false(
		spawner.call("_is_valid_hostile_spawn_cell", w, Vector3i(0, 64, 0)),
		"a lit Overworld cell still refuses hostiles"
	)
	w.light = 3
	assert_true(
		spawner.call("_is_valid_hostile_spawn_cell", w, Vector3i(0, 64, 0)),
		"and a dark one still accepts them"
	)


# --- Species predicates ---


func test_a_ghast_needs_an_open_pocket_not_a_floor() -> void:
	DimensionContext.set_active(_NETHER)
	var spawner: Node = _spawner()
	var w: FakeWorld = _fake_world()
	var ghast: Script = MobRegistry.script_for("ghast")
	# Standing on the floor is exactly where a 4x4 body must NOT go: the
	# cell below is solid, so the pocket is not clear.
	assert_true(
		spawner.call("_is_valid_spawn_cell_for", w, ghast, Vector3i(0, 70, 0)),
		"open air well above the floor is fine"
	)
	w.fill(Vector3i(-1, 71, -1), Vector3i(2, 71, 2), Blocks.NETHERRACK)
	assert_false(
		spawner.call("_is_valid_spawn_cell_for", w, ghast, Vector3i(0, 70, 0)),
		"a ceiling one block up does not leave room for it"
	)


func test_a_pigman_uses_the_humanoid_check() -> void:
	DimensionContext.set_active(_NETHER)
	var spawner: Node = _spawner()
	var w: FakeWorld = _fake_world()
	var pigman: Script = MobRegistry.script_for("zombie_pigman")
	assert_true(
		spawner.call("_is_valid_spawn_cell_for", w, pigman, Vector3i(0, 64, 0)),
		"a 2-tall pocket over a floor"
	)
	assert_false(
		spawner.call("_is_valid_spawn_cell_for", w, pigman, Vector3i(0, 70, 0)),
		"but not mid-air — a pigman needs ground"
	)


func test_ghasts_spawn_alone_and_pigmen_in_groups() -> void:
	# `am.i()` returns 1 where the EntityLiving default is 4.
	var spawner: Node = _spawner()
	assert_eq(spawner.call("_group_size_for", MobRegistry.script_for("ghast")), 1, "am.i() = 1")
	assert_eq(
		spawner.call("_group_size_for", MobRegistry.script_for("zombie_pigman")),
		4,
		"the hf.i() default"
	)
	assert_eq(
		spawner.call("_group_size_for", MobRegistry.script_for("zombie")),
		4,
		"and the Overworld hostiles are unchanged"
	)


func test_the_species_probe_leaves_nothing_behind() -> void:
	# The descriptor is read from a throwaway instance. If it were not
	# freed, every spawn pass would leak a mob.
	var spawner: Node = _spawner()
	var before: int = MobBase.active_mobs().size()
	for _i: int in range(20):
		spawner.call("_group_size_for", MobRegistry.script_for("ghast"))
		spawner.call("_group_size_for", MobRegistry.script_for("zombie_pigman"))
	assert_eq(MobBase.active_mobs().size(), before, "probes are freed, not registered")


# --- The cap ---


func test_the_nether_uses_the_source_hostile_factor() -> void:
	# `gy.java` — `a(cz.class, 100)`. The threshold is
	# `100 * eligible_chunks / 256`.
	assert_eq(
		DimensionContext.provider(_NETHER).hostile_cap_per_256_chunks, 100, "the source figure"
	)


func test_the_overworld_keeps_its_shipped_cap() -> void:
	# §8.4: "keep the project's existing Overworld hostile cap at 70
	# unless a separate, measured correction is approved."
	assert_eq(
		DimensionContext.provider(_OVERWORLD).hostile_cap_per_256_chunks,
		70,
		"unchanged, deliberately"
	)


func test_the_cap_scales_with_loaded_chunks() -> void:
	# `count > factor * eligible.size() / 256` — a Tiny render distance
	# gets proportionally fewer mobs, which is what keeps a small world
	# from being packed wall to wall.
	for chunks: int in [25, 81, 289]:
		for factor: int in [70, 100]:
			var expected: int = mini(factor, factor * chunks / 256)
			assert_lte(expected, factor, "never above the flat cap")
			if chunks < 256:
				assert_lt(expected, factor, "and below it at %d chunks" % chunks)


# --- Slimes ---


func test_slimes_do_not_spawn_in_the_nether() -> void:
	# The slime path bypasses the normal pool entirely — no light gate,
	# no night gate — so it needs its own dimension check or slimes would
	# appear in the Nether despite not being on any list.
	DimensionContext.set_active(_NETHER)
	var spawner: Node = _spawner()
	var w: FakeWorld = _fake_world()
	var before: int = MobBase.active_mobs().size()
	for _i: int in range(30):
		spawner.call("_run_spawn_pass")
	for mob in MobBase.active_mobs().values():
		if is_instance_valid(mob):
			assert_false(mob is Slime, "no slimes down here")
	assert_gte(MobBase.active_mobs().size(), before, "sanity")


func test_the_ghast_declares_vanillas_one_in_twenty_spawn_gate() -> void:
	# `am.a()` — `nextInt(20) == 0 && super.a() && difficulty > 0`. The
	# Nether hostile pool is {pigman, ghast}, so an UNGATED ghast takes
	# half of every hostile spawn instead of 2.5% of them: twenty times
	# vanilla density, each firing on the correct 3 s cadence. That reads
	# in play as constant bombardment.
	var ghast: Node = _GHAST_SCRIPT.new()
	assert_true(ghast.has_method("natural_spawn_denominator"), "the gate exists")
	assert_eq(int(ghast.call("natural_spawn_denominator")), 20, "one in twenty, per am.a()")
	ghast.free()
	# Species without a declared gate must be unaffected.
	var pigman: Node = _PIGMAN_SCRIPT.new()
	assert_false(
		pigman.has_method("natural_spawn_denominator"), "pigman has no gate in am.a()'s sense"
	)
	pigman.free()


func test_the_spawn_gate_is_applied_by_the_spawner() -> void:
	var spawner: Node = _SPAWNER_SCRIPT.new()
	add_child_autofree(spawner)
	var ghast_script: Script = _GHAST_SCRIPT
	var pigman_script: Script = _PIGMAN_SCRIPT
	# An ungated species always passes; the gate must never block it.
	for _i: int in range(50):
		assert_true(
			bool(spawner.call("_passes_species_spawn_roll", pigman_script)),
			"ungated species always spawn"
		)
	# The gated species passes roughly one attempt in twenty. Bounds are
	# wide enough to be stable across seeds while still failing an
	# ungated (always-true) implementation.
	var passes: int = 0
	for _i: int in range(2000):
		if bool(spawner.call("_passes_species_spawn_roll", ghast_script)):
			passes += 1
	assert_between(passes, 40, 160, "~100 of 2000 attempts pass (1 in 20)")


func test_arrival_grace_suppresses_the_hostile_pass() -> void:
	# The breathing-room window: a player dropped into an unfamiliar
	# dimension gets a few seconds before the hostile pass resumes.
	var spawner: Node = _SPAWNER_SCRIPT.new()
	add_child_autofree(spawner)
	spawner.call("grant_spawn_grace", 12.0)
	assert_almost_eq(float(spawner.get("_spawn_grace_remaining")), 12.0, 0.001, "window opens")
	# A shorter grant must never shorten a longer live window.
	spawner.call("grant_spawn_grace", 2.0)
	assert_almost_eq(
		float(spawner.get("_spawn_grace_remaining")), 12.0, 0.001, "longest window wins"
	)
	spawner.call("_process", 5.0)
	assert_almost_eq(float(spawner.get("_spawn_grace_remaining")), 7.0, 0.001, "window drains")
	spawner.call("_process", 30.0)
	assert_eq(float(spawner.get("_spawn_grace_remaining")), 0.0, "window closes, never negative")
