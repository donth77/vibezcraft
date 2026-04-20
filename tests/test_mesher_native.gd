extends GutTest

# Smoke tests for the MesherNative GDExtension scaffold. Verifies the
# compiled native library loaded, the MesherNative class is registered
# in ClassDB, and the ping() binding round-trips a String through the
# GDScript <-> C++ boundary.
#
# These tests are the gate for the GDExtension toolchain itself — if they
# pass, the scaffold is healthy and the actual mesh_chunk port (follow-up
# commit) can proceed with confidence.


func test_class_is_registered() -> void:
	assert_true(
		ClassDB.class_exists("MesherNative"),
		"MesherNative not registered — did the .gdextension load? Rebuild via `scons`."
	)


func test_ping_returns_expected_string() -> void:
	var mn = ClassDB.instantiate("MesherNative")
	assert_not_null(mn, "failed to instantiate MesherNative")
	assert_eq(mn.ping(), "native mesher stub alive")
