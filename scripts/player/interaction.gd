# gdlint: disable=max-file-lines
extends Node

# Raycast-based block break/place wired into the player's Inventory.
#   Break: hold LMB; progress accumulates; on completion the block is removed
#   and Blocks.drops(id) goes into the inventory. Crack overlay + looped dig
#   sound provide visual + audio feedback during the hold.
#   Place: RMB (single click). Consumes one of the selected hotbar slot.

const REACH: float = 5.0
const PLACE_COOLDOWN_MS: int = 50
const DIG_SOUND_INTERVAL_MS: int = 300
# Vanilla bz.java:114-143 spawns ONE EntityDiggingFX per tick (50 ms at
# 20 TPS) at the face being mined. We match vanilla's per-tick cadence
# so the dig face has the same crumb density as the original. BlockFx's
# mining pool absorbs the 50ms × 0.35s = ~7 in-flight emitters cheaply.
const MINING_PARTICLE_INTERVAL_MS: int = 50
# preload() instead of `class_name BlockFx` direct ref — Godot's editor
# class index lags one reload behind for new class_name files (same trick
# chunk_manager.gd uses for TickScheduler). Headless `--check-only` parses
# this script before block_fx.gd is registered, so the direct identifier
# would fail at parse time.
const _BLOCK_FX: GDScript = preload("res://scripts/world/block_fx.gd")
const NO_TARGET: Vector3i = Vector3i(-2147483648, -2147483648, -2147483648)
const CRACK_ATLAS_PATH: String = "res://assets/textures/effects/destroy_stages.png"
# Hoe + farmland are Beta 1.6 additions, not in Alpha 1.2.6. The recipe
# is disabled so normal players can't craft a hoe, but the till logic
# stays enabled so devs who debug-grant a hoe (J in debug mode) can still
# exercise the full path.
const HOE_TILL_ENABLED: bool = true
# Preload the script so we can `is`-test without depending on the
# class_name cache (which only populates after an editor scan; headless
# test runs don't trigger that scan).
const _MOB_BASE_SCRIPT := preload("res://scripts/entities/mob_base.gd")

var _last_place_ms: int = 0
# Cached player ref for the food-eating handler. find_child walks the
# tree, so we cache the result and re-resolve only when the cached
# node has been freed (scene transition). Same pattern as ItemIcons.
var _cached_player: Node = null
var _highlight: MeshInstance3D
var _crack: MeshInstance3D
var _crack_material: ShaderMaterial
var _crack_stages: int = 6  # auto-detected from texture; default falls back to 6

# Hold-to-break state
var _mining_target: Vector3i = NO_TARGET
var _mining_progress: float = 0.0
var _mining_total_time: float = 0.0
var _last_dig_sound_ms: int = 0
var _last_mining_particle_ms: int = 0
# Wall-clock timestamp when the current mining session started (sec).
# Used purely by the debug logger to compare expected vs measured break.
var _mining_started_at: float = 0.0

@onready var _camera: Camera3D = get_parent().get_node("Camera3D")
@onready var _chunk_manager: Node3D = get_tree().root.get_node_or_null("Main/ChunkManager")


func _ready() -> void:
	_highlight = _build_highlight()
	_crack = _build_crack()
	_crack_material = _crack.material_override as ShaderMaterial
	# Parent under stationary ChunkManager so world-space overlays don't
	# inherit the player transform.
	var parent: Node = _chunk_manager if _chunk_manager != null else self
	parent.add_child(_highlight)
	parent.add_child(_crack)


func _process(delta: float) -> void:
	if not _world_input_active():
		# Inventory or other modal UI is up — drop any in-progress mining and
		# stop highlighting so the player isn't accidentally breaking a block
		# while clicking around the inventory.
		_set_player_mining(false)
		_reset_mining()
		_highlight.visible = false
		return
	var hit := _raycast()
	_update_highlight(hit)
	_update_mining(hit, delta)


func _unhandled_input(event: InputEvent) -> void:
	if not _world_input_active():
		return
	if event.is_action_pressed("interact_place"):
		_try_place()
	# Left-click attack: on the EDGE of interact_break (just-pressed),
	# check whether the raycast hits a MobBase. If yes, deal a hit and
	# skip the mining path entirely (a mob in front of you shouldn't
	# trigger block mining behind it). The hold-to-mine path in
	# _update_mining still runs continuously for blocks.
	if event.is_action_pressed("interact_break"):
		_try_attack_mob()


# Returns true if the raycast hit a MobBase and damage was dealt.
# Knockback direction = camera forward × XZ (no vertical component on
# attacker side; vanilla applies the +0.4 vertical kick inside the
# entity's take_damage path).
func _try_attack_mob() -> bool:
	var hit: Dictionary = _raycast()
	if hit.is_empty():
		return false
	var collider: Node = hit.get("collider") as Node
	if collider == null:
		return false
	# The raycast collider might be the mob's CollisionShape3D or the
	# CharacterBody3D itself depending on what the physics server hit.
	# Walk up the tree until we find a node whose script extends MobBase.
	var mob: Node = null
	var node: Node = collider
	while node != null:
		var script: Script = node.get_script()
		if script != null and _script_extends(script, _MOB_BASE_SCRIPT):
			mob = node
			break
		node = node.get_parent()
	if mob == null:
		return false
	# Damage amount = held tool's melee value (vanilla
	# ItemSword.getDamageVsEntity returns 4..7 by tier; non-weapon items
	# return 1). Items.melee_damage encapsulates the lookup.
	var attacker_xz := -_camera.global_transform.basis.z
	attacker_xz.y = 0.0
	var inv: Inventory = _player_inventory()
	var held_id: int = 0
	if inv != null:
		var stack: ItemStack = inv.selected()
		if stack != null and not stack.is_empty():
			held_id = stack.item_id
	var damage: int = Items.melee_damage(held_id)
	mob.call("take_damage", damage, attacker_xz)
	_trigger_player_use_swing()
	SFX.play_player_hit()
	# Tool durability — vanilla swords + tools take 1 durability per
	# attack (ItemSword.hitEntity). Other items (hand, food, etc.) don't.
	if inv != null and held_id != 0 and Items.is_tool_item(held_id):
		if inv.damage_selected_tool():
			SFX.play_tool_break()
	return true


# Walk a script's base-script chain looking for `target`. Used to test
# "is a MobBase" without relying on class_name registration.
static func _script_extends(script: Script, target: Script) -> bool:
	var s: Script = script
	while s != null:
		if s == target:
			return true
		s = s.get_base_script()
	return false


# True if the raycast hit's collider is (or is a child of) a MobBase.
# Used by _update_highlight to suppress the block-selection cube on
# mobs and by _try_attack_mob to route LMB to take_damage.
func _hit_collider_is_mob(hit: Dictionary) -> bool:
	return _find_mob_from_hit(hit) != null


# Walk the collider's ancestor chain looking for a MobBase descendant.
# Returns the mob node or null. Used by both the highlight suppress
# and the right-click mount/saddle path.
func _find_mob_from_hit(hit: Dictionary) -> Node:
	var collider: Node = hit.get("collider") as Node
	if collider == null:
		return null
	var node: Node = collider
	while node != null:
		var script: Script = node.get_script()
		if script != null and _script_extends(script, _MOB_BASE_SCRIPT):
			return node
		node = node.get_parent()
	return null


# Returns true if the right-click was consumed by a mob (saddle apply,
# mount, etc.). The mob decides what to do — Pig.right_click_with
# checks for SADDLE in hand to saddle itself, or swallows the click if
# already saddled (defers mount until M1c). Falling through to a block
# place is suppressed when this returns true.
func _try_right_click_mob(hit: Dictionary) -> bool:
	var mob: Node = _find_mob_from_hit(hit)
	if mob == null:
		return false
	if not mob.has_method("right_click_with"):
		return false
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	var stack: ItemStack = inv.selected()
	var held_id: int = stack.item_id if stack != null and not stack.is_empty() else 0
	var consumed: bool = mob.call("right_click_with", held_id, get_parent())
	if not consumed:
		return false
	# If the mob accepted a saddle, decrement the held stack so the
	# player can't infinitely re-saddle. Other items (mount-without-
	# consume case) leave the stack alone.
	if held_id == Items.SADDLE and stack != null and not stack.is_empty():
		inv.consume_one_selected()
	return true


func _world_input_active() -> bool:
	# Mouse-captured == playing the game; visible == a UI screen owns input.
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _update_highlight(hit: Dictionary) -> void:
	if hit.is_empty():
		_highlight.visible = false
		return
	# Suppress the block-selection wireframe when the cursor is over a
	# mob. The mob's CharacterBody3D collision shape registers as a hit
	# the same way a block does; without this check the highlight cube
	# would render around whatever AIR cell the mob's body happens to
	# occupy. Vanilla MC also doesn't show the block outline on mobs.
	if _hit_collider_is_mob(hit):
		_highlight.visible = false
		return
	_highlight.visible = true
	# Per-block selection AABB — defaults to a unit cube but plants get
	# the tighter vanilla bbox (sapling = (0.1,0,0.1)..(0.9,0.8,0.9), per
	# BlockSapling() in Bukkit/mc-dev). The base wireframe is a unit cube
	# centered on origin; we scale + offset it to match the per-block AABB.
	# Torches use meta-aware AABBs (vanilla ob.java:122-138) so wall-mount
	# variants get the correct offset against the support wall instead of
	# floating in the air cell next to it.
	var hit_id: int = _chunk_manager.get_world_block(hit.block_pos)
	var hit_meta: int = _chunk_manager.get_world_block_meta(hit.block_pos)
	var aabb: AABB = Blocks.selection_aabb(hit_id, hit_meta)
	_highlight.scale = aabb.size
	_highlight.global_position = Vector3(hit.block_pos) + aabb.position + aabb.size * 0.5
	_highlight.rotation = Vector3.ZERO


func _update_mining(hit: Dictionary, delta: float) -> void:
	var holding: bool = Input.is_action_pressed("interact_break")
	# Releasing LMB always cancels mining + the swing animation. Holding
	# LMB but raycasting empty (chunk re-mesh frame, micro-jitter, looked
	# away for a tick) does NOT reset — vanilla accumulates progress as
	# long as the click is held and only re-targets when a different
	# block is under the cursor.
	if not holding:
		_set_player_mining(false)
		_reset_mining()
		return
	if hit.is_empty() or _chunk_manager == null:
		# Stop the animation but PRESERVE progress so a one-frame miss
		# during chunk re-mesh doesn't undo seconds of work.
		_set_player_mining(false)
		return
	_set_player_mining(true)
	var target: Vector3i = hit.block_pos
	# Creative mode: instant break, ignore bedrock indestructibility, always drop
	if _is_creative():
		_creative_break(target)
		_reset_mining()
		return
	# Stale-collider guard: after a block break, the chunk's trimesh is
	# rebuilt on a worker so for 1-3 frames the raycast still hits the old
	# geometry at the just-emptied cell. Block data is authoritative and
	# already says AIR; treating that hit as a mineable block makes
	# `Blocks.break_time(AIR, ...)` fall through hardness' match and return
	# the default 1.0 hardness → a spurious ~1.5 s "slow" timer that the
	# player sees as the crack resetting and progressing slowly.
	var target_id_now: int = _chunk_manager.get_world_block(target)
	if target_id_now == Blocks.AIR:
		_set_player_mining(false)
		return
	if target != _mining_target:
		_start_mining(target)
		if _mining_total_time < 0.0:
			# Unbreakable (bedrock). Bail.
			_reset_mining()
			return
	_mining_progress += delta
	# Loop the dig sound every ~300ms while mining
	var now: int = Time.get_ticks_msec()
	if now - _last_dig_sound_ms >= DIG_SOUND_INTERVAL_MS:
		_last_dig_sound_ms = now
		var id: int = _chunk_manager.get_world_block(target)
		SFX.play_break(id)
	# Vanilla bz.java:114-143 — sprinkle one EntityDiggingFX per tick at
	# the face being hit. We spawn at MINING_PARTICLE_INTERVAL_MS cadence
	# (every ~3 vanilla ticks) so the trickle is visible without flooding.
	# `hit.normal_i` is the OUTWARD face normal (e.g. (0,1,0) for top).
	if now - _last_mining_particle_ms >= MINING_PARTICLE_INTERVAL_MS:
		_last_mining_particle_ms = now
		var mining_id: int = _chunk_manager.get_world_block(target)
		_BLOCK_FX.spawn_mining(_chunk_manager, target, mining_id, Vector3(hit.normal_i))
	# Update crack overlay — pick the integer stage based on progress.
	# Position + scale to the block's selection AABB so non-cube blocks
	# (snow_layer slab, etc.) get a crack matching the visible shape
	# rather than a full 1x1x1 box floating above the slab.
	var damage: float = clamp(_mining_progress / _mining_total_time, 0.0, 1.0)
	var stage: int = clamp(int(damage * float(_crack_stages)), 0, _crack_stages - 1)
	var hit_id_now: int = _chunk_manager.get_world_block(target)
	var hit_meta_now: int = _chunk_manager.get_world_block_meta(target)
	var crack_aabb: AABB = Blocks.selection_aabb(hit_id_now, hit_meta_now)
	_crack.visible = true
	_crack.global_position = Vector3(target) + crack_aabb.position + crack_aabb.size * 0.5
	_crack.scale = crack_aabb.size
	_crack_material.set_shader_parameter("stage", stage)
	# Complete the break?
	if _mining_progress >= _mining_total_time:
		_complete_break(target)
		_reset_mining()


func _start_mining(target: Vector3i) -> void:
	_mining_target = target
	_mining_progress = 0.0
	_last_dig_sound_ms = 0
	_last_mining_particle_ms = 0
	var id: int = _chunk_manager.get_world_block(target)
	var tool_id: int = _held_tool_id()
	_mining_total_time = Blocks.break_time(id, tool_id)
	# Underwater dig penalty — vanilla EntityPlayer.getPlayerRelativeBlockHardness
	# (mc-dev) multiplies block hardness by 0.2 (i.e. takes 5× longer) when
	# `isInsideOfMaterial(WATER)`. Applied here so the crack animation +
	# completion stay in sync with the actual slower timing.
	if _mining_total_time > 0.0 and _head_submerged_in_water():
		_mining_total_time *= 5.0
	_mining_started_at = Time.get_ticks_msec() / 1000.0
	if Game.debug_mining:
		print(
			(
				"[Mine START] block=%s tool=%s expected=%.3fs (speed=%.1f)"
				% [
					Blocks.name_of(id),
					Items.display_name(tool_id),
					_mining_total_time,
					Items.tool_speed(tool_id),
				]
			)
		)


# True if the player's eye cell is water. Mirrors player._head_in_water;
# re-derived here so interaction.gd doesn't need a hard dep on the
# concrete Player class (same pattern as _is_creative()'s untyped `get`).
func _head_submerged_in_water() -> bool:
	if _chunk_manager == null:
		return false
	var player: Node3D = get_parent() as Node3D
	if player == null:
		return false
	var head_cell := Vector3i(
		int(floor(player.global_position.x)),
		int(floor(player.global_position.y + 0.7)),
		int(floor(player.global_position.z))
	)
	return Blocks.is_water(_chunk_manager.get_world_block(head_cell))


# Returns the currently-selected tool item id (or AIR if no tool/empty).
# Used for break-time + drop calculations.
func _held_tool_id() -> int:
	var inv: Inventory = _player_inventory()
	if inv == null:
		return Blocks.AIR
	var stack: ItemStack = inv.selected()
	if stack == null or stack.is_empty():
		return Blocks.AIR
	if not Items.is_tool_item(stack.item_id):
		return Blocks.AIR
	return stack.item_id


func _reset_mining() -> void:
	_mining_target = NO_TARGET
	_mining_progress = 0.0
	_mining_total_time = 0.0
	_crack.visible = false


func _complete_break(target: Vector3i) -> void:
	var broken_id: int = _chunk_manager.get_world_block(target)
	if broken_id == Blocks.AIR or broken_id == Blocks.BEDROCK:
		return
	if Game.debug_mining:
		var elapsed: float = Time.get_ticks_msec() / 1000.0 - _mining_started_at
		var tool_id: int = _held_tool_id()
		print(
			(
				"[Mine DONE]  block=%s tool=%s expected=%.3fs measured=%.3fs (Δ=%+.3fs)"
				% [
					Blocks.name_of(broken_id),
					Items.display_name(tool_id),
					_mining_total_time,
					elapsed,
					elapsed - _mining_total_time,
				]
			)
		)
	# Furnaces hold a tile-entity dict (input/fuel/output). Spit those
	# contents out as dropped items BEFORE the block disappears, then
	# clear the entry so the coord can be reused.
	if broken_id == Blocks.FURNACE or broken_id == Blocks.LIT_FURNACE:
		_drop_furnace_contents(target)
	# Same vanilla rule for chests — tile-entity contents drop as items
	# when the block is broken, then ChestStorage forgets the position.
	if broken_id == Blocks.CHEST:
		_drop_chest_contents(target)
	# Doors: break both halves. Upper drops nothing (gv.java:163), lower
	# drops the door item. Also remove the partner half.
	if broken_id == Blocks.WOODEN_DOOR or broken_id == Blocks.IRON_DOOR:
		_break_door(target, broken_id)
		return
	# Async re-mesh — chunk_manager.set_world_block flips chunk.dirty + a
	# `_priority_apply` flag on the chunk_node so the result skips the
	# 1-per-frame apply budget queue (avoids the ghost-block bug where the
	# player's edit got stuck behind background relight churn). Worker
	# still does the heavy mesh build off-main, so no frame-spike from
	# the GDScript mesher path on chunks with non-cube blocks.
	_chunk_manager.set_world_block(target, Blocks.AIR)
	SFX.play_break(broken_id)
	# Vanilla bz.java:95-112 → ki.java (EntityDiggingFX). 24-particle
	# burst sampled from the block's atlas region, tinted to 60% so it
	# reads as crumbs rather than full-bright tile fragments.
	# preload() instead of the class_name — Godot's editor class index
	# lags one reload behind for new class_name files (TickScheduler had
	# the same issue). The preload path doesn't depend on the index.
	_BLOCK_FX.spawn_break(_chunk_manager, target, broken_id)
	# Drop is gated by tool tier — bare hand on stone yields nothing,
	# wrong-tier pick on iron ore yields nothing, etc.
	# Multi-drop blocks (bookshelf → 3 books) loop random_drop so each
	# slot rolls independently — preserves leaves-sapling / gravel-flint
	# semantics for any future multi-drop block that wants the random
	# tier mixed in.
	# CROPS has variable-item drops (wheat + 0..3 seeds) — route through
	# a special-case helper instead of the uniform-count loop above.
	if broken_id == Blocks.CROPS:
		for item_id in _farm_drops(broken_id, target):
			_spawn_dropped_item(target, item_id)
	else:
		var n_drops: int = Blocks.drop_quantity(broken_id)
		for _i in range(n_drops):
			var dropped_id: int = Blocks.random_drop(broken_id, _held_tool_id())
			if dropped_id != Blocks.AIR:
				_spawn_dropped_item(target, dropped_id)
	# Tool durability — vanilla loses 1 use per block broken (regardless of
	# whether the break "counted" for a drop). Snap sound on the final hit.
	var inv: Inventory = _player_inventory()
	if inv != null and inv.damage_selected_tool():
		SFX.play_tool_break()


func _drop_furnace_contents(target: Vector3i) -> void:
	if not FurnaceManager.has_furnace(target):
		return
	var state: Dictionary = FurnaceManager.get_or_create(target)
	for stack: ItemStack in [state.input, state.fuel, state.output]:
		if not stack.is_empty():
			for i in range(stack.count):
				_spawn_dropped_item(target, stack.item_id)
	FurnaceManager.forget(target)


# Spit out every non-empty stack in the chest, one DroppedItem per item
# (matches the per-item burst vanilla MC produces from
# Block.dropAsStack). Then forget the position so a future chest at the
# same coords starts empty.
func _drop_chest_contents(target: Vector3i) -> void:
	if not ChestStorage.has_chest(target):
		return
	for stack: ItemStack in ChestStorage.contents_snapshot(target):
		for i in range(stack.count):
			_spawn_dropped_item(target, stack.item_id)
	ChestStorage.forget(target)


# Break a door — removes both halves, drops the door item only from the lower.
# Vanilla gv.java:162-170: upper half `(n2 & 8) != 0` → return 0 (no drop).
func _break_door(target: Vector3i, door_id: int) -> void:
	var meta: int = _chunk_manager.get_world_block_meta(target)
	var is_upper: bool = (meta & 8) != 0
	var lower: Vector3i = target if not is_upper else target + Vector3i(0, -1, 0)
	var upper: Vector3i = target if is_upper else target + Vector3i(0, 1, 0)
	_chunk_manager.set_world_block(lower, Blocks.AIR)
	if _chunk_manager.get_world_block(upper) == door_id:
		_chunk_manager.set_world_block(upper, Blocks.AIR)
	SFX.play_break(door_id)
	_BLOCK_FX.spawn_break(_chunk_manager, target, door_id)
	# Only the lower half drops the item.
	var dropped_id: int = Blocks.random_drop(door_id, _held_tool_id())
	if dropped_id != Blocks.AIR:
		_spawn_dropped_item(lower, dropped_id)
	var inv: Inventory = _player_inventory()
	if inv != null and inv.damage_selected_tool():
		SFX.play_tool_break()


func _spawn_dropped_item(block_pos: Vector3i, dropped_id: int) -> void:
	var item := DroppedItem.new()
	var spawn_pos := Vector3(block_pos) + Vector3(0.5, 0.5, 0.5)
	_chunk_manager.add_child(item)
	item.global_position = spawn_pos
	item.setup(dropped_id)


func _creative_break(target: Vector3i) -> void:
	var broken_id: int = _chunk_manager.get_world_block(target)
	if broken_id == Blocks.AIR:
		return
	# Doors: break both halves in creative too.
	if broken_id == Blocks.WOODEN_DOOR or broken_id == Blocks.IRON_DOOR:
		var meta: int = _chunk_manager.get_world_block_meta(target)
		var partner: Vector3i = (
			target + Vector3i(0, -1, 0) if (meta & 8) != 0 else target + Vector3i(0, 1, 0)
		)
		_chunk_manager.set_world_block(target, Blocks.AIR)
		if _chunk_manager.get_world_block(partner) == broken_id:
			_chunk_manager.set_world_block(partner, Blocks.AIR)
		SFX.play_break(broken_id)
		_BLOCK_FX.spawn_break(_chunk_manager, target, broken_id)
		var inventory: Inventory = _player_inventory()
		if inventory != null:
			inventory.add_item(Blocks.drops(broken_id), 1)
		return
	_chunk_manager.set_world_block(target, Blocks.AIR)
	SFX.play_break(broken_id)
	_BLOCK_FX.spawn_break(_chunk_manager, target, broken_id)
	# Creative: skip the dropped-item dance, go straight to inventory
	var inventory: Inventory = _player_inventory()
	if inventory != null:
		inventory.add_item(broken_id, 1)


func _is_creative() -> bool:
	var player: Node = get_parent()
	if "creative_mode" in player:
		return player.get("creative_mode") as bool
	return false


# gdlint: disable=max-returns
func _try_place() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_place_ms < PLACE_COOLDOWN_MS:
		return
	var hit := _raycast()
	if _chunk_manager == null:
		return
	# Mob right-click (saddle, mount, etc.) — runs before block-place so
	# right-clicking a pig with a saddle doesn't try to place the saddle
	# as a block. Returns true if the mob consumed the click.
	if _try_right_click_mob(hit):
		_last_place_ms = now
		return
	# Buckets run even when `hit` is empty — the bucket's fluid-aware scan
	# handles pointing at open water (no collider → raycast passes through)
	# and pointing at open sky for lava-source placement.
	var held_inv: Inventory = _player_inventory()
	if held_inv != null:
		var held_stack: ItemStack = held_inv.selected()
		if held_stack != null and not held_stack.is_empty():
			var held_id: int = held_stack.item_id
			# Food — Alpha-style instant eat: right-click → restore HP +
			# decrement stack. Runs BEFORE the hit-required branches so
			# the player can eat while pointing at sky / no target block.
			# Vanilla qk.a (ItemFood) — see Items.food_value for source.
			if Items.is_food(held_id):
				if _try_eat_food(held_id):
					_last_place_ms = now
				return
			# Fishing rod — cast / reel. Vanilla bj.java::a checks
			# player.fishEntity; if set, reels in (catches if bite
			# active), else casts a new bobber. Hit-irrelevant so this
			# fires regardless of what the player is pointing at.
			if held_id == Items.FISHING_ROD:
				if _try_fishing_rod():
					_last_place_ms = now
				return
			if (
				held_id == Items.BUCKET_EMPTY
				or held_id == Items.BUCKET_WATER
				or held_id == Items.BUCKET_LAVA
			):
				if _try_bucket(hit, -1):
					_last_place_ms = now
				return
	if hit.is_empty():
		return
	# RMB on a placed crafting table opens its 3x3 craft screen instead of
	# placing whatever the player is holding. Vanilla MC behavior.
	var hit_id: int = _chunk_manager.get_world_block(hit.block_pos)
	if hit_id == Blocks.CRAFTING_TABLE:
		_open_crafting_table()
		_last_place_ms = now
		return
	if hit_id == Blocks.FURNACE or hit_id == Blocks.LIT_FURNACE:
		_open_furnace(hit.block_pos)
		_last_place_ms = now
		return
	if hit_id == Blocks.CHEST:
		_open_chest(hit.block_pos)
		_last_place_ms = now
		return
	if hit_id == Blocks.WOODEN_DOOR:
		_toggle_door(hit.block_pos, hit_id)
		_last_place_ms = now
		return
	# Hoe + dirt/grass + top face hit + air above → till to farmland.
	# Verbatim from ItemHoe.interactWith (Bukkit/mc-dev).
	if _try_hoe_till(hit, hit_id):
		_last_place_ms = now
		return
	# Flint and steel — vanilla nv.java a(...): right-click on a face
	# of an opaque block places FIRE in the air cell on the face's
	# normal side, costs 1 durability.
	if _try_flint_and_steel(hit, hit_id):
		_last_place_ms = now
		return
	# Bone meal on sapling → instant tree growth. Vanilla
	# IBlockFragilePlantElement.b() in BlockSapling: rolls 0.45 chance
	# per use to advance the growth, with two stages to clear before the
	# tree pops; expected uses ≈ 4.4 to fully grow. We collapse the two
	# stages into one — same end state, half the bonemeal grind.
	if _try_bonemeal(hit, hit_id):
		_last_place_ms = now
		return
	# Bucket — fills from water/lava source on pointed cell OR places
	# fluid source at (hit.block_pos + normal) if holding a filled bucket.
	# Mirrors vanilla ItemBucket.use (ds.java). (Handled above when hit
	# is empty — this branch catches the solid-hit case.)
	if _try_bucket(hit, hit_id):
		_last_place_ms = now
		return
	if _place_block_from_held(hit):
		_last_place_ms = now


# Returns true if a hoe-till happened (caller should then update cooldown).
# Alpha-style instant eat. Mirrors vanilla qk.a (ItemFood):
#   --au.a;          // stack count -= 1
#   ay.j(this.b);    // player.heal(food_value)
#   return au;
# Mushroom stew is a special case (au.java extends qk): the stew is
# consumed but the slot is replaced with an empty bowl instead of
# decrementing to zero (au.java line 8: au.a == 0 ? new au(dx.C) : au).
# Returns true if the item was eaten (so caller can refresh cooldown +
# inventory state).
#
# Skips the heal when the player is already at full HP — vanilla qk
# does NOT skip (the heal is just clamped in player.j()), but eating
# at full HP would waste the food with no visible effect, which is a
# common QoL deviation; mirror that here.
func _try_eat_food(item_id: int) -> bool:
	var player_node: Node = _player_node()
	if player_node == null:
		return false
	var heal: int = Items.food_value(item_id)
	if heal <= 0:
		return false
	# Skip when full — common QoL deviation from strict vanilla (which
	# wastes the food regardless). If you want bit-exact Alpha, drop
	# this guard and the heal-at-cap line below.
	#
	# Node.get("CONST_NAME") doesn't see GDScript consts (only vars), so
	# we read MAX_HEALTH by literal — kept in sync with player.gd:73.
	const MAX_HP_CAP: int = 20
	var cur_hp: int = int(player_node.get("health"))
	if cur_hp >= MAX_HP_CAP:
		return false
	var max_hp: int = MAX_HP_CAP
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	# Apply heal first, then mutate the inventory. The order doesn't
	# matter functionally but keeps the player.health_changed signal
	# firing before the inventory.changed signal — UI repaint order.
	player_node.set("health", mini(max_hp, cur_hp + heal))
	if player_node.has_signal("health_changed"):
		player_node.emit_signal("health_changed", int(player_node.get("health")), max_hp)
	if item_id == Items.MUSHROOM_STEW:
		# Stack-of-1 by definition; swap the single stew for an empty bowl
		# in place so the player still holds something edible-adjacent.
		inv.replace_selected(Items.BOWL, 1)
	else:
		inv.consume_one_selected()
	# Eating arm-swing — vanilla shows the held food bobbing during the
	# eat animation (Beta 1.8 added the multi-frame chew; Alpha was a
	# single swing).
	_trigger_player_use_swing()
	return true


func _player_node() -> Node:
	if _cached_player != null and is_instance_valid(_cached_player):
		return _cached_player
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	_cached_player = tree.root.find_child("Player", true, false)
	return _cached_player


# Mirrors vanilla ItemHoe.interactWith: requires dirt/grass at hit.block_pos,
# air directly above it, top face was clicked. On success: replace with
# FARMLAND, damage hoe, play gravel-step sound.
#
# Currently enabled (HOE_TILL_ENABLED = true) because debug-mode players
# can grant themselves a hoe via J. The recipe is disabled separately
# (recipes.json _disabled), so normal players never reach this path.
func _try_hoe_till(hit: Dictionary, hit_id: int) -> bool:
	if not HOE_TILL_ENABLED:
		return false
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	var stack: ItemStack = inv.selected()
	if stack.is_empty() or Items.tool_type(stack.item_id) != Items.TOOL_TYPE_HOE:
		return false
	# Vanilla rejects: not dirt/grass, bottom-face hit, or air-above check.
	# Our `normal_i.y == 1` means the TOP face was hit (looking down at it).
	var above: Vector3i = hit.block_pos + Vector3i(0, 1, 0)
	var ok: bool = (
		(hit_id == Blocks.DIRT or hit_id == Blocks.GRASS)
		and hit.normal_i.y == 1
		and _chunk_manager.get_world_block(above) == Blocks.AIR
	)
	if not ok:
		return false
	_chunk_manager.set_world_block(hit.block_pos, Blocks.FARMLAND)
	SFX.play_hoe_till()
	if inv.damage_selected_tool():
		SFX.play_tool_break()
	return true


# Returns true if a flint-and-steel ignition fired (caller updates cooldown).
# Vanilla nv.java::ItemFlintAndSteel.a(...) places FIRE in the AIR cell
# adjacent to the face hit, on the face's outward normal. Conditions:
#   * Held item is FLINT_AND_STEEL.
#   * Target cell is opaque (i.e. has a face the player could click).
#   * Cell at (hit.block_pos + normal_i) is AIR (place fire there).
# Costs 1 durability per ignition; plays the fizz SFX. Vanilla also re-
# uses the same right-click handler to ignite TNT (deferred — no TNT yet)
# and to detonate creepers (deferred — no mobs yet).
func _try_flint_and_steel(hit: Dictionary, hit_id: int) -> bool:
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	var stack: ItemStack = inv.selected()
	if stack.is_empty() or stack.item_id != Items.FLINT_AND_STEEL:
		return false
	# TNT branch — vanilla v.java::b(world, x, y, z, meta) fires from the
	# right-click handler on the BLOCK itself, not the adjacent face. So
	# clicking directly on a TNT cube replaces the block with a primed
	# entity instead of dropping fire on top of it.
	if hit_id == Blocks.TNT:
		return _ignite_tnt(hit.block_pos, inv)
	# Need a solid (opaque) target so there's a face to ignite against;
	# clicking sky / leaves shouldn't drop a free-floating fire.
	if not Blocks.is_opaque(hit_id):
		return false
	# Place fire on the air cell touching the hit face. normal_i points
	# OUTWARD from that face (e.g. (0,1,0) for top), so block_pos +
	# normal_i is the AIR cell where fire lands.
	var fire_pos: Vector3i = hit.block_pos + hit.normal_i
	if _chunk_manager.get_world_block(fire_pos) != Blocks.AIR:
		return false
	_chunk_manager.set_world_block(fire_pos, Blocks.FIRE)
	# Kickstart the spread/decay loop — without this, fire just sits
	# there static and never spreads to adjacent flammables.
	TickScheduler.schedule(fire_pos, Blocks.FIRE, BlockFire.TICK_RATE)
	# `random.click` at pitch 0.9 — see SFX.play_flint_and_steel for the
	# vanilla audio note (Alpha was silent; modern MC plays a metallic
	# strike). Click-at-low-pitch is the closest tactile substitute we
	# have without bundling a dedicated fire.ignite OGG.
	SFX.play_flint_and_steel()
	if inv.damage_selected_tool():
		SFX.play_tool_break()
	return true


# Replace a TNT block with a primed-TNT entity at the cell center. Mirrors
# vanilla v.java::b() — the block becomes air, an EntityTNTPrimed spawns
# with the default 80-tick (4-second) fuse, and `random.fuse` plays once.
# Costs 1 durability per ignition same as fire-placing.
func _ignite_tnt(target: Vector3i, inv: Inventory) -> bool:
	_chunk_manager.set_world_block(target, Blocks.AIR)
	var primed = PrimedTNT.new()
	_chunk_manager.add_child(primed)
	primed.global_position = Vector3(target) + Vector3(0.5, 0.5, 0.5)
	primed.setup()
	# Tool durability — vanilla loses 1 per ignition (BlockTNT path uses
	# the same ItemFlintAndSteel.a() handler as fire placement, which
	# consumes durability unconditionally). Don't play the click cue —
	# the fuse hiss already plays from the primed entity's _ready.
	if inv.damage_selected_tool():
		SFX.play_tool_break()
	return true


# Returns true if a bonemeal use was consumed (caller updates cooldown).
# Vanilla rules (BlockSapling.IBlockFragilePlantElement.a/b in mc-dev):
# bonemeal on a sapling has a 45% chance to advance growth; on success
# the sapling either advances stage or grows into a tree. We collapse
# the two stages into one growth step. The dice roll matches vanilla so
# the player still feels the "needs a few uses" pacing.
func _try_bonemeal(hit: Dictionary, hit_id: int) -> bool:
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	var stack: ItemStack = inv.selected()
	if stack.is_empty() or stack.item_id != Items.BONEMEAL:
		return false
	# Sapling — 45% chance per use of growing the tree (vanilla). A
	# whiff still consumes one bonemeal.
	if hit_id == Blocks.SAPLING:
		if randf() < 0.45:
			_chunk_manager.grow_tree_at(hit.block_pos)
		inv.consume_one_selected()
		_trigger_player_use_swing()
		return true
	# Crops — vanilla BlockCrops.fertilize advances meta straight to
	# mature (7). Always succeeds (no random roll) and consumes one
	# bonemeal. No-op if the crop is already mature.
	if hit_id == Blocks.CROPS:
		var meta: int = _chunk_manager.get_world_block_meta(hit.block_pos)
		if meta < 7:
			_chunk_manager.set_world_block(hit.block_pos, Blocks.CROPS, 7)
			# Cancel the pending growth tick — the crop is mature now.
			TickScheduler.cancel(hit.block_pos, Blocks.CROPS)
		inv.consume_one_selected()
		_trigger_player_use_swing()
		return true
	return false


# Bucket use — covers three cases mirroring ds.java::ItemBucket.a() :
#   1. Empty bucket + nearest fluid source along look-ray: fill bucket,
#      destroy the source cell. (Alpha lets you bucket-up a source block
#      for free.)
#   2. Filled bucket: place the fluid source at (hit.block_pos + normal)
#      if that cell is AIR or replaceable. Bucket becomes empty.
# Returns true if either of the above fired.
#
# The raycast (`hit`) may be null or point past water because water has
# no collision shape — the physics ray passes straight through a water
# column and lands on the seabed. For buckets we do a separate fluid-
# aware scan: step along the look direction in ~1-block increments out
# to REACH and stop at the first fluid-source cell encountered.
# gdlint: disable=max-returns
# gdlint: disable=unused-argument
func _try_bucket(hit: Dictionary, hit_id: int) -> bool:
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	var stack: ItemStack = inv.selected()
	if stack.is_empty():
		return false
	var item_id: int = stack.item_id
	# Empty bucket — scan along look ray for the nearest fluid source.
	if item_id == Items.BUCKET_EMPTY:
		var source_hit: Dictionary = _scan_fluid_source()
		if source_hit.is_empty():
			return false
		var fluid_id: int = source_hit.block_id
		_chunk_manager.set_world_block(source_hit.pos, Blocks.AIR)
		if Blocks.is_water(fluid_id):
			inv.replace_selected(Items.BUCKET_WATER, 1)
		else:
			inv.replace_selected(Items.BUCKET_LAVA, 1)
		_trigger_player_use_swing()
		return true
	# Filled bucket — place fluid source on the face we clicked (or on
	# the cell the ray points at if the raycast missed entirely).
	if item_id == Items.BUCKET_WATER or item_id == Items.BUCKET_LAVA:
		var place_pos: Vector3i
		if not hit.is_empty():
			place_pos = hit.block_pos + hit.normal_i
		else:
			# No block in range — place at the first non-solid cell along
			# the look ray within REACH. Lets the player drop water into
			# air ahead of them, not just against a wall.
			var empty_cell: Dictionary = _scan_placeable_cell()
			if empty_cell.is_empty():
				return false
			place_pos = empty_cell.pos
		var dest_id: int = _chunk_manager.get_world_block(place_pos)
		# Water bucket on FIRE — vanilla ag.java:74-79 short-circuits the
		# place: clicking water-bucket onto a fire cell extinguishes it
		# with the fizz SFX + smoke puff instead of writing water. Also
		# extinguish when the hit-cell ITSELF is fire (player clicked
		# directly on the flame quad). Consumes the bucket either way.
		if item_id == Items.BUCKET_WATER:
			var fire_cell: Vector3i = place_pos
			if dest_id != Blocks.FIRE and not hit.is_empty():
				var clicked_id: int = _chunk_manager.get_world_block(hit.block_pos)
				if clicked_id == Blocks.FIRE:
					fire_cell = hit.block_pos
					dest_id = Blocks.FIRE
			if dest_id == Blocks.FIRE:
				_chunk_manager.set_world_block(fire_cell, Blocks.AIR)
				SFX.play_fizz(false)
				inv.replace_selected(Items.BUCKET_EMPTY, 1)
				_trigger_player_use_swing()
				return true
		if not Blocks.is_replaceable(dest_id) and dest_id != Blocks.AIR:
			return false
		var source_id: int = (
			Blocks.WATER_STILL if item_id == Items.BUCKET_WATER else Blocks.LAVA_STILL
		)
		# Write as STILL with meta=0 — _schedule_fluid_tick in ChunkManager
		# will demote to FLOWING so the spread algorithm picks it up.
		_chunk_manager.set_world_block_with_meta(place_pos, source_id, 0)
		inv.replace_selected(Items.BUCKET_EMPTY, 1)
		_trigger_player_use_swing()
		return true
	return false


# Kicks the one-shot swing animation on the player model. Called after a
# successful bucket fill/place — mirrors vanilla's item-use swing. Silent
# no-op if the player node doesn't expose the hook (e.g. tests).
func _trigger_player_use_swing() -> void:
	var player: Node = get_parent()
	if player != null and player.has_method("trigger_use_swing"):
		player.call("trigger_use_swing")


# Walk the look ray in small steps looking for a fluid source cell
# (water_still or lava_still with meta=0, OR water_flowing/lava_flowing
# source — vanilla only picks up sources per ItemBucket.a, but source
# is always meta=0 regardless of the id). Returns {pos, block_id} or
# empty dict. Fluid cells have no physics collider so the ordinary
# raycast passes through them.
func _scan_fluid_source() -> Dictionary:
	var origin: Vector3 = _camera.global_position
	var direction: Vector3 = -_camera.global_transform.basis.z
	var step: float = 0.25
	var max_steps: int = int(REACH / step)
	for i in range(max_steps):
		var t: float = step * float(i + 1)
		var world_p: Vector3 = origin + direction * t
		var cell := Vector3i(int(floor(world_p.x)), int(floor(world_p.y)), int(floor(world_p.z)))
		var id: int = _chunk_manager.get_world_block(cell)
		if not (Blocks.is_water(id) or Blocks.is_lava(id)):
			continue
		var meta: int = _chunk_manager.get_world_block_meta(cell)
		# Alpha only fills buckets from sources; flowing cells are skipped.
		if meta == 0:
			return {"pos": cell, "block_id": id}
	return {}


# Walk the look ray and return the first AIR/replaceable cell — used
# when the raycast misses solid terrain (player pointing at open sky).
func _scan_placeable_cell() -> Dictionary:
	var origin: Vector3 = _camera.global_position
	var direction: Vector3 = -_camera.global_transform.basis.z
	var step: float = 0.25
	var max_steps: int = int(REACH / step)
	for i in range(max_steps):
		var t: float = step * float(i + 1)
		var world_p: Vector3 = origin + direction * t
		var cell := Vector3i(int(floor(world_p.x)), int(floor(world_p.y)), int(floor(world_p.z)))
		var id: int = _chunk_manager.get_world_block(cell)
		if id == Blocks.AIR or Blocks.is_replaceable(id):
			return {"pos": cell}
	return {}


func _open_crafting_table() -> void:
	var table: Control = (
		get_tree().root.get_node_or_null("Main/Player/Crosshair/CraftingTableScreen") as Control
	)
	if table != null and table.has_method("toggle"):
		table.toggle()


# Right-click on a furnace block opens its smelting screen, bound to that
# specific block position so input/fuel/output route to the correct
# tile-entity state.
func _open_furnace(pos: Vector3i) -> void:
	var screen: Node = get_tree().root.get_node_or_null("Main/Player/Crosshair/FurnaceScreen")
	if screen != null and screen.has_method("open_at"):
		screen.open_at(pos)


# Right-click on a chest opens its 27-slot screen and tweens the lid up.
# The screen close-callback closes the lid again so the animation tracks
# the UI state symmetrically. ChestNode lookup goes through ChunkManager
# since chests are children of their owning chunk_node.
func _open_chest(pos: Vector3i) -> void:
	var screen: Node = get_tree().root.get_node_or_null("Main/Player/Crosshair/ChestScreen")
	if screen == null or not screen.has_method("open_for"):
		return
	var node: ChestNode = _chunk_manager.find_chest_node_at(pos) if _chunk_manager else null
	if node != null:
		node.set_open(true)
	# Vanilla TileEntityChest plays `random.chestopen` here (c.java).
	SFX.play_chest_open()
	screen.open_for(
		pos,
		func() -> void:
			if node != null:
				node.set_open(false)
			SFX.play_chest_close()
	)


# Vanilla gv.java:82-103 — toggle door open/close. Only called for wooden
# doors; iron doors need redstone (not implemented) and fall through to
# normal block placement instead.
func _toggle_door(pos: Vector3i, block_id: int) -> void:
	var meta: int = _chunk_manager.get_world_block_meta(pos)
	# If we clicked the upper half, delegate to the lower half.
	if (meta & 8) != 0:
		var lower := pos + Vector3i(0, -1, 0)
		if _chunk_manager.get_world_block(lower) == block_id:
			_toggle_door(lower, block_id)
		return
	# Toggle bit 2 (open/close) on both halves.
	var new_lower: int = meta ^ 4
	_chunk_manager.set_world_block_with_meta(pos, block_id, new_lower)
	var upper := pos + Vector3i(0, 1, 0)
	if _chunk_manager.get_world_block(upper) == block_id:
		# Vanilla gv.java:94 — upper half gets (n5 ^ 4) + 8.
		_chunk_manager.set_world_block_with_meta(upper, block_id, new_lower + 8)
	SFX.play_door_toggle()


# Returns true if a block was actually placed (i.e., consumed an item).
# gdlint: disable=max-returns
func _place_block_from_held(hit: Dictionary) -> bool:
	var inv: Inventory = _player_inventory()
	if inv == null:
		return false
	var stack: ItemStack = inv.selected()
	if stack.is_empty():
		return false
	# Only block IDs are placeable. Tools, sticks, coal etc. are non-block
	# items (Items.* IDs >= 100) and right-clicking with one shouldn't drop
	# a textureless mystery block into the world.
	# Door items are non-block (id >= 100) but still placeable — they spawn
	# a two-block-tall door block. Route through a dedicated handler.
	if stack.item_id == Items.WOODEN_DOOR or stack.item_id == Items.IRON_DOOR:
		return _try_place_door(hit, stack)
	# Sugar cane item → SUGAR_CANE block placement. Item and block IDs
	# differ but the placement check uses block id; route via dedicated
	# handler that performs the support check + block write.
	if stack.item_id == Items.SUGAR_CANE:
		return _try_place_sugar_cane(hit, stack)
	# Sign item (vanilla dx.as = nv(67)) — clicked-top-face spawns
	# SIGN_STANDING with yaw meta from player rotation; clicked-side-
	# face spawns SIGN_WALL with directional meta. Both create an
	# empty 4-line text entry in SignStorage.
	if stack.item_id == Items.SIGN:
		return _try_place_sign(hit, stack)
	# Wheat seeds → CROPS at stage 0. Vanilla la.java (ItemSeeds)
	# checks the targeted cell is FARMLAND + the cell above is AIR,
	# then places nq.az (BlockCrops) at meta=0 above the farmland.
	if stack.item_id == Items.WHEAT_SEEDS:
		return _try_place_wheat_seeds(hit)
	# Stone slab combine — vanilla qj.java::e(). Placing a HALF_SLAB
	# onto a cell that already holds a HALF_SLAB (from the top face)
	# upgrades the cell to DOUBLE_SLAB and consumes the held slab
	# without spawning a new cell above. Returns true if the combine
	# fired; falls through to normal placement otherwise (e.g. side-
	# face click puts a new slab in the neighbor cell as usual).
	if stack.item_id == Blocks.HALF_SLAB:
		if _try_slab_combine(hit, stack):
			return true
	if stack.item_id >= 100 or Items.is_tool_item(stack.item_id):
		return false
	# Vanilla Block.isReplaceable: when the targeted cell holds a plant /
	# water / etc., the new block goes INTO that cell (overwriting the
	# replaceable). Solid cubes push placement into the neighbor cell as
	# usual. Cross-quad raycast normals aren't axis-aligned anyway, so
	# routing through the neighbor would produce diagonal placements that
	# look broken.
	var hit_id: int = _chunk_manager.get_world_block(hit.block_pos)
	var place: Vector3i
	if Blocks.is_replaceable(hit_id):
		place = hit.block_pos
	else:
		place = hit.block_pos + hit.normal_i
		# Neighbor cell must be empty OR replaceable (water, plants). The
		# earlier hardcoded `!= AIR` check rejected placement into water
		# even when the water was right next to the face the player
		# clicked — breaking the common "dam up a stream" workflow.
		var neighbor_id: int = _chunk_manager.get_world_block(place)
		if neighbor_id != Blocks.AIR and not Blocks.is_replaceable(neighbor_id):
			return false
	# Per-block placement validity (BlockPlant.canPlace → grass/dirt/
	# farmland support) AND player-occupancy guard. Blocks the player
	# from planting saplings on stone / sand / mid-air (vanilla rejects)
	# and from placing a block inside their own feet/head (would clip).
	var support_id: int = _chunk_manager.get_world_block(place + Vector3i(0, -1, 0))
	var player: Node3D = get_parent()
	var pp := player.global_position
	var player_block := Vector3i(int(floor(pp.x)), int(floor(pp.y)), int(floor(pp.z)))
	var blocks_player: bool = place == player_block or place == player_block + Vector3i(0, 1, 0)
	if blocks_player or not Blocks.can_place_at(stack.item_id, support_id):
		return false
	# Vanilla BlockTorch (ob.java:30-64) requires AT LEAST ONE solid neighbor
	# among (-X, +X, -Z, +Z, -Y) and stores orientation in metadata 1..5
	# encoding which neighbor is the support. Without this, torches just
	# float in mid-air when the player aims at a wall.
	if stack.item_id == Blocks.TORCH:
		var torch_meta: int = _torch_meta_from_face(hit.normal_i, place)
		if torch_meta == 0:
			return false  # no valid support neighbor → reject placement
		# Replacing a non-AIR cell (water, plant) — drop the displaced block
		# before clobbering, same path the cube branch takes below.
		var displaced_for_torch: int = _chunk_manager.get_world_block(place)
		if displaced_for_torch != Blocks.AIR:
			var dd: int = Blocks.drops(displaced_for_torch)
			if dd != Blocks.AIR:
				_spawn_dropped_item(place, dd)
		_chunk_manager.set_world_block_with_meta(place, Blocks.TORCH, torch_meta)
		SFX.play_place(Blocks.TORCH)
		inv.consume_one_selected()
		return true
	# Vanilla BlockLadder (ca.java) — wall-mount only (no floor/ceiling).
	# Metadata 2..5 encodes which wall the ladder sits against. Requires an
	# opaque block on the support side; rejects placement otherwise.
	if stack.item_id == Blocks.LADDER:
		var ladder_meta: int = _ladder_meta_from_face(hit.normal_i, place)
		if ladder_meta == 0:
			return false
		var displaced_for_ladder: int = _chunk_manager.get_world_block(place)
		if displaced_for_ladder != Blocks.AIR:
			var dd: int = Blocks.drops(displaced_for_ladder)
			if dd != Blocks.AIR:
				_spawn_dropped_item(place, dd)
		_chunk_manager.set_world_block_with_meta(place, Blocks.LADDER, ladder_meta)
		SFX.play_place(Blocks.LADDER)
		inv.consume_one_selected()
		return true
	# Replacing a non-AIR cell — vanilla Block.dropBlockAsItem fires before
	# the new block clobbers the old one, so e.g. placing stone over a
	# sapling drops the sapling as a pickup. Skipped if the cell was AIR.
	var displaced_id: int = _chunk_manager.get_world_block(place)
	if displaced_id != Blocks.AIR:
		var displaced_drop: int = Blocks.drops(displaced_id)
		if displaced_drop != Blocks.AIR:
			_spawn_dropped_item(place, displaced_drop)
	# Vanilla c.java:c() orients the chest based on the player's yaw at
	# placement time (so the latched front faces the player). meta 0..3
	# encodes -Z / -X / +Z / +X (matches ChestNode.set_facing).
	if stack.item_id == Blocks.CHEST:
		var meta: int = _chest_meta_from_yaw()
		_chunk_manager.set_world_block_with_meta(place, Blocks.CHEST, meta)
		SFX.play_place(Blocks.CHEST)
		inv.consume_one_selected()
		return true
	# Stairs orient with the ascending side facing the player's look
	# direction — mb.java:170-183 uses `(yaw*4/360+0.5)&3` then remaps.
	if stack.item_id == Blocks.WOOD_STAIRS or stack.item_id == Blocks.COBBLESTONE_STAIRS:
		var meta: int = _stair_meta_from_yaw()
		_chunk_manager.set_world_block_with_meta(place, stack.item_id, meta)
		SFX.play_place(stack.item_id)
		inv.consume_one_selected()
		return true
	# Pumpkin / Jack O'Lantern — vanilla BlockPumpkin orients the carved
	# face toward the player (BlockPumpkin.b sets meta from EntityLiving
	# yaw). Same convention as chest, so the same yaw quadrant helper
	# applies. meta 0..3 maps -Z / -X / +Z / +X to which side carries
	# the face — see Blocks.directional_face_texture.
	if stack.item_id == Blocks.PUMPKIN or stack.item_id == Blocks.JACK_O_LANTERN:
		var pumpkin_meta: int = _chest_meta_from_yaw()
		_chunk_manager.set_world_block_with_meta(place, stack.item_id, pumpkin_meta)
		SFX.play_place(stack.item_id)
		inv.consume_one_selected()
		return true
	_chunk_manager.set_world_block(place, stack.item_id)
	SFX.play_place(stack.item_id)
	inv.consume_one_selected()
	return true


# Pick the chest facing meta (0..3) from the player's current yaw, so
# the chest's "front" (where the latch sits) ends up pointing at the
# player. Mirrors vanilla c.java::c() in BlockChest, which uses
# `MathHelper.floor_double(EntityLiving.aw * 4 / 360 + 0.5) & 3` then
# maps direction id → block meta. We collapse those steps into one
# yaw-quadrant lookup below.
func _chest_meta_from_yaw() -> int:
	var player: Node3D = get_parent()
	# Yaw in radians, atan2(-x, -z) so 0 = facing -Z (Godot's default
	# forward). Map the four quadrants to the 4 cardinal directions and
	# pick the chest meta that orients the front toward the player.
	var yaw: float = player.global_transform.basis.get_euler().y
	# Quantize to nearest cardinal: 0 = -Z, 1 = -X, 2 = +Z, 3 = +X.
	# +0.5 rotation/8 offset puts the threshold midway between cardinals.
	var dir: int = int(round(yaw / (PI / 2.0))) & 3
	# The chest's front faces the OPPOSITE of the player's gaze direction
	# (so the player sees the latched face). dir of 0 (player facing -Z)
	# means the chest front faces +Z, which is meta 2 in our scheme.
	match dir:
		0:
			return 2  # player faces -Z → chest front +Z
		1:
			return 3  # player faces -X → chest front +X
		2:
			return 0  # player faces +Z → chest front -Z
		3:
			return 1  # player faces +X → chest front -X
	return 0


# Stair orientation from player yaw. Vanilla mb.java:171 quantizes
# `(yaw * 4/360 + 0.5) & 3` then remaps to meta. Stairs ascend in the
# direction the player faces. Our Godot dir convention:
#   dir 0 = facing -Z, 1 = -X, 2 = +Z, 3 = +X.
# Vanilla meta geometry (from mb.java:43-66):
#   meta 0: ascending +X, meta 1: ascending -X,
#   meta 2: ascending +Z, meta 3: ascending -Z.
func _stair_meta_from_yaw() -> int:
	var player: Node3D = get_parent()
	var yaw: float = player.global_transform.basis.get_euler().y
	var dir: int = int(round(yaw / (PI / 2.0))) & 3
	match dir:
		0:
			return 3  # facing -Z → ascending -Z
		1:
			return 1  # facing -X → ascending -X
		2:
			return 2  # facing +Z → ascending +Z
		3:
			return 0  # facing +X → ascending +X
	return 0


# Vanilla eu.java door placement. RMB on a top face (+Y normal) of a solid
# block: place door at (block_pos + Vector3i(0,1,0)), oriented by yaw, with
# hinge determined from neighboring solidity. Must have air at both the
# placement cell AND the cell above. Consumes one door item on success.
# gdlint: disable=max-returns
func _try_place_door(hit: Dictionary, stack: ItemStack) -> bool:
	if hit.is_empty():
		return false
	# Vanilla eu.java:10 — doors only place on the top face.
	if hit.normal_i.y != 1:
		return false
	var place: Vector3i = hit.block_pos + hit.normal_i
	var block_id: int = (
		Blocks.WOODEN_DOOR if stack.item_id == Items.WOODEN_DOOR else Blocks.IRON_DOOR
	)
	# Vanilla gv.java:184-188 — solid ground + two air cells above.
	if not _torch_neighbor_solid(hit.block_pos):
		return false
	if place.y >= 127:
		return false
	var above: Vector3i = place + Vector3i(0, 1, 0)
	if _chunk_manager.get_world_block(place) != Blocks.AIR:
		return false
	if _chunk_manager.get_world_block(above) != Blocks.AIR:
		return false
	# Player occupancy check.
	var player: Node3D = get_parent()
	var pp := player.global_position
	var player_block := Vector3i(int(floor(pp.x)), int(floor(pp.y)), int(floor(pp.z)))
	if (
		place == player_block
		or place == player_block + Vector3i(0, 1, 0)
		or above == player_block
		or above == player_block + Vector3i(0, 1, 0)
	):
		return false
	# Orientation from yaw — eu.java:16.
	var yaw: float = player.global_transform.basis.get_euler().y
	var dir: int = int(round(yaw / (PI / 2.0))) & 3
	# Map Godot yaw dirs to vanilla eu.java direction convention:
	#   Godot dir 0 = facing -Z → vanilla dir 3
	#   Godot dir 1 = facing -X → vanilla dir 0
	#   Godot dir 2 = facing +Z → vanilla dir 1
	#   Godot dir 3 = facing +X → vanilla dir 2
	var n6: int
	match dir:
		0:
			n6 = 3
		1:
			n6 = 0
		2:
			n6 = 1
		_:
			n6 = 2
	# Hinge side — eu.java:22-38. Check solidity of blocks to the left
	# and right (from the player's perspective) to decide if the hinge
	# flips. When the left side has more solid neighbors (or an existing
	# door), the hinge shifts to the right.
	var n7: int = 0  # perpendicular offset X
	var n8: int = 0  # perpendicular offset Z
	if n6 == 0:
		n8 = 1
	elif n6 == 1:
		n7 = -1
	elif n6 == 2:
		n8 = -1
	elif n6 == 3:
		n7 = 1
	var left_solid: int = (
		(_solid_at(place + Vector3i(-n7, 0, -n8)) as int)
		+ (_solid_at(place + Vector3i(-n7, 1, -n8)) as int)
	)
	var right_solid: int = (
		(_solid_at(place + Vector3i(n7, 0, n8)) as int)
		+ (_solid_at(place + Vector3i(n7, 1, n8)) as int)
	)
	var left_door: bool = (
		_chunk_manager.get_world_block(place + Vector3i(-n7, 0, -n8)) == block_id
		or _chunk_manager.get_world_block(place + Vector3i(-n7, 1, -n8)) == block_id
	)
	var right_door: bool = (
		_chunk_manager.get_world_block(place + Vector3i(n7, 0, n8)) == block_id
		or _chunk_manager.get_world_block(place + Vector3i(n7, 1, n8)) == block_id
	)
	var flip_hinge: bool = false
	if left_door and not right_door:
		flip_hinge = true
	elif right_solid > left_solid:
		flip_hinge = true
	if flip_hinge:
		n6 = (n6 - 1) & 3
		n6 += 4
	_chunk_manager.set_world_block_with_meta(place, block_id, n6)
	_chunk_manager.set_world_block_with_meta(above, block_id, n6 + 8)
	SFX.play_place(block_id)
	var inv: Inventory = _player_inventory()
	if inv != null:
		inv.consume_one_selected()
	return true


# Sugar cane placement: requires a valid support (grass/dirt/sand or
# another sugar cane below) AND water adjacent at the base. Vanilla
# BlockReed.canPlace checks both. Place the SUGAR_CANE block; consume
# one item.
func _try_place_sugar_cane(hit: Dictionary, _stack: ItemStack) -> bool:
	if hit.is_empty():
		return false
	# Determine target cell — replace if hit cell is replaceable, else
	# place into the neighbor in the hit's normal direction.
	var hit_id: int = _chunk_manager.get_world_block(hit.block_pos)
	var place: Vector3i
	if Blocks.is_replaceable(hit_id):
		place = hit.block_pos
	else:
		place = hit.block_pos + hit.normal_i
	# Target cell must be empty.
	var target_id: int = _chunk_manager.get_world_block(place)
	if target_id != Blocks.AIR and not Blocks.is_replaceable(target_id):
		return false
	# Support check: grass/dirt/sand below, OR another sugar cane.
	var support_id: int = _chunk_manager.get_world_block(place + Vector3i(0, -1, 0))
	if not Blocks.can_place_at(Blocks.SUGAR_CANE, support_id):
		return false
	# Water-adjacency check (vanilla BlockReed: at least one cardinal
	# neighbor at the BASE Y must be water). Skip if support is another
	# sugar cane (stacking on existing).
	if support_id != Blocks.SUGAR_CANE:
		var has_water: bool = false
		for off: Vector3i in [
			Vector3i(1, -1, 0), Vector3i(-1, -1, 0), Vector3i(0, -1, 1), Vector3i(0, -1, -1)
		]:
			var n_id: int = _chunk_manager.get_world_block(place + off)
			if n_id == Blocks.WATER_STILL or n_id == Blocks.WATER_FLOWING:
				has_water = true
				break
		if not has_water:
			return false
	# Player occupancy guard.
	var player: Node3D = get_parent()
	var pp := player.global_position
	var player_block := Vector3i(int(floor(pp.x)), int(floor(pp.y)), int(floor(pp.z)))
	if place == player_block or place == player_block + Vector3i(0, 1, 0):
		return false
	_chunk_manager.set_world_block(place, Blocks.SUGAR_CANE)
	SFX.play_place(Blocks.SUGAR_CANE)
	var inv: Inventory = _player_inventory()
	if inv != null:
		inv.consume_one_selected()
	return true


# Fishing rod — vanilla bj.java::a. Branches on player.fishing_bobber:
#   * nil  → cast: spawn FishingBobber at camera pos with vel toward
#     look direction. Play "random.bow" sfx (vanilla pi.bj does the
#     same — bow sfx is the cast whoosh in Alpha).
#   * set  → reel: if bobber.reel() returns true (bite active), spawn
#     a raw_fish dropped item at the bobber position with velocity
#     toward the player + small Y bias. Damage the rod by 1.
#
# Returns true so the cooldown advances; player.fishing_bobber holds
# the single-bobber state.
func _try_fishing_rod() -> bool:
	var player_node: Node3D = _player_node() as Node3D
	if player_node == null:
		return false
	var existing: Node = player_node.get("fishing_bobber") as Node
	if existing != null and is_instance_valid(existing):
		var caught: bool = existing.reel()
		var bobber_pos: Vector3 = existing.get_bobber_position()
		player_node.set("fishing_bobber", null)
		if caught:
			# Spawn raw_fish entity at bobber, vanilla velocity toward
			# player + slight upward bias.
			var to_player: Vector3 = player_node.global_position + Vector3(0, 1.6, 0) - bobber_pos
			var dist: float = to_player.length()
			var vel: Vector3 = to_player * 0.5
			vel.y += sqrt(maxf(dist, 0.0)) * 0.5
			_spawn_dropped_item_with_velocity(bobber_pos, Items.RAW_FISH, vel)
		# Always damage rod on reel (vanilla returns n2 from k(); we
		# simplify to 1).
		var inv: Inventory = _player_inventory()
		if inv != null and inv.damage_selected_tool():
			SFX.play_tool_break()
		_trigger_player_use_swing()
		return true
	# Cast — spawn bobber from camera position along look direction.
	var camera: Camera3D = player_node.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return false
	var cam_pos: Vector3 = camera.global_position
	var look_dir: Vector3 = -camera.global_transform.basis.z
	var bobber_script: GDScript = load("res://scripts/world/fishing_bobber.gd")
	var bobber: Node3D = bobber_script.new()
	# Parent to the chunk manager so the bobber outlives the player
	# transform but unloads cleanly with the scene.
	_chunk_manager.add_child(bobber)
	bobber.setup(player_node, _chunk_manager, cam_pos, look_dir)
	player_node.set("fishing_bobber", bobber)
	# Vanilla bj.java plays "random.bow" — we don't have a bow sound
	# yet so reuse splash with a low-amplitude velocity for the cast
	# whoosh; not perfect but better than silence.
	SFX.play_splash(Vector3(0, 0.4, 0))
	_trigger_player_use_swing()
	return true


# Spawn a dropped item at `pos` with an initial velocity (used by
# fishing-rod reel to fling a fish toward the player). Mirrors the
# regular _spawn_dropped_item but takes a custom velocity instead of
# the default break-pop randomization.
func _spawn_dropped_item_with_velocity(pos: Vector3, item_id: int, vel: Vector3) -> void:
	var item_script: GDScript = load("res://scripts/world/dropped_item.gd")
	var item: Node3D = item_script.new()
	_chunk_manager.add_child(item)
	item.setup(item_id, pos, _player_node() as Node3D, _chunk_manager)
	item.set("_velocity", vel)


# Variable-count drops for CROPS.
#   Mature (meta=7): 1 wheat + 0..3 seeds. Vanilla BlockCrops loops
#     0..3 with a 1/(15-i) chance per seed slot; we use the simpler
#     1/4-per-slot approximation that gives the same ~3 average drop.
#   Immature: 1 seed back (vanilla: return your seed when the plant
#     isn't fully grown).
func _farm_drops(broken_id: int, pos: Vector3i) -> Array:
	var drops: Array = []
	if broken_id == Blocks.CROPS:
		var meta: int = _chunk_manager.get_world_block_meta(pos)
		if meta >= 7:
			drops.append(Items.WHEAT)
			for _i in range(3):
				if randi() % 4 == 0:
					drops.append(Items.WHEAT_SEEDS)
		else:
			drops.append(Items.WHEAT_SEEDS)
	return drops


# Wheat seeds placement — vanilla la.java (ItemSeeds.a) requires the
# CLICKED face to be the top of a FARMLAND cell, and the cell above
# that to be empty. Places BlockCrops (nq.az) at meta 0 (stage 0),
# consumes one seed. Players who haven't tilled their dirt first will
# see no effect — that's Alpha-faithful.
func _try_place_wheat_seeds(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	# Vanilla requires the top face of farmland. normal_i.y == 1 means
	# the player clicked the top face — that's the only valid case.
	if hit.normal_i.y != 1:
		return false
	var support_id: int = _chunk_manager.get_world_block(hit.block_pos)
	if support_id != Blocks.FARMLAND:
		return false
	var place: Vector3i = hit.block_pos + Vector3i(0, 1, 0)
	var target_id: int = _chunk_manager.get_world_block(place)
	if target_id != Blocks.AIR and not Blocks.is_replaceable(target_id):
		return false
	_chunk_manager.set_world_block(place, Blocks.CROPS, 0)
	# Schedule growth ticks via TickScheduler. Vanilla picks an interval
	# uniformly from ~9-30 seconds per stage; we use a mid-range default
	# of 200 ticks (~10 seconds at 20 TPS) — see _on_crop_tick.
	TickScheduler.schedule(place, Blocks.CROPS, 200)
	SFX.play_place(Blocks.FARMLAND)  # soft "till" sound; no dedicated seed-plant sfx in Alpha
	var inv: Inventory = _player_inventory()
	if inv != null:
		inv.consume_one_selected()
	_trigger_player_use_swing()
	return true


# Sign placement — vanilla ItemSign (nv.java) places SIGN_STANDING on
# top of a support cube and SIGN_WALL on a vertical face. Both get
# meta encoding orientation (16-rotation yaw for standing, 4-direction
# for wall) and an empty 4-line text entry in SignStorage.
func _try_place_sign(hit: Dictionary, _stack: ItemStack) -> bool:
	if hit.is_empty():
		return false
	var support_id: int = _chunk_manager.get_world_block(hit.block_pos)
	if not Blocks.is_opaque(support_id):
		return false
	var place: Vector3i = hit.block_pos + hit.normal_i
	var dest_id: int = _chunk_manager.get_world_block(place)
	if dest_id != Blocks.AIR and not Blocks.is_replaceable(dest_id):
		return false
	# Player-occupancy guard.
	var player: Node3D = get_parent() as Node3D
	if player != null:
		var pp: Vector3 = player.global_position
		var pb := Vector3i(int(floor(pp.x)), int(floor(pp.y)), int(floor(pp.z)))
		if place == pb or place == pb + Vector3i(0, 1, 0):
			return false
	var block_id: int
	var meta: int
	if hit.normal_i.y == 1:
		block_id = Blocks.SIGN_STANDING
		var yaw_deg: float = rad_to_deg(_player_yaw()) + 180.0
		meta = int(round(yaw_deg * 16.0 / 360.0)) & 0x0F
	else:
		block_id = Blocks.SIGN_WALL
		meta = _wall_sign_meta_from_normal(hit.normal_i)
	_chunk_manager.set_world_block_with_meta(place, block_id, meta)
	SignStorage.get_or_create(place)
	SFX.play_place(Blocks.SIGN_STANDING)
	var inv: Inventory = _player_inventory()
	if inv != null:
		inv.consume_one_selected()
	_trigger_player_use_swing()
	return true


# Returns the player's yaw in radians. Used by sign placement.
func _player_yaw() -> float:
	var player: Node3D = get_parent() as Node3D
	if player == null:
		return 0.0
	return player.rotation.y


# Maps a wall-face hit normal to our 4-direction meta encoding:
# 0=-Z, 1=+Z, 2=-X, 3=+X. Same convention as _chest_meta_from_yaw.
func _wall_sign_meta_from_normal(normal: Vector3i) -> int:
	if normal.z < 0:
		return 0
	if normal.z > 0:
		return 1
	if normal.x < 0:
		return 2
	return 3


# Stone slab combine — vanilla qj.java::e(). Returns true if the
# clicked cell was a HALF_SLAB AND the player clicked its top face,
# converting that cell to DOUBLE_SLAB. Side / bottom clicks return
# false so the regular block-placement path puts the new slab in the
# neighbor cell.
func _try_slab_combine(hit: Dictionary, _stack: ItemStack) -> bool:
	if hit.is_empty():
		return false
	# Must be clicking the top face for the combine to fire.
	if hit.normal_i.y != 1:
		return false
	var existing_id: int = _chunk_manager.get_world_block(hit.block_pos)
	if existing_id != Blocks.HALF_SLAB:
		return false
	_chunk_manager.set_world_block(hit.block_pos, Blocks.DOUBLE_SLAB)
	SFX.play_place(Blocks.HALF_SLAB)
	var inv: Inventory = _player_inventory()
	if inv != null:
		inv.consume_one_selected()
	_trigger_player_use_swing()
	return true


func _solid_at(pos: Vector3i) -> bool:
	if _chunk_manager == null:
		return false
	var id: int = _chunk_manager.get_world_block(pos)
	return id != Blocks.AIR and Blocks.is_opaque(id)


# Vanilla ob.java:46-64 onPlace — encodes which neighbor supports the torch:
#   meta 1 = -X neighbor, 2 = +X, 3 = -Z, 4 = +Z, 5 = -Y (floor)
# Vanilla also has a fallback (ob.java:71-83) that scans neighbors when meta
# is invalid; we replicate that as the final pass so a torch placed against
# a non-solid clicked face still finds any other valid support before giving
# up and rejecting placement.
# gdlint: disable=max-returns
func _torch_meta_from_face(normal_i: Vector3i, place: Vector3i) -> int:
	# First try the clicked face — vanilla prefers the face the player aimed at.
	# normal_i = +Y (clicked top): support is at -Y of placement cell → meta 5.
	# normal_i = ±X / ±Z: support is at the OPPOSITE side of placement cell.
	if normal_i.y == 1 and _torch_neighbor_solid(place + Vector3i(0, -1, 0)):
		return 5
	if normal_i.x == 1 and _torch_neighbor_solid(place + Vector3i(-1, 0, 0)):
		return 1
	if normal_i.x == -1 and _torch_neighbor_solid(place + Vector3i(1, 0, 0)):
		return 2
	if normal_i.z == 1 and _torch_neighbor_solid(place + Vector3i(0, 0, -1)):
		return 3
	if normal_i.z == -1 and _torch_neighbor_solid(place + Vector3i(0, 0, 1)):
		return 4
	# Vanilla ceiling face (normal_i.y == -1) is unsupported in Alpha — torches
	# can't hang upside-down. Fall through to the "any neighbor solid" rescan.
	if _torch_neighbor_solid(place + Vector3i(-1, 0, 0)):
		return 1
	if _torch_neighbor_solid(place + Vector3i(1, 0, 0)):
		return 2
	if _torch_neighbor_solid(place + Vector3i(0, 0, -1)):
		return 3
	if _torch_neighbor_solid(place + Vector3i(0, 0, 1)):
		return 4
	if _torch_neighbor_solid(place + Vector3i(0, -1, 0)):
		return 5
	return 0  # no valid support → reject


# Vanilla `cy.g(x,y,z)` is "is this a solid full cube" — used for torch
# canPlaceBlockAt + canPlaceTorchOn. We approximate via Blocks.is_opaque,
# which is true for full solid cubes and false for plants / fluids / fire /
# torches themselves. Matches the Alpha vanilla check closely enough that
# torches reject placement on non-solid neighbors as expected.
func _torch_neighbor_solid(pos: Vector3i) -> bool:
	if _chunk_manager == null:
		return false
	var nb: int = _chunk_manager.get_world_block(pos)
	return nb != Blocks.AIR and Blocks.is_opaque(nb)


# Vanilla ca.java — ladder placement meta from the clicked face normal.
# Ladders only attach to vertical walls (no floor/ceiling). Meta 2..5
# encodes the support direction:
#   normal (0,0,-1) → support at +Z → meta 2
#   normal (0,0,+1) → support at -Z → meta 3
#   normal (-1,0,0) → support at +X → meta 4
#   normal (+1,0,0) → support at -X → meta 5
# Returns 0 if no valid support exists (rejects placement).
func _ladder_meta_from_face(normal_i: Vector3i, place: Vector3i) -> int:
	if normal_i.y != 0:
		# Clicked top or bottom face — scan for any solid horizontal neighbor.
		for pair: Array in [
			[Vector3i(0, 0, 1), 2],
			[Vector3i(0, 0, -1), 3],
			[Vector3i(1, 0, 0), 4],
			[Vector3i(-1, 0, 0), 5]
		]:
			if _torch_neighbor_solid(place + pair[0]):
				return pair[1] as int
		return 0
	# Clicked a vertical face — support is opposite the normal.
	if normal_i.z == -1 and _torch_neighbor_solid(place + Vector3i(0, 0, 1)):
		return 2
	if normal_i.z == 1 and _torch_neighbor_solid(place + Vector3i(0, 0, -1)):
		return 3
	if normal_i.x == -1 and _torch_neighbor_solid(place + Vector3i(1, 0, 0)):
		return 4
	if normal_i.x == 1 and _torch_neighbor_solid(place + Vector3i(-1, 0, 0)):
		return 5
	# Clicked face doesn't have a solid support — try any neighbor.
	for pair: Array in [
		[Vector3i(0, 0, 1), 2],
		[Vector3i(0, 0, -1), 3],
		[Vector3i(1, 0, 0), 4],
		[Vector3i(-1, 0, 0), 5]
	]:
		if _torch_neighbor_solid(place + pair[0]):
			return pair[1] as int
	return 0


func _set_player_mining(active: bool) -> void:
	var player: Node = get_parent()
	if "is_mining" in player:
		player.set("is_mining", active)


func _player_inventory() -> Inventory:
	var player: Node = get_parent()
	if player.has_method("get") and "inventory" in player:
		return player.get("inventory") as Inventory
	return null


func _raycast() -> Dictionary:
	var space := _camera.get_world_3d().direct_space_state
	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * REACH)
	# Layer 1 = solid world (cube collision). Layer 2 = non-cube selection-
	# only shapes (sapling cross-quads, future torches/levers/buttons) —
	# the player physics body ignores layer 2 so plants stay passable, but
	# the cursor still needs to target them, so the raycast opts both in.
	query.collision_mask = 0b11
	var player: CollisionObject3D = get_parent() as CollisionObject3D
	if player != null:
		query.exclude = [player.get_rid()]
	var result := space.intersect_ray(query)
	if result.is_empty():
		return {}
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var inside := hit_pos - hit_normal * 0.01
	return {
		"collider": result.collider,
		"block_pos": Vector3i(int(floor(inside.x)), int(floor(inside.y)), int(floor(inside.z))),
		"normal_i":
		Vector3i(int(round(hit_normal.x)), int(round(hit_normal.y)), int(round(hit_normal.z))),
	}


func _build_highlight() -> MeshInstance3D:
	# Vanilla-faithful black wireframe outline. PRIMITIVE_LINES gives 1px
	# lines on most GPUs (basically invisible), so we build each edge as a
	# thin 3D box — controllable thickness, looks correct at any resolution.
	var mi := MeshInstance3D.new()
	mi.mesh = _build_wireframe_cube_mesh(1.002, 0.012)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0, 0, 0, 1.0)
	mat.cull_mode = StandardMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = false
	return mi


# 12-edge wireframe of a cube centered at origin. Each edge is a thin
# rectangular box of `thickness` cross-section, so the wireframe has
# real visible width regardless of GPU line-rasterization quirks.
func _build_wireframe_cube_mesh(size: float, thickness: float) -> ArrayMesh:
	var s: float = size * 0.5
	var t: float = thickness * 0.5
	# Each edge: [center_position, half_extents_along_each_axis]. Edges
	# extend slightly past their endpoints (length = s + t) so adjacent
	# edges meet flush at the cube corners.
	var edges: Array = [
		# Bottom face (y = -s) — 4 horizontal edges
		[Vector3(0, -s, -s), Vector3(s + t, t, t)],
		[Vector3(s, -s, 0), Vector3(t, t, s + t)],
		[Vector3(0, -s, s), Vector3(s + t, t, t)],
		[Vector3(-s, -s, 0), Vector3(t, t, s + t)],
		# Top face (y = +s) — 4 horizontal edges
		[Vector3(0, s, -s), Vector3(s + t, t, t)],
		[Vector3(s, s, 0), Vector3(t, t, s + t)],
		[Vector3(0, s, s), Vector3(s + t, t, t)],
		[Vector3(-s, s, 0), Vector3(t, t, s + t)],
		# 4 vertical pillars connecting the two faces
		[Vector3(-s, 0, -s), Vector3(t, s + t, t)],
		[Vector3(s, 0, -s), Vector3(t, s + t, t)],
		[Vector3(-s, 0, s), Vector3(t, s + t, t)],
		[Vector3(s, 0, s), Vector3(t, s + t, t)],
	]
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var face_quads: Array = [
		[0, 1, 2, 3],  # -Z back
		[4, 7, 6, 5],  # +Z front
		[0, 4, 5, 1],  # -Y bottom
		[3, 2, 6, 7],  # +Y top
		[0, 3, 7, 4],  # -X left
		[1, 5, 6, 2],  # +X right
	]
	var base: int = 0
	for edge: Array in edges:
		var c: Vector3 = edge[0]
		var e: Vector3 = edge[1]
		(
			verts
			. append_array(
				PackedVector3Array(
					[
						c + Vector3(-e.x, -e.y, -e.z),
						c + Vector3(e.x, -e.y, -e.z),
						c + Vector3(e.x, e.y, -e.z),
						c + Vector3(-e.x, e.y, -e.z),
						c + Vector3(-e.x, -e.y, e.z),
						c + Vector3(e.x, -e.y, e.z),
						c + Vector3(e.x, e.y, e.z),
						c + Vector3(-e.x, e.y, e.z),
					]
				)
			)
		)
		for q: Array in face_quads:
			(
				indices
				. append_array(
					PackedInt32Array(
						[
							base + q[0],
							base + q[1],
							base + q[2],
							base + q[0],
							base + q[2],
							base + q[3],
						]
					)
				)
			)
		base += 8
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_crack() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	# BoxMesh's default UVs split a single texture across all 6 faces with a
	# cube-unwrap layout — not what we want. Build a custom cube where each
	# face has full (0,0)-(1,1) UVs so the crack atlas samples cleanly.
	mi.mesh = _build_uv_cube_mesh(1.01)
	var tex: Texture2D = load(CRACK_ATLAS_PATH) as Texture2D
	if tex == null:
		push_error("[Crack] failed to load atlas: " + CRACK_ATLAS_PATH)
	else:
		_crack_stages = max(1, int(round(float(tex.get_height()) / float(tex.get_width()))))
		if Game.debug_mesh:
			print(
				(
					"[Crack] atlas loaded: %dx%d, %d stages"
					% [tex.get_width(), tex.get_height(), _crack_stages]
				)
			)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/crack.gdshader") as Shader
	mat.set_shader_parameter("crack_atlas", tex)
	mat.set_shader_parameter("stage", 0)
	mat.set_shader_parameter("total_stages", _crack_stages)
	mi.material_override = mat
	mi.visible = false
	return mi


# Six-face cube where every face has UV (0,0)..(1,1) — needed so the crack
# shader can sample the full atlas cell per face (BoxMesh defaults split UVs).
func _build_uv_cube_mesh(size: float) -> ArrayMesh:
	var s: float = size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Vertex orderings mirror the chunk mesher exactly (known-working winding
	# for Godot 4 cull_back). For a centered cube of given size: 0→-s, 1→+s.
	var faces: Array = [
		# +Y (top)
		[
			Vector3(-s, s, -s),
			Vector3(-s, s, s),
			Vector3(s, s, s),
			Vector3(s, s, -s),
			Vector3(0, 1, 0)
		],
		# -Y (bottom)
		[
			Vector3(-s, -s, s),
			Vector3(-s, -s, -s),
			Vector3(s, -s, -s),
			Vector3(s, -s, s),
			Vector3(0, -1, 0)
		],
		# +X (east)
		[
			Vector3(s, -s, -s),
			Vector3(s, s, -s),
			Vector3(s, s, s),
			Vector3(s, -s, s),
			Vector3(1, 0, 0)
		],
		# -X (west)
		[
			Vector3(-s, -s, s),
			Vector3(-s, s, s),
			Vector3(-s, s, -s),
			Vector3(-s, -s, -s),
			Vector3(-1, 0, 0)
		],
		# +Z (south)
		[
			Vector3(s, -s, s),
			Vector3(s, s, s),
			Vector3(-s, s, s),
			Vector3(-s, -s, s),
			Vector3(0, 0, 1)
		],
		# -Z (north)
		[
			Vector3(-s, -s, -s),
			Vector3(-s, s, -s),
			Vector3(s, s, -s),
			Vector3(s, -s, -s),
			Vector3(0, 0, -1)
		],
	]
	for face: Array in faces:
		var base: int = verts.size()
		for i: int in range(4):
			verts.append(face[i])
			norms.append(face[4])
		# Match the chunk shader's UV V-flip so face textures aren't upside-down
		uvs.append(Vector2(0, 1))
		uvs.append(Vector2(0, 0))
		uvs.append(Vector2(1, 0))
		uvs.append(Vector2(1, 1))
		# Reversed winding for Godot 4's CW-front + cull_back
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
