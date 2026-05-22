extends GutTest

# Lighting slice 2: WorldTime autoload covering day cycle math, sky_factor
# (slice-1 effective_light hook), sun direction, sky/ambient color stops.


func before_each() -> void:
	# Restore vanilla 20-minute day length and noon start, since other tests
	# (or earlier runs) may have stepped the clock.
	WorldTime.set_day_length(WorldTime.VANILLA_DAY_SECONDS)
	WorldTime.set_time_ticks(6000)


# --- Tick advancement ---


func test_default_day_length_matches_vanilla() -> void:
	assert_eq(WorldTime.VANILLA_DAY_SECONDS, 1200.0)
	assert_eq(WorldTime.TICKS_PER_DAY, 24000)


func test_set_day_length_clamps_to_one_second_minimum() -> void:
	WorldTime.set_day_length(0.0)
	assert_eq(WorldTime.day_length_seconds, 1.0)
	WorldTime.set_day_length(-50.0)
	assert_eq(WorldTime.day_length_seconds, 1.0)


func test_set_time_ticks_wraps_into_day() -> void:
	WorldTime.set_time_ticks(WorldTime.TICKS_PER_DAY + 500)
	assert_eq(WorldTime.current_tick(), 500)
	WorldTime.set_time_ticks(-100)
	assert_eq(WorldTime.current_tick(), WorldTime.TICKS_PER_DAY - 100)


# --- Phase + sun elevation ---


func test_phase_at_canonical_ticks() -> void:
	# Vanilla convention used here: tick 0 = sunrise (phase 0, sun on east
	# horizon), 6000 = noon (phase 0.25, zenith), 12000 = sunset
	# (phase 0.5), 18000 = midnight (phase 0.75, nadir).
	WorldTime.set_time_ticks(0)
	assert_almost_eq(WorldTime.phase(), 0.0, 0.001)
	WorldTime.set_time_ticks(6000)
	assert_almost_eq(WorldTime.phase(), 0.25, 0.001)
	WorldTime.set_time_ticks(12000)
	assert_almost_eq(WorldTime.phase(), 0.5, 0.001)
	WorldTime.set_time_ticks(18000)
	assert_almost_eq(WorldTime.phase(), 0.75, 0.001)


func test_sun_elevation_peaks_at_noon_troughs_at_midnight() -> void:
	WorldTime.set_time_ticks(6000)  # noon
	assert_almost_eq(WorldTime.sun_elevation(), 1.0, 0.001)
	WorldTime.set_time_ticks(18000)  # midnight
	assert_almost_eq(WorldTime.sun_elevation(), -1.0, 0.001)
	WorldTime.set_time_ticks(0)  # sunrise — horizon
	assert_almost_eq(WorldTime.sun_elevation(), 0.0, 0.001)
	WorldTime.set_time_ticks(12000)  # sunset — horizon
	assert_almost_eq(WorldTime.sun_elevation(), 0.0, 0.001)


# --- Sky factor (the key slice-1 hook) ---


func test_sky_factor_full_at_noon() -> void:
	WorldTime.set_time_ticks(6000)
	assert_almost_eq(WorldTime.sky_factor(), WorldTime.SKY_FACTOR_MAX, 0.001)


func test_sky_factor_floor_at_midnight() -> void:
	WorldTime.set_time_ticks(18000)
	assert_almost_eq(WorldTime.sky_factor(), WorldTime.SKY_FACTOR_MIN, 0.001)


func test_sky_factor_intermediate_at_dawn_and_dusk() -> void:
	# At sunrise / sunset the vanilla curve sin(phase·TAU)*2+0.5 lands at
	# exactly 0.5 (the horizon shoulder), which lerps to min + 0.5*(max-min)
	# — well above the midnight floor but below the daytime plateau.
	# Crucially: same value at sunrise and sunset.
	WorldTime.set_time_ticks(0)
	var dawn: float = WorldTime.sky_factor()
	WorldTime.set_time_ticks(12000)
	var dusk: float = WorldTime.sky_factor()
	assert_almost_eq(dawn, dusk, 0.001)
	assert_gt(dawn, WorldTime.SKY_FACTOR_MIN)
	assert_lt(dawn, WorldTime.SKY_FACTOR_MAX)


# --- Color stops ---


func test_sky_color_dawn_is_orange_tinted() -> void:
	# Phase 0.01 is within the dawn peak orange plateau (0.00–0.02).
	WorldTime.set_time_ticks(int(0.01 * WorldTime.TICKS_PER_DAY))
	var c: Color = WorldTime.sky_color()
	assert_gt(c.r, c.b, "dawn sky should be redder than blue")


func test_sky_color_noon_is_blue_tinted() -> void:
	WorldTime.set_time_ticks(6000)
	var c: Color = WorldTime.sky_color()
	assert_gt(c.b, c.r, "noon sky should be more blue than red")


func test_sky_color_midnight_is_dark() -> void:
	WorldTime.set_time_ticks(18000)
	var c: Color = WorldTime.sky_color()
	assert_lt(c.r + c.g + c.b, 0.5, "midnight sky should be near-black")


# --- Sun direction ---


func test_sun_direction_points_down_at_noon() -> void:
	# Noon: sun overhead (sun_pos = (cos(π/2), sin(π/2), 0.2) = (0, 1, 0.2)),
	# direction sunlight TRAVELS = -normalized(sun_pos), so .y component
	# should be strongly negative (down).
	WorldTime.set_time_ticks(6000)
	var d: Vector3 = WorldTime.sun_direction()
	assert_lt(d.y, -0.9, "noon sun should travel downward")


func test_sun_energy_zero_at_midnight_peak_at_noon() -> void:
	WorldTime.set_time_ticks(18000)
	assert_eq(WorldTime.sun_energy(1.5), 0.0)
	WorldTime.set_time_ticks(6000)
	assert_almost_eq(WorldTime.sun_energy(1.5), 1.5, 0.001)


# --- Process tick advances time ---


func test_process_advances_time() -> void:
	WorldTime.set_day_length(20.0)  # 20-second day → 1200 ticks/sec
	WorldTime.set_time_ticks(0)
	WorldTime._process(1.0)  # 1 second → 1200 ticks
	assert_eq(WorldTime.current_tick(), 1200)


func test_process_wraps_at_day_boundary() -> void:
	WorldTime.set_day_length(20.0)
	WorldTime.set_time_ticks(WorldTime.TICKS_PER_DAY - 100)
	WorldTime._process(1.0)  # advance by 1200 ticks → wraps
	# ticks_per_sec = 24000/20 = 1200; new = (24000-100+1200) % 24000 = 1100
	assert_eq(WorldTime.current_tick(), 1100)
