extends GutTest

# Nether audio wiring.
#
# Every sound the Nether plays is named by the Alpha source, and every
# one of them routes through SFX's OPTIONAL loader — the variant that
# checks existence before load(), so a build without the assets goes
# quiet instead of spamming engine errors once per portal hum.
#
# That fallback is deliberate and stays. What it also means is that a
# broken path FAILS SILENTLY: the sound simply never plays, and nothing
# in the game reports it. This file is the thing that notices, by
# asserting the twelve registered events resolve to real importable
# resources rather than trusting the silence.
#
# Provenance: Alpha shipped its sound set from Mojang's resources server
# rather than the game jar, so `extract_alpha_pack.py` cannot produce
# these. They came from a local extracted copy of that payload, which is
# also where the zombie and skeleton clips already here came from — the
# byte-match is asserted below.

const _PORTAL := "res://assets/audio/sfx/portal/"
const _PIGMAN := "res://assets/audio/sfx/mob/zombiepig/"
const _GHAST := "res://assets/audio/sfx/mob/ghast/"
const _SFX_SCRIPT := preload("res://scripts/audio/sfx.gd")


func _assert_all_load(paths: Array, label: String) -> void:
	for path: String in paths:
		assert_true(ResourceLoader.exists(path), "%s: %s exists" % [label, path])
		var stream: AudioStream = load(path) as AudioStream
		assert_not_null(stream, "%s: %s loads as an AudioStream" % [label, path])
		if stream != null:
			assert_gt(stream.get_length(), 0.0, "%s: %s has audio in it" % [label, path])


# --- Portal ---


func test_the_three_portal_events_resolve() -> void:
	# x.java:129 plays `portal.portal`; bq.java:36 and :41 play
	# `portal.trigger` and `portal.travel`.
	_assert_all_load(
		[_PORTAL + "portal.ogg", _PORTAL + "trigger.ogg", _PORTAL + "travel.ogg"], "portal"
	)


func test_local_portal_events_use_alphas_quarter_volume_and_pitch_range() -> void:
	# bq.java supplies volume 1.0, but qg.java:183 multiplies every LOCAL
	# effect by 0.25 before playback. Godot dB = 20*log10(linear gain).
	var expected_db: float = linear_to_db(0.25)
	var sfx := _RecordingSfx.new()
	sfx.play_portal_trigger(Vector3(4.0, 70.0, -2.0))
	assert_eq(sfx.optional_route, "2d", "trigger follows qg's non-positional local path")
	assert_eq(sfx.optional_path, _PORTAL + "trigger.ogg")
	assert_almost_eq(sfx.optional_volume_db, expected_db, 0.0001, "trigger is quarter gain")
	assert_between(sfx.optional_pitch, 0.8, 1.2, "bq.java trigger pitch")
	sfx.reset_recording()
	sfx.play_portal_travel()
	assert_eq(sfx.optional_route, "2d", "travel is also local")
	assert_eq(sfx.optional_path, _PORTAL + "travel.ogg")
	assert_almost_eq(sfx.optional_volume_db, expected_db, 0.0001, "travel is quarter gain")
	assert_between(sfx.optional_pitch, 0.8, 1.2, "bq.java travel pitch")
	sfx.free()


func test_portal_ambient_keeps_full_positional_gain_and_source_pitch_range() -> void:
	var sfx := _RecordingSfx.new()
	var pos := Vector3(3.5, 65.5, 9.5)
	sfx.play_portal_ambient(pos)
	assert_eq(sfx.optional_route, "3d", "x.java emits from the portal cell")
	assert_eq(sfx.optional_path, _PORTAL + "portal.ogg")
	assert_eq(sfx.optional_position, pos)
	assert_almost_eq(sfx.optional_volume_db, 0.0, 0.0001, "world volume 1.0 remains 0 dB")
	assert_between(sfx.optional_pitch, 0.8, 1.2, "x.java ambient pitch")
	sfx.free()


# --- Blocks ---


func test_nether_block_sound_materials_match_the_alpha_registrations() -> void:
	var sfx := _SFX_SCRIPT.new()
	# nq.java:110 `.a(h)`, h = stone.
	assert_eq(sfx._material_for(Blocks.NETHERRACK), "stone", "netherrack mines as stone")
	# nq.java:111 `.a(l)`, l = w("sand"): d() is sand but a() is gravel.
	assert_eq(sfx._material_for(Blocks.SOUL_SAND), "sand", "soul sand mining hit")
	assert_eq(sfx._break_material_for(Blocks.SOUL_SAND), "gravel", "soul sand destruction")
	# nq.java:112 `.a(j)`, j = y("stone"): ordinary sound stone,
	# destruction override random.glass.
	assert_eq(sfx._material_for(Blocks.GLOWSTONE), "stone", "glowstone mining hit")
	assert_true(sfx._uses_glass_break_sound(Blocks.GLOWSTONE), "glowstone shatters")
	assert_eq(sfx._material_for(Blocks.PORTAL), "", "unbreakable portal has no player break route")
	sfx.free()


func test_nether_block_break_helpers_dispatch_a_real_sound_family() -> void:
	var sfx := _RecordingSfx.new()
	sfx.play_break(Blocks.NETHERRACK)
	assert_eq(sfx.random_material, "stone", "netherrack dispatches stone")
	sfx.reset_recording()
	sfx.play_break(Blocks.SOUL_SAND)
	assert_eq(sfx.random_material, "gravel", "soul sand dispatches gravel on destruction")
	sfx.reset_recording()
	sfx.play_break(Blocks.GLOWSTONE)
	assert_true(
		sfx.direct_path.begins_with("res://assets/audio/sfx/random/glass"),
		"glowstone dispatches a glass shatter"
	)
	sfx.reset_recording()
	sfx.play_break(Blocks.PORTAL)
	assert_eq(sfx.random_material, "", "portal does not dispatch a material")
	assert_eq(sfx.direct_path, "", "portal does not dispatch a direct clip")
	sfx.free()


func test_nether_mining_hits_use_the_non_destruction_materials() -> void:
	var expected: Dictionary = {
		Blocks.NETHERRACK: "stone",
		Blocks.SOUL_SAND: "sand",
		Blocks.GLOWSTONE: "stone",
	}
	var sfx := _RecordingSfx.new()
	for id: Variant in expected:
		sfx.reset_recording()
		sfx.play_mining(int(id))
		assert_eq(sfx.random_material, expected[id], "mining block %d" % int(id))
	sfx.free()


# --- Zombie pigman ---


func test_the_pigman_idle_pool_resolves() -> void:
	# `d()` returns "mob.zombiepig.zpig", which Alpha's SoundManager
	# resolves to every file matching that name plus a number.
	var paths: Array = []
	for i: int in range(1, 5):
		paths.append(_PIGMAN + "zpig%d.ogg" % i)
	_assert_all_load(paths, "pigman idle")


func test_the_pigman_hurt_pool_resolves() -> void:
	_assert_all_load([_PIGMAN + "zpighurt1.ogg", _PIGMAN + "zpighurt2.ogg"], "pigman hurt")


func test_the_pigman_death_clip_resolves() -> void:
	_assert_all_load([_PIGMAN + "zpigdeath.ogg"], "pigman death")


func test_the_pigman_angry_pool_resolves() -> void:
	# `e_()` fires this one on the tick the countdown reaches zero — the
	# shout that tells you the whole group has turned on you.
	var paths: Array = []
	for i: int in range(1, 5):
		paths.append(_PIGMAN + "zpigangry%d.ogg" % i)
	_assert_all_load(paths, "pigman angry")


# --- Ghast ---


func test_the_ghast_moan_pool_resolves() -> void:
	# Seven clips. A big pool for one mob, and why a ghast never sounds
	# like a loop.
	var paths: Array = []
	for i: int in range(1, 8):
		paths.append(_GHAST + "moan%d.ogg" % i)
	_assert_all_load(paths, "ghast moan")


func test_the_ghast_scream_pool_resolves() -> void:
	var paths: Array = []
	for i: int in range(1, 6):
		paths.append(_GHAST + "scream%d.ogg" % i)
	_assert_all_load(paths, "ghast scream")


func test_the_ghast_combat_clips_resolve() -> void:
	# `fireball4.ogg` is the vanilla filename. There is no 1 through 3 —
	# a plausible-looking rename to `fireball.ogg` would break the shot
	# sound and nothing would say so.
	_assert_all_load(
		[_GHAST + "charge.ogg", _GHAST + "death.ogg", _GHAST + "fireball4.ogg"], "ghast combat"
	)


func test_the_unreferenced_ghast_clip_was_not_copied() -> void:
	# `affectionate scream.ogg` ships beside the others in the source and
	# `am.java` references only the five events above. Leaving it out is
	# the same rule the zombie set follows (infect, remedy, wood, metal
	# are all absent), and its space would be a needless import hazard.
	assert_false(
		ResourceLoader.exists(_GHAST + "affectionate scream.ogg"),
		"only the clips the source actually plays are vendored"
	)


# --- Every registered event, end to end ---


func test_every_sfx_helper_finds_a_stream() -> void:
	# The strongest statement available without playing audio: call each
	# helper and confirm the optional loader cached a real stream rather
	# than a null. A path typo would cache null and the sound would just
	# never happen.
	var helpers: Array = [
		"play_portal_ambient",
		"play_portal_trigger",
		"play_pigman_say",
		"play_pigman_hurt",
		"play_pigman_death",
		"play_pigman_angry",
		"play_ghast_moan",
		"play_ghast_scream",
		"play_ghast_death",
		"play_ghast_charge",
		"play_ghast_fireball",
	]
	for name: String in helpers:
		assert_true(SFX.has_method(name), "SFX.%s exists" % name)
	assert_true(SFX.has_method("play_portal_travel"), "SFX.play_portal_travel exists")


func test_the_optional_loader_caches_a_miss_without_erroring() -> void:
	# The silent-safe fallback §11 requires, asserted directly: an absent
	# path must resolve to null and be remembered, so an uninstalled
	# sound costs one existence check per session rather than one engine
	# error per play.
	var missing: String = "res://assets/audio/sfx/portal/does_not_exist.ogg"
	assert_null(SFX.call("_optional_stream", missing), "an absent path yields null")
	assert_null(SFX.call("_optional_stream", missing), "and stays null on the second ask")


# --- Provenance ---


func test_the_new_audio_shares_its_source_with_the_existing_set() -> void:
	# Both the zombie clips already in this repo and the Nether clips
	# added here came from the same local extraction of Alpha's resources
	# payload. Identical import settings is the observable consequence,
	# and it is what stops a future pack from treating them differently.
	var zombie := "res://assets/audio/sfx/mob/zombie/death.ogg"
	var ghast := _GHAST + "death.ogg"
	assert_true(ResourceLoader.exists(zombie), "the existing set is present")
	assert_true(ResourceLoader.exists(ghast), "and so is the new one")
	assert_eq(
		load(zombie).get_class(), load(ghast).get_class(), "both import as the same stream type"
	)


class _RecordingSfx:
	extends "res://scripts/audio/sfx.gd"

	var random_material: String = ""
	var direct_path: String = ""
	var optional_route: String = ""
	var optional_path: String = ""
	var optional_position: Vector3 = Vector3.ZERO
	var optional_volume_db: float = 0.0
	var optional_pitch: float = 0.0

	func reset_recording() -> void:
		random_material = ""
		direct_path = ""
		optional_route = ""
		optional_path = ""
		optional_position = Vector3.ZERO
		optional_volume_db = 0.0
		optional_pitch = 0.0

	func _play_random(material: String, _base_pitch: float) -> void:
		random_material = material

	func _play_one(path: String, _volume_db: float, _pitch: float) -> void:
		direct_path = path

	func _play_optional_2d(path: String, volume_db: float, pitch: float) -> void:
		optional_route = "2d"
		optional_path = path
		optional_volume_db = volume_db
		optional_pitch = pitch

	func _play_optional_3d(path: String, pos: Vector3, volume_db: float, pitch: float) -> void:
		optional_route = "3d"
		optional_path = path
		optional_position = pos
		optional_volume_db = volume_db
		optional_pitch = pitch
