class_name EntityLighting

# Vanilla Alpha entity lighting — entities sample sky + block light at
# their cell each tick and apply the brightness LUT result as a colour
# multiplier on their texture. Without this, entities render at full
# brightness regardless of time of day or cover.
#
# Vanilla refs:
#   oz.java:22-28  — World.brightness LUT (per light level 0..15)
#   cy.java        — World.j(time) sun-brightness scaler (we use WorldTime)

const _FLOOR: float = 0.05


# Vanilla LUT formula. Returns 0.05..1.0 — matches the LUT baked into
# chunk.gdshader so entities visually match the surrounding terrain.
static func brightness_for_level(level: int) -> float:
	var l: float = clampf(float(level), 0.0, 15.0)
	var f3: float = 1.0 - l / 15.0
	return (1.0 - f3) / (f3 * 3.0 + 1.0) * (1.0 - _FLOOR) + _FLOOR


# Sample the effective light at a world cell, accounting for day-night.
# Returns a 0.05..1.0 multiplier suitable for `mat.albedo_color = Color(b,b,b)`.
static func sample_brightness(chunk_manager: Node, world_pos: Vector3i) -> float:
	if chunk_manager == null:
		return 1.0
	var sky: int = chunk_manager.get_world_sky_light(world_pos)
	var block: int = chunk_manager.get_world_block_light(world_pos)
	var sky_factor: float = WorldTime.sky_factor()
	var effective: int = maxi(int(round(float(sky) * sky_factor)), block)
	return brightness_for_level(effective)
