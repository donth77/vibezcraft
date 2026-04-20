extends GutTest

# Unit tests for LeafDecay.find_orphan_leaves. Tests stub out the world
# via a Dictionary-backed get_block so we don't need a live ChunkManager.

var _blocks: Dictionary


func before_each() -> void:
	_blocks = {}


func _block_at(p: Vector3i) -> int:
	return _blocks.get(p, Blocks.AIR)


func test_four_cardinal_leaves_decay_when_only_log_removed() -> void:
	# Start: 1 log + 4 leaves touching it. Simulate the log being removed
	# by leaving it out of the dict. All 4 leaves should orphan.
	_blocks[Vector3i(1, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(-1, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(0, 0, 1)] = Blocks.LEAVES
	_blocks[Vector3i(0, 0, -1)] = Blocks.LEAVES
	var orphans := LeafDecay.find_orphan_leaves(_block_at, Vector3i(0, 0, 0))
	assert_eq(orphans.size(), 4, "all 4 leaves orphaned")


func test_leaves_stay_when_another_log_within_range() -> void:
	# Leaves chain (0..3, 0, 0); log survives at (4, 0, 0). Pretend the
	# broken log was at (-1, 0, 0). All leaves should BFS to the surviving
	# log within DECAY_RADIUS = 4 steps.
	_blocks[Vector3i(0, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(1, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(2, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(3, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(4, 0, 0)] = Blocks.LOG
	var orphans := LeafDecay.find_orphan_leaves(_block_at, Vector3i(-1, 0, 0))
	assert_eq(orphans.size(), 0, "all leaves stay — log within BFS range")


func test_far_leaf_beyond_decay_radius_orphans() -> void:
	# Chain of 5 leaves plus a log at (6, 0, 0). The leaf at (0, 0, 0)
	# needs 6 BFS steps through leaves to reach the log — past the 4-step
	# limit — so it orphans. Closer leaves stay.
	_blocks[Vector3i(0, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(1, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(2, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(3, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(4, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(5, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(6, 0, 0)] = Blocks.LOG
	var orphans := LeafDecay.find_orphan_leaves(_block_at, Vector3i(-1, 0, 0))
	# Leaf (0,0,0): 6 steps to log. Out of range.
	# Leaf (1,0,0): 5 steps. Out of range.
	# Leaf (2,0,0): 4 steps. At the boundary — BFS explores to dist=3 then
	#   checks neighbors at dist=4, so reaches log.
	# Leaves (3..5, 0, 0): ≤3 steps. In range.
	assert_true(Vector3i(0, 0, 0) in orphans, "leaf 6 steps away is orphaned")
	assert_true(Vector3i(1, 0, 0) in orphans, "leaf 5 steps away is orphaned")
	assert_false(Vector3i(2, 0, 0) in orphans, "leaf exactly 4 steps away stays")
	assert_false(Vector3i(3, 0, 0) in orphans, "leaf 3 steps away stays")


func test_only_leaves_within_scan_radius_are_considered() -> void:
	# Leaf far from the broken log should not be scanned at all, even if
	# it would be orphaned in isolation.
	var far := Vector3i(100, 0, 0)
	_blocks[far] = Blocks.LEAVES
	var orphans := LeafDecay.find_orphan_leaves(_block_at, Vector3i(0, 0, 0))
	assert_false(far in orphans, "leaf outside scan cube ignored")


func test_empty_world_no_orphans() -> void:
	var orphans := LeafDecay.find_orphan_leaves(_block_at, Vector3i(0, 0, 0))
	assert_eq(orphans.size(), 0)


func test_bfs_does_not_hop_through_non_leaf_solids() -> void:
	# Put a DIRT block between a leaf and a log — BFS should not tunnel
	# through the dirt, so the leaf orphans despite the log being "close".
	_blocks[Vector3i(0, 0, 0)] = Blocks.LEAVES
	_blocks[Vector3i(1, 0, 0)] = Blocks.DIRT
	_blocks[Vector3i(2, 0, 0)] = Blocks.LOG
	var orphans := LeafDecay.find_orphan_leaves(_block_at, Vector3i(-1, 0, 0))
	assert_true(Vector3i(0, 0, 0) in orphans, "leaf blocked from log by non-leaf solid orphans")
