extends SceneTree


func _init() -> void:
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(0)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(0)

	# Sample h_grid + g_grid + climate for chunk (0,0), then walk d4/d8/d9 chain
	var DEPTH_SCALE: float = 200.0
	var AMPLITUDE_SCALE: float = 1.121
	const _CLIMATE_OFFSETS: Array = [1, 4, 7, 10, 13]

	print("# Per coarse column for chunk (0,0) seed 0:")
	print(
		(
			"%-8s %-10s %-10s %-10s %-10s %-10s %-8s %-8s"
			% ["(ix,iz)", "h_raw", "g_raw", "temp", "rain", "d7", "d4", "d8", "d9"]
		)
	)
	for ix in range(5):
		for iz in range(5):
			var nx: float = float(0 * 4 + ix)
			var nz: float = float(0 * 4 + iz)
			var h: float = Worldgen3D._depth_noise.sample_2d(nx * DEPTH_SCALE, nz * DEPTH_SCALE)
			var g: float = Worldgen3D._amplitude_noise.sample_2d(
				nx * AMPLITUDE_SCALE, nz * AMPLITUDE_SCALE
			)
			var center_x: float = float(0 * 16 + _CLIMATE_OFFSETS[ix])
			var center_z: float = float(0 * 16 + _CLIMATE_OFFSETS[iz])
			var climate: Vector2 = Worldgen3D.climate_at(center_x, center_z)
			var d6: float = climate.y * climate.x
			var d7: float = 1.0 - d6
			d7 *= d7
			d7 *= d7
			d7 = 1.0 - d7
			var d8: float = (g + 256.0) / 512.0
			d8 *= d7
			if d8 > 1.0:
				d8 = 1.0
			var d4: float = h / 8000.0
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
			d4 = d4 * 17.0 / 16.0  # n6 = 17 in our code (vanilla GRID_Y is 17 too)
			var d9: float = 17.0 / 2.0 + d4 * 4.0
			print(
				(
					"(%d,%d)   %10.2f %10.2f %10.4f %10.4f %10.4f %8.4f %8.4f %8.4f"
					% [ix, iz, h, g, climate.x, climate.y, d7, d4, d8, d9]
				)
			)
	quit(0)
