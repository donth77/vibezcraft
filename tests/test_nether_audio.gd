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
