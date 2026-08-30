extends GutTest

# Creeper mob smoke test — asserts registration, drop config, BB dims,
# HP, and the vanilla fuse state machine numbers (`dq.java` constants).
# Full AI behavior (chase + ignite + detonate) needs a live ChunkManager
# + player + Explosion path, so we only verify the configuration here
# and a single fuse-decay invariant on an offscreen-instantiated mob.

var _parent: Node = null


class DetonationProbe:
	extends Creeper

	var drop_calls: int = 0
	var death_sfx_calls: int = 0

	func _spawn_drops() -> void:
		drop_calls += 1

	func _play_death_sfx() -> void:
		death_sfx_calls += 1


func before_each() -> void:
	_parent = Node.new()
	add_child_autofree(_parent)


func test_registered_under_creeper_name() -> void:
	var script: Script = MobRegistry.script_for("creeper")
	assert_not_null(script, "MobRegistry missing 'creeper' entry")
	assert_true(
		script.resource_path == "res://scripts/entities/creeper.gd",
		"Creeper registered to wrong path: %s" % script.resource_path
	)


# Vanilla `dq.g_()` returns dx.K.aW = GUNPOWDER. 0-2 per kill (same
# range as zombie's feather / spider's string).
func test_drop_config_gunpowder_0_to_2() -> void:
	var creeper: Node = _instantiate_offscreen()
	assert_eq(creeper.get("drop_item_id"), Items.GUNPOWDER)
	assert_eq(creeper.get("drop_count_min"), 0)
	assert_eq(creeper.get("drop_count_max"), 2)


# Prove that a positive Alpha roll reaches the concrete world-item path.
# The zero end of the 0-2 range is intentional; pinning both bounds to one
# isolates the wiring from RNG and catches a missing ChunkManager or setup().
func test_positive_drop_roll_spawns_real_gunpowder_item() -> void:
	var creeper: Node = _instantiate_offscreen()
	creeper.set("_chunk_manager", _parent)
	creeper.set("drop_count_min", 1)
	creeper.set("drop_count_max", 1)
	var child_count_before: int = _parent.get_child_count()

	creeper.call("_spawn_drops")

	assert_eq(_parent.get_child_count(), child_count_before + 1)
	var drop := _parent.get_child(_parent.get_child_count() - 1) as DroppedItem
	assert_not_null(drop, "a positive roll must create a pickup entity")
	assert_eq(drop.item_id, Items.GUNPOWDER)
	assert_eq(drop.get_child_count(), 1, "setup() must build the dropped-item mesh")


# BB dims — modern MC 0.6 × 1.7 (deviation from Alpha's 0.6 × 1.8
# default for tighter hit registration on the 1.625 m visual model).
# Same deviation pattern as zombie.gd which overrides Alpha 1.8 →
# 1.95 for its taller silhouette.
func test_bb_dims_match_vanilla() -> void:
	var creeper: Node = _instantiate_offscreen()
	assert_eq(creeper.call("_get_body_height"), 1.7, "BB height should be 1.7 m")
	assert_eq(creeper.call("_get_body_width"), 0.6, "BB width should be 0.6 m")
	# Eye height = 1.7 × 0.85 = 1.445 — vanilla EntityLiving default.
	assert_almost_eq(creeper.call("_get_eye_height"), 1.445, 0.001)


# HP — vanilla `ef.<init>` sets `this.J = 20` (Living default). Creeper
# inherits unchanged.
func test_max_health_is_20() -> void:
	var creeper: Node = _instantiate_offscreen()
	assert_eq(creeper.get("max_health"), 20)


# Creeper must extend MobBase so take_damage / die() / drops route
# through the shared damage path.
func test_extends_mob_base() -> void:
	var script: Script = MobRegistry.script_for("creeper")
	var base: Script = script.get_base_script()
	assert_not_null(base, "creeper.gd should have a base script")
	assert_true(
		base.resource_path == "res://scripts/entities/mob_base.gd",
		"creeper.gd should extend MobBase, got: %s" % base.resource_path
	)


# Creeper is in the natural hostile spawn pool.
func test_is_in_natural_hostile_pool() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/world/natural_mob_spawner.gd")
	assert_true(
		src.find('"creeper"') != -1,
		'natural_mob_spawner.gd should reference "creeper" in its hostile pool'
	)


# Fuse state machine invariants — vanilla `dq.java`:
#   * Initial state is inert: fuse_ticks=0, fuse_dir=-1.
#   * `_tick_fuse_decay` should LEAVE fuse_ticks at 0 when already 0
#     (no underflow), and DECREMENT from >0 toward 0 each call.
#   * `_tick_fuse_ignite` should INCREMENT fuse_ticks and flip dir=+1.
#     We can't invoke _tick_fuse_ignite directly (it needs a player
#     ref) but we can manually set state to verify the decay path.
func test_fuse_decay_floors_at_zero() -> void:
	var creeper: Node = _instantiate_offscreen()
	assert_eq(creeper.get("_fuse_ticks"), 0, "fresh creeper starts inert")
	assert_eq(creeper.get("_fuse_dir"), -1, "fresh creeper starts with dir=-1")
	# Drive several decay ticks from rest — should stay 0.
	for _i in range(5):
		creeper.call("_tick_fuse_decay")
	assert_eq(creeper.get("_fuse_ticks"), 0, "decay from 0 must not underflow")
	# Charge manually then decay — should count back down by 1/tick.
	creeper.set("_fuse_ticks", 10)
	for _i in range(7):
		creeper.call("_tick_fuse_decay")
	assert_eq(creeper.get("_fuse_ticks"), 3, "decay should subtract 1 per call")
	assert_eq(creeper.get("_fuse_dir"), -1, "decay should leave dir=-1")


# Vanilla constants match — the fuse window is 30 ticks (1.5 s) and
# explosion power is 3.0. These are gameplay constants — surfaces a
# regression if anyone accidentally tweaks them.
func test_vanilla_fuse_constants() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/entities/creeper.gd")
	assert_true(
		src.find("_FUSE_MAX_TICKS: int = 30") != -1, "fuse window should be vanilla 30 ticks"
	)
	assert_true(
		src.find("_EXPLOSION_POWER: float = 3.0") != -1, "explosion power should be vanilla 3.0"
	)
	assert_true(
		src.find("_FUSE_IGNITE_RANGE: float = 3.0") != -1, "ignite range should be vanilla 3.0 m"
	)
	assert_true(
		src.find("_FUSE_ABORT_RANGE: float = 7.0") != -1, "sustain band should reach vanilla 7.0 m"
	)


func test_self_detonation_bypasses_death_loot_and_uses_feet_origin() -> void:
	var creeper := DetonationProbe.new()
	_parent.add_child(creeper)
	creeper.global_position = Vector3(3.5, 64.05, -7.5)
	assert_eq(creeper.call("_explosion_origin"), creeper.global_position, "lw.ax is AABB-base Y")
	creeper.call("_detonate")
	assert_eq(creeper.drop_calls, 0, "dq calls setDead directly instead of onDeath")
	assert_eq(creeper.death_sfx_calls, 0, "the explosion sound is the detonation cue")
	assert_true(creeper.is_queued_for_deletion(), "self-detonation removes the creeper immediately")


# Persistence round-trip — fuse_ticks + fuse_dir must survive a save.
# A creeper mid-ignition that's evicted from active chunks should
# resume the fuse on reload (vanilla `dq.a(iq)` + `b(iq)` persist the
# fuse field).
func test_fuse_persists_through_save_dict() -> void:
	var creeper: Node = _instantiate_offscreen()
	creeper.set("_fuse_ticks", 17)
	creeper.set("_fuse_dir", 1)
	var d: Dictionary = creeper.call("to_save_dict")
	assert_eq(d.get("fuse"), 17, "fuse_ticks should serialize")
	assert_eq(d.get("fuse_dir"), 1, "fuse_dir should serialize")
	# Round-trip on a fresh instance.
	var other: Node = _instantiate_offscreen()
	other.global_position = Vector3.ZERO
	other.call("restore_from_dict", d)
	assert_eq(other.get("_fuse_ticks"), 17, "restored fuse_ticks must match")
	assert_eq(other.get("_fuse_dir"), 1, "restored fuse_dir must match")


# Helper — creates a Creeper attached to the throwaway parent so
# _ready() runs (which is what wires drop_item_id, max_health, etc.).
func _instantiate_offscreen() -> Node:
	var script: Script = MobRegistry.script_for("creeper")
	var creeper: Node = script.new()
	_parent.add_child(creeper)
	return creeper
