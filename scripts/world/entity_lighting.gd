class_name EntityLighting

# Vanilla Alpha entity lighting — entities sample sky + block light at
# their cell each tick and apply the brightness LUT result as a colour
# multiplier on their texture. Without this, entities render at full
# brightness regardless of time of day or cover.
#
# Vanilla refs:
#   oz.java:22-28  — World.brightness LUT (per light level 0..15)
#   cy.java:846-854 — integer skyLightSubtracted

# Entity and terrain consumers share Alpha's brightness floor so an entity
# cannot glow against a level-0 cave wall.
# Mirrors the terrain shader's `ambient_floor` uniform. Entities and the
# blocks under them have to agree on the curve or a mob reads as lit
# differently from the floor it stands on; in the Nether the terrain got
# 0.1 while mobs were stuck on the Overworld's 0.05, so a ghast crossing
# from lava-light into shadow swung twice as far as vanilla's does.
static var _floor: float = 0.05


# Pushed by day_night_driver alongside the shader uniform.
static func set_ambient_floor(value: float) -> void:
	_floor = clampf(value, 0.0, 1.0)


# Vanilla LUT formula. Returns 0.05..1.0 — matches the LUT baked into
# chunk.gdshader so entities visually match the surrounding terrain.
static func brightness_for_level(level: int) -> float:
	var l: float = clampf(float(level), 0.0, 15.0)
	var f3: float = 1.0 - l / 15.0
	return (1.0 - f3) / (f3 * 3.0 + 1.0) * (1.0 - _floor) + _floor


# Sample the effective light at a world cell, accounting for day-night.
# Returns a 0.05..1.0 multiplier suitable for `mat.albedo_color = Color(b,b,b)`.
static func sample_brightness(chunk_manager: Node, world_pos: Vector3i) -> float:
	if chunk_manager == null:
		return 1.0
	var effective: int
	if chunk_manager.has_method("get_world_effective_light"):
		effective = chunk_manager.get_world_effective_light(world_pos)
	else:
		var sky: int = chunk_manager.get_world_sky_light(world_pos)
		var block: int = chunk_manager.get_world_block_light(world_pos)
		effective = WorldTime.effective_light_level(sky, block)
	return brightness_for_level(effective)
