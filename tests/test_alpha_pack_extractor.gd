extends GutTest

# Alpha texture-pack extractor guard (docs/nether-alpha-1.2.6-implementation-plan.md
# Batch 0).
#
# The plan's §3.5 says the extractor is missing. It is not — commit
# 1d12a1b moved it, with six other vanilla-touching tools, into the
# gitignored scripts/dev/internal/. What the move DID break was its
# `ROOT` constant: the file went one directory deeper without the
# path-walk being updated, so every input path resolved under scripts/
# and the tool could not run at all. That is fixed; this file keeps it
# fixed.
#
# Only the --verify dry run is exercised. Running the real extraction
# from a test would rewrite the active texture pack as a side effect,
# and the Batch 0 contract is that nothing existing changes appearance.
#
# Everything here degrades to a skip when the gitignored vendor tree,
# Python or Pillow is absent, so a clean checkout still goes green.

const _EXTRACTOR := "scripts/dev/internal/extract_alpha_pack.py"
const _VENDOR_JAR := "vendor/mojang/alpha-1.2.6/client.jar"

var _repo_root: String = ""
var _available: bool = false
var _verify_output: String = ""
var _verify_exit: int = -1


func before_all() -> void:
	_repo_root = ProjectSettings.globalize_path("res://").trim_suffix("/")
	var extractor: String = _repo_root.path_join(_EXTRACTOR)
	var jar: String = _repo_root.path_join(_VENDOR_JAR)
	if not FileAccess.file_exists(extractor) or not FileAccess.file_exists(jar):
		return
	var out: Array = []
	var exit_code: int = OS.execute("python3", [extractor, "--verify"], out, true)  # read stderr too
	_verify_exit = exit_code
	_verify_output = "\n".join(
		PackedStringArray(out.map(func(x: Variant) -> String: return str(x)))
	)
	# Pillow missing is an environment gap, not a regression.
	if _verify_output.contains("ModuleNotFoundError"):
		return
	_available = true


func _skip_if_unavailable() -> bool:
	if not _available:
		pass_test("extractor, vendor jar or Pillow unavailable — skipped")
		return true
	return false


func test_extractor_lives_in_the_gitignored_internal_dir() -> void:
	# Independent of the vendor tree: the file must exist where the move
	# put it, so CLAUDE.md's layout note and the plan stay honest.
	assert_true(FileAccess.file_exists(_repo_root.path_join(_EXTRACTOR)), "%s exists" % _EXTRACTOR)
	assert_false(
		FileAccess.file_exists(_repo_root.path_join("scripts/dev/extract_alpha_pack.py")),
		"the tool is not duplicated back into the tracked dev dir"
	)


func test_verify_reports_every_required_alpha_input() -> void:
	if _skip_if_unavailable():
		return
	for needle: String in ["terrain.png", "gui/items.png", "mob/char.png"]:
		assert_true(_verify_output.contains(needle), "verify reports input %s" % needle)
	assert_false(_verify_output.contains("MISS"), "no required input is missing")


func test_verify_reports_the_nether_assets_the_plan_requires() -> void:
	if _skip_if_unavailable():
		return
	# Tile coordinates are source-confirmed from nq.java:110-113 and
	# dx.java:101 — see the extractor's NETHER_* maps.
	for needle: String in [
		"netherrack",
		"soul_sand",
		"glowstone",
		"portal",
		"glowstone_dust",
		"pigzombie.png",
		"ghast.png",
		"ghast_fire.png",
	]:
		assert_true(_verify_output.contains(needle), "verify reports Nether asset %s" % needle)


func test_verify_confirms_no_write_target_is_tracked() -> void:
	if _skip_if_unavailable():
		return
	# The acceptance criterion: extraction must never stage raw Mojang
	# assets. verify asks `git check-ignore` about each write target.
	assert_false(
		_verify_output.contains("TRACKED"),
		"every extraction target is gitignored:\n%s" % _verify_output
	)
	assert_true(_verify_output.contains("verify: PASS"), "the dry run reports PASS")


func test_verify_exits_cleanly_and_writes_nothing() -> void:
	if _skip_if_unavailable():
		return
	assert_eq(_verify_exit, 0, "verify exits 0")
	# A dry run must not have created the pack dirs' marker output. The
	# real run prints "wrote N blocks"; verify prints "would write".
	assert_true(_verify_output.contains("would write"), "verify describes, not performs")
	assert_false(_verify_output.contains("wrote "), "verify did not write")
