# gdlint: disable=max-public-methods
extends GutTest

# Content-registry invariants (docs/nether-alpha-1.2.6-implementation-plan.md
# §3.1, Batch 0).
#
# Until the Nether work started, "is this id a block or an item?" was
# answered by comparing against 100 — blocks stopped at 96, items started
# at 100, and the arithmetic happened to hold. The Alpha Nether reserves
# the portal at block id 206, which sits ABOVE the item floor, so every
# one of those comparisons would have classified a world block as an item
# and routed it into inventories, icons, held meshes and drops.
#
# These tests pin the replacement: two explicit registries that never
# overlap, always fit a uint8, and can be swept for drift. The drift
# sweep is the important one — it reads the scripts' own constant maps,
# so a new block const that someone forgets to add to `REGISTERED_IDS`
# fails here instead of silently becoming unclassifiable content.

# Public int constants in blocks.gd that are NOT block ids. Everything
# else in that script's constant map must be a registered block.
const _BLOCK_NON_ID_PREFIXES: Array[String] = ["MESH_SHAPE_"]
# Same for items.gd.
const _ITEM_NON_ID_PREFIXES: Array[String] = ["ARMOR_SLOT_", "TOOL_TYPE_"]

# Constants that are lists of ids rather than ids themselves.
const _ID_LIST_NAMES: Array[String] = ["REGISTERED_IDS", "WORLD_ONLY_IDS", "BURNED_IDS"]

# Ids the Nether plan reserved. Batch 2 claimed all five; the assertions
# below check they landed in the RIGHT registry, which is the property
# that actually matters — 206 in particular is a block living above the
# item floor, and the whole registry refactor exists to make that safe.
const _RESERVED_BLOCK_IDS: Array[int] = [97, 98, 99, 206]
const _RESERVED_ITEM_IDS: Array[int] = [205]


func _int_constants(path: String, non_id_prefixes: Array[String]) -> Dictionary:
	var script: GDScript = load(path) as GDScript
	assert_not_null(script, "%s loads" % path)
	if script == null:
		return {}
	var out: Dictionary = {}
	for name: String in script.get_script_constant_map().keys():
		var value: Variant = script.get_script_constant_map()[name]
		if typeof(value) != TYPE_INT:
			continue
		if name.begins_with("_"):
			continue  # private tuning constants, not content ids
		if _ID_LIST_NAMES.has(name):
			continue
		var skip: bool = false
		for prefix: String in non_id_prefixes:
			if name.begins_with(prefix):
				skip = true
				break
		if skip:
			continue
		out[name] = value
	return out


# --- Uniqueness and byte range ---


func test_block_ids_are_unique() -> void:
	var seen: Dictionary = {}
	for id: int in Blocks.REGISTERED_IDS:
		assert_false(seen.has(id), "block id %d appears once in REGISTERED_IDS" % id)
		seen[id] = true


func test_item_ids_are_unique() -> void:
	var seen: Dictionary = {}
	for id: int in Items.REGISTERED_IDS:
		assert_false(seen.has(id), "item id %d appears once in REGISTERED_IDS" % id)
		seen[id] = true


func test_every_registered_id_fits_a_uint8() -> void:
	# Chunk storage is a PackedByteArray and ItemStack persists a byte,
	# so an id outside 0..255 would truncate on the way to disk.
	for id: int in Blocks.REGISTERED_IDS:
		assert_between(id, 0, 255, "block id %d fits uint8" % id)
	for id: int in Items.REGISTERED_IDS:
		assert_between(id, 0, 255, "item id %d fits uint8" % id)


func test_registries_are_disjoint() -> void:
	for id: int in Blocks.REGISTERED_IDS:
		assert_false(Items.REGISTERED_IDS.has(id), "block id %d is not also an item id" % id)
	for id: int in Items.REGISTERED_IDS:
		assert_false(Blocks.REGISTERED_IDS.has(id), "item id %d is not also a block id" % id)


func test_every_id_belongs_to_exactly_one_registry() -> void:
	# The invariant the whole feature rests on: for any byte, at most one
	# of the two registries claims it, and a claimed byte is never
	# ambiguous.
	for id: int in range(256):
		var as_block: bool = Blocks.is_registered(id)
		var as_item: bool = Items.is_registered(id)
		assert_false(as_block and as_item, "id %d is claimed by only one registry" % id)


# --- AIR and the burned id ---


func test_air_is_registered_but_has_no_item_form() -> void:
	assert_true(Blocks.is_registered(Blocks.AIR), "AIR is a real stored id")
	assert_false(Blocks.has_item_form(Blocks.AIR), "AIR never reaches an inventory")
	assert_false(Items.is_registered(Blocks.AIR), "AIR is not an item")


func test_burned_id_50_is_claimed_by_nobody() -> void:
	# A save written before tall grass was removed can still carry the
	# byte 50. If any future block claimed that id, those cells would
	# silently mutate into it — which is precisely the failure mode the
	# plan forbids for the Nether reservations.
	for id: int in Blocks.BURNED_IDS:
		assert_false(Blocks.is_registered(id), "burned id %d is not a block" % id)
		assert_false(Items.is_registered(id), "burned id %d is not an item" % id)
		assert_false(Blocks.has_item_form(id), "burned id %d has no item form" % id)


func test_burned_id_50_is_not_in_either_id_list() -> void:
	assert_false(Blocks.REGISTERED_IDS.has(50), "id 50 stays out of the block registry")
	assert_false(Items.REGISTERED_IDS.has(50), "id 50 stays out of the item registry")


# --- Item-form policy ---


func test_live_world_only_blocks_are_registered_without_an_item_form() -> void:
	# Batch 2 populated this with the Nether portal. Was vacuous before
	# that; the builder-seam test below still proves the mechanism
	# independently of what happens to be listed.
	assert_true(Blocks.WORLD_ONLY_IDS.has(Blocks.PORTAL), "the portal is the world-only block")
	for id: int in Blocks.WORLD_ONLY_IDS:
		assert_true(Blocks.is_registered(id), "world-only id %d is still a block" % id)
		assert_false(Blocks.has_item_form(id), "world-only id %d has no item form" % id)
		assert_false(Blocks.is_inventory_placeable(id), "world-only id %d is not placeable" % id)


func test_id_206_registers_as_a_world_only_block_without_becoming_an_item() -> void:
	# Batch 0 acceptance criterion: the portal's reserved id sits ABOVE
	# the old `id >= 100 means item` line, so this is the case the whole
	# registry refactor exists to make safe. Drive the real builder with
	# the Batch 2 id set and check the classification it produces.
	var portal: int = 206
	var ids: Array[int] = [Blocks.AIR, Blocks.STONE, 97, 98, 99, portal]
	var world_only: Array[int] = [portal]
	var lut: PackedByteArray = Blocks.build_registry_flags(ids, world_only)
	assert_eq(lut.size(), 256, "the flag table covers the whole byte range")
	assert_eq(lut[portal] & 1, 1, "id 206 registers as a block")
	assert_eq(lut[portal] & 2, 0, "id 206 has no item form")
	# The three inventory blocks reserved alongside it keep their form.
	for id: int in [97, 98, 99]:
		assert_eq(lut[id] & 1, 1, "reserved block id %d registers" % id)
		assert_eq(lut[id] & 2, 2, "reserved block id %d keeps its item form" % id)
	# And nothing about id 206 makes it an item in the live item registry.
	assert_false(Items.is_registered(portal), "id 206 is never an item")
	assert_eq(Items.display_name(portal), "", "id 206 has no item display name")


func test_id_206_survives_the_uint8_storage_paths_without_truncation() -> void:
	# "Not truncated" is the other half of the criterion. A block id above
	# 127 must survive the signed/unsigned boundary in chunk storage.
	var portal: int = 206
	var chunk := Chunk.new()
	chunk.set_block(3, 40, 9, portal)
	assert_eq(chunk.get_block(3, 40, 9), portal, "chunk storage round-trips id 206")
	var bytes: PackedByteArray = chunk.blocks
	var idx: int = 40 * Chunk.SIZE_X * Chunk.SIZE_Z + 9 * Chunk.SIZE_X + 3
	assert_eq(bytes[idx], portal, "the raw PackedByteArray cell holds 206")
	# BlockAtlas keeps a 256-entry lookup table, so an id of 206 indexes
	# it without going out of bounds.
	var uv_table: PackedFloat32Array = BlockAtlas.uv_table_flat()
	assert_true(
		uv_table.size() >= (portal + 1) * 4,
		"the atlas UV table spans the full byte range (got %d floats)" % uv_table.size()
	)


func test_reserved_and_burned_ids_survive_a_raw_chunk_byte_round_trip() -> void:
	# Plan Batch 0 required test: ids 0, 50, 99, 100, 205, 206 and 255 as
	# raw byte values. None of them are defined content today — the point
	# is that the storage format carries any byte faithfully, so a future
	# reservation can never be corrupted by the format itself.
	var probes: Array[int] = [0, 50, 99, 100, 205, 206, 255]
	var chunk := Chunk.new()
	for i: int in range(probes.size()):
		chunk.set_block(i, 5, 0, probes[i])
	for i: int in range(probes.size()):
		assert_eq(chunk.get_block(i, 5, 0), probes[i], "raw byte %d round-trips" % probes[i])
	# Through a compress/decompress cycle too — that is how ChunkManager
	# persists edited chunks in memory.
	var packed: PackedByteArray = chunk.blocks.compress()
	var restored: PackedByteArray = packed.decompress(chunk.blocks.size())
	assert_eq(restored, chunk.blocks, "FastLZ round-trip preserves every byte")


func test_reserved_and_burned_ids_survive_a_region_file_round_trip() -> void:
	# Same probe set through the on-disk region format. Uses a throwaway
	# world dir — never a real slot; SaveLoad.delete_world is a hard
	# recursive delete.
	var world: String = "test_content_registry_bytes"
	SaveLoad.delete_world(world)
	SaveLoad.clear_cache()
	var probes: Array[int] = [0, 50, 99, 100, 205, 206, 255]
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	for i: int in range(probes.size()):
		blocks[i] = probes[i]
	var empty_32k := PackedByteArray()
	empty_32k.resize(Chunk.TOTAL_BLOCKS)
	var empty_hm := PackedByteArray()
	empty_hm.resize(Chunk.SIZE_X * Chunk.SIZE_Z)
	var entry: Dictionary = {
		"bytes": blocks.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_meta": empty_32k.compress(FileAccess.COMPRESSION_FASTLZ),
		"sky_light": empty_32k.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_light": empty_32k.compress(FileAccess.COMPRESSION_FASTLZ),
		"height_map": empty_hm.compress(FileAccess.COMPRESSION_FASTLZ),
		"max_y": 70,
		"pending_ticks": [],
	}
	assert_true(SaveLoad.save_chunk(Vector2i(0, 0), entry, world), "region write succeeds")
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), world)
	assert_true(loaded.has("bytes"), "region read returns block bytes")
	if loaded.has("bytes"):
		var out: PackedByteArray = loaded["bytes"].decompress(Chunk.TOTAL_BLOCKS)
		for i: int in range(probes.size()):
			assert_eq(out[i], probes[i], "region round-trip preserves byte %d" % probes[i])
	SaveLoad.delete_world(world)


func test_every_non_air_registered_block_has_an_item_form_unless_world_only() -> void:
	for id: int in Blocks.REGISTERED_IDS:
		if id == Blocks.AIR:
			continue
		var expected: bool = not Blocks.WORLD_ONLY_IDS.has(id)
		assert_eq(Blocks.has_item_form(id), expected, "item-form policy for block id %d" % id)


func test_unregistered_ids_are_never_classified_as_content() -> void:
	for id: int in range(256):
		if Blocks.is_registered(id) or Items.is_registered(id):
			continue
		assert_false(Blocks.has_item_form(id), "unclaimed id %d has no item form" % id)
		assert_false(Blocks.has_sprite_tile(id), "unclaimed id %d has no sprite tile" % id)


func test_registry_queries_reject_out_of_range_ids() -> void:
	for id: int in [-1, -100, 256, 1000]:
		assert_false(Blocks.is_registered(id), "id %d is out of the byte range" % id)
		assert_false(Blocks.has_item_form(id), "id %d has no item form" % id)
		assert_false(Items.is_registered(id), "id %d is not an item" % id)


# --- Drift sweep: no content constant may escape its registry ---


func test_no_block_constant_escapes_the_block_registry() -> void:
	var consts: Dictionary = _int_constants("res://scripts/world/blocks.gd", _BLOCK_NON_ID_PREFIXES)
	assert_gt(consts.size(), 50, "the sweep actually found the block id constants")
	for name: String in consts.keys():
		var id: int = consts[name]
		assert_true(
			Blocks.REGISTERED_IDS.has(id),
			"Blocks.%s (= %d) is listed in Blocks.REGISTERED_IDS" % [name, id]
		)


func test_no_item_constant_escapes_the_item_registry() -> void:
	var consts: Dictionary = _int_constants("res://scripts/world/items.gd", _ITEM_NON_ID_PREFIXES)
	assert_gt(consts.size(), 50, "the sweep actually found the item id constants")
	for name: String in consts.keys():
		var id: int = consts[name]
		assert_true(
			Items.REGISTERED_IDS.has(id),
			"Items.%s (= %d) is listed in Items.REGISTERED_IDS" % [name, id]
		)


func test_registry_lists_match_the_constant_sweep_exactly() -> void:
	# The reverse direction: every listed id traces back to a named
	# constant, so the list can't accumulate ids for blocks that were
	# deleted.
	var block_values: Array = (
		_int_constants("res://scripts/world/blocks.gd", _BLOCK_NON_ID_PREFIXES).values()
	)
	for id: int in Blocks.REGISTERED_IDS:
		assert_true(block_values.has(id), "block id %d has a named constant" % id)
	var item_values: Array = (
		_int_constants("res://scripts/world/items.gd", _ITEM_NON_ID_PREFIXES).values()
	)
	for id: int in Items.REGISTERED_IDS:
		assert_true(item_values.has(id), "item id %d has a named constant" % id)


# --- Nether reservations (plan §3.1) ---


func test_reserved_nether_ids_landed_in_the_right_registry() -> void:
	for id: int in _RESERVED_BLOCK_IDS:
		assert_true(Blocks.is_registered(id), "reserved block id %d is a block" % id)
		assert_false(Items.is_registered(id), "reserved block id %d is NOT an item" % id)
	for id: int in _RESERVED_ITEM_IDS:
		assert_true(Items.is_registered(id), "reserved item id %d is an item" % id)
		assert_false(Blocks.is_registered(id), "reserved item id %d is NOT a block" % id)


func test_repeater_ids_landed_in_the_right_registry() -> void:
	for id: int in [Blocks.REDSTONE_REPEATER_OFF, Blocks.REDSTONE_REPEATER_ON]:
		assert_true(Blocks.is_registered(id), "repeater state id %d is a block" % id)
		assert_false(Items.is_registered(id), "repeater state id %d is not an item" % id)
	assert_true(Items.is_registered(Items.REDSTONE_REPEATER), "repeater inventory id is an item")
	assert_false(Blocks.is_registered(Items.REDSTONE_REPEATER), "repeater item is not a block")


func test_ids_210_to_255_are_free_for_future_content() -> void:
	for id: int in range(210, 256):
		assert_false(Blocks.is_registered(id), "id %d is free" % id)
		assert_false(Items.is_registered(id), "id %d is free" % id)
