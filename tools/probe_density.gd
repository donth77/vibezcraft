extends SceneTree

# One-shot diagnostic: sample Worldgen3D's depth/amplitude noise + density
# fields for chunk (0,0) at a fixed seed. Print per-coarse-column d4/d8/d9
# and the resulting density at iy=8 (mid-Y) so we can see whether the chain
# is collapsing into a constant baseline or actually varying per column.
#
# Usage:
#   godot --headless --path . -s tools/probe_density.gd -- <seed>


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 1737401494247853575
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	# Build noise stack
	Worldgen3D._ensure_noises(seed)

	# Sample the same 5×5 grid columns Worldgen3D uses
	var GRID_X: int = 5
	var GRID_Z: int = 5
	var DEPTH_SCALE: float = 200.0
	var AMPLITUDE_SCALE: float = 1.121
	var DEPTH_DIVISOR: float = 8000.0
	var AMPLITUDE_OFFSET: float = 256.0
	var AMPLITUDE_DIVISOR: float = 512.0

	print("seed=%d   chunk (0,0)" % seed)
	print("Sampling 5×5 coarse columns. Per-column raw h, raw g, computed d4, d8, d9.")
	print("")
	print(
		(
			"%4s %4s | %12s %12s | %8s %8s %8s"
			% ["ix", "iz", "h_raw", "g_raw", "d4", "d8", "d9"]
		)
	)
	print("-".repeat(72))

	var d4_min: float = 1e30
	var d4_max: float = -1e30
	var d8_min: float = 1e30
	var d8_max: float = -1e30
	var d9_min: float = 1e30
	var d9_max: float = -1e30
	var h_min: float = 1e30
	var h_max: float = -1e30
	var g_min: float = 1e30
	var g_max: float = -1e30

	const _CLIMATE_OFFSETS: Array = [1, 4, 7, 10, 13]
	for ix in range(GRID_X):
		var nx: float = float(0 * 16 + ix * 4)
		for iz in range(GRID_Z):
			var nz: float = float(0 * 16 + iz * 4)

			var h_raw: float = Worldgen3D._depth_noise.sample_2d(
				nx * DEPTH_SCALE, nz * DEPTH_SCALE
			)
			var g_raw: float = Worldgen3D._amplitude_noise.sample_2d(
				nx * AMPLITUDE_SCALE, nz * AMPLITUDE_SCALE
			)

			# Replicate Worldgen3D._compute_density chain for d4 + d8 + d9
			var center_x: float = float(0 * 16 + _CLIMATE_OFFSETS[ix])
			var center_z: float = float(0 * 16 + _CLIMATE_OFFSETS[iz])
			var climate: Vector2 = Worldgen3D.climate_at(center_x, center_z)
			var d5: float = climate.x
			var d6: float = climate.y * d5
			var d7: float = 1.0 - d6
			d7 *= d7
			d7 *= d7
			d7 = 1.0 - d7

			var d8: float = (g_raw + AMPLITUDE_OFFSET) / AMPLITUDE_DIVISOR
			d8 *= d7
			if d8 > 1.0:
				d8 = 1.0

			var d4: float = h_raw / DEPTH_DIVISOR
			if d4 < 0.0:
				d4 = -d4 * 0.3
			d4 = d4 * 3.0 - 2.0
			if d4 < 0.0:
				d4 = d4 / 2.0
				if d4 < -1.0:
					d4 = -1.0
				d4 = d4 / 1.4
				d4 = d4 / 2.0
				d8 = 0.0
			else:
				if d4 > 1.0:
					d4 = 1.0
				d4 = d4 / 8.0

			if d8 < 0.0:
				d8 = 0.0
			d8 += 0.5

			d4 = d4 * 16.0 / 16.0  # n6 = 16
			var d9: float = 16.0 / 2.0 + d4 * 4.0

			h_min = min(h_min, h_raw)
			h_max = max(h_max, h_raw)
			g_min = min(g_min, g_raw)
			g_max = max(g_max, g_raw)
			d4_min = min(d4_min, d4)
			d4_max = max(d4_max, d4)
			d8_min = min(d8_min, d8)
			d8_max = max(d8_max, d8)
			d9_min = min(d9_min, d9)
			d9_max = max(d9_max, d9)

			print(
				(
					"%4d %4d | %12.4f %12.4f | %8.4f %8.4f %8.4f"
					% [ix, iz, h_raw, g_raw, d4, d8, d9]
				)
			)

	print("-".repeat(72))
	print(
		"Ranges: h_raw [%.4f, %.4f]  g_raw [%.4f, %.4f]" % [h_min, h_max, g_min, g_max]
	)
	print(
		"        d4 [%.4f, %.4f]  d8 [%.4f, %.4f]  d9 [%.4f, %.4f]"
		% [d4_min, d4_max, d8_min, d8_max, d9_min, d9_max]
	)
	print("")
	print(
		"Vanilla expected: h_raw spans roughly [-8000, +8000]; ratio < 1 = flat ocean."
	)
	print(
		"d8 stuck at 0.5 = 'forced amplitude=0' path was taken (deep ocean baseline)."
	)
	print(
		"d9 ~= 8.0 means baseline column height = mid-chunk, no variation per column."
	)
	quit(0)
