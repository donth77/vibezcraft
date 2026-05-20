extends Node3D

# Vanilla-style celestial sphere — sun + moon billboards on a pivot that
# rotates with WorldTime. The pivot follows the player so the sky always
# appears at "infinity" relative to the camera, but rotates independently
# of player look direction.
#
# Vanilla reference (Beta-era RenderGlobal.renderSky): sun + moon are two
# camera-locked square quads on a celestial sphere ~100 units out, scaled
# to ~30° angular size each, fading toward darker shading at night. We
# reproduce that without the precise 30° math — just place the quads at
# a fixed distance, scale to look right.
#
# Cloud layer is a separate single textured plane scrolling at vanilla's
# ~0.6 m/s above the world (~y = SIZE_Y - 8). World-position offset, no
# parallax — vanilla matches this.

const _SUN_DISTANCE: float = 256.0
# Sized to match the same angular size the previous 90-unit values gave
# (30 / 90 ≈ 0.33 rad). At render_distance = 8 chunks the diagonal reach
# is ~181 blocks; the old 90-unit distance let distant terrain z-buffer
# in FRONT of the celestial body, producing the "moon clips through far
# blocks" symptom. 256 is comfortably beyond any in-view chunk.
const _SUN_SIZE: float = 85.0  # 30 × (256 / 90)
const _MOON_SIZE: float = 71.0  # 25 × (256 / 90)
# Vanilla Alpha cloud altitude (f.java:652 `f9 = 108.0f - f6 + 0.33f`) —
# absolute world y = 108. Our old value of SIZE_Y-1+12=139 put clouds too
# high, shrinking their apparent size and making the cell grid more visible
# (more cells in FOV looks like "a bunch of boxes" rather than big slabs).
const _CLOUD_ALTITUDE_Y: float = 108.0
const _CLOUD_SCROLL_SPEED: float = 0.6  # vanilla 0.03 m/tick × 20 tick/s = 0.6 m/s
# Vanilla cloud UV scale: f.java:617 sets `f3 = 4.8828125E-4 = 1/2048`
# blocks per UV unit. 256-pixel texture / (1/2048) = 1 full texture per
# 2048 world blocks → 8 world blocks per cloud pixel. Earlier 3072
# (derived from "1 pixel = 12 blocks") was Beta-era, not Alpha 1.2.6.
const _CLOUD_TEXTURE_WORLD_SIZE: float = 2048.0
# Plane size: large enough that edges sit beyond the camera far plane at
# normal viewing angles, but not so large that the cloud-shader fragment
# work dominates frametime. 512×512 covers ~3× render_distance worth of
# horizontal sky and adds <2% per-frame fragment cost on a 1080p monitor.
# Earlier 1024 caused FPS to halve due to fillrate (~4× more pixels).
const _CLOUD_PLANE_SIZE: float = 512.0

# Single preload so both fast + fancy cloud builders share the texture
# resource (gdlint flags duplicated load() calls; preload also defers
# the file fetch to script-load time).
const _CLOUD_TEXTURE: Texture2D = preload("res://assets/textures/sky/clouds.png")

@export var player_path: NodePath = ^"../Player"

var _sun_pivot: Node3D
var _moon: MeshInstance3D
var _sun: MeshInstance3D
var _cloud_plane: MeshInstance3D
var _cloud_material: ShaderMaterial
# Debug probe: throttled log counter. Fires when Game.debug_clouds is on.
var _debug_clouds_last_print_ms: int = 0
var _debug_clouds_stats_printed: bool = false

@onready var _player: Node3D = get_node_or_null(player_path) as Node3D


func _ready() -> void:
	# Sun + moon live on a rotating pivot. The pivot's basis spins with
	# celestial angle so the sun rises in +X and sets in -X — sun and moon
	# sit on opposite sides of the pivot.
	_sun_pivot = Node3D.new()
	add_child(_sun_pivot)

	_sun = _build_celestial_quad("res://assets/textures/sky/sun.png", _SUN_SIZE)
	_sun.position = Vector3(0, 0, -_SUN_DISTANCE)
	_sun_pivot.add_child(_sun)

	_moon = _build_celestial_quad("res://assets/textures/sky/moon.png", _MOON_SIZE)
	# Moon is opposite the sun on the celestial sphere.
	_moon.position = Vector3(0, 0, _SUN_DISTANCE)
	_sun_pivot.add_child(_moon)

	# Cloud quality switch — vanilla split between fast (flat plane) and
	# fancy (3D box clouds with shaded sides). Game.cloud_quality reads
	# from project setting / env override; default = fancy (the iconic
	# look). Off skips clouds entirely.
	if Game.cloud_quality == Game.CLOUD_QUALITY_FAST:
		_cloud_plane = _build_cloud_plane()
		add_child(_cloud_plane)
	elif Game.cloud_quality == Game.CLOUD_QUALITY_FANCY:
		_cloud_plane = _build_fancy_cloud_mesh_instance()
		add_child(_cloud_plane)


func _process(_delta: float) -> void:
	# Defensive re-resolve: @onready can race with the player scene
	# instantiation under some load orders. If _player is null the dome
	# stays at world origin and the sun appears at e.g. (0, 90, 0) —
	# rendered into the ground from the player's actual POV at (8, 100, 8).
	if _player == null:
		_player = get_node_or_null(player_path) as Node3D
	# Sky dome follows the player in ALL three axes so the celestial
	# sphere always appears centered on the camera. Pivot then rotates
	# the sun/moon around the player's position.
	if _player != null:
		global_position = _player.global_position
	# Pivot rotates around +X so the sun arcs E (sunrise) → up (noon) →
	# W (sunset) → down (midnight). Sun starts at (0, 0, -DISTANCE);
	# rotation by phase*TAU around +X (right-hand rule: +Y → +Z) carries
	# (0, 0, -DISTANCE) to (0, +DISTANCE, 0) at quarter rotation = noon.
	# Earlier impl used -X axis which inverted the arc, putting the sun
	# below the player at "noon" and the moon overhead — matches the
	# "I see the moon at noon" symptom.
	var angle: float = WorldTime.phase() * TAU
	_sun_pivot.transform.basis = Basis(Vector3(1, 0, 0), angle)

	# Sun visibility tracks the elevation — fade in/out around the horizon
	# so the sun doesn't pop. Same for moon (inverted: visible at night).
	var elev: float = WorldTime.sun_elevation()
	if _sun != null:
		_sun.visible = elev > -0.2  # show through dawn/dusk
	if _moon != null:
		_moon.visible = elev < 0.2  # moon shows opposite

	# Cloud plane: anchored above the world (NOT player y) so player can
	# fly up and through them. Horizontal position follows the player with
	# a CONTINUOUS fractional offset, matching vanilla f.java:677
	# (`f13 = d2 - floor(d2)`). The mesh slides smoothly under the player
	# so clusters drift in world space as scroll advances and player moves.
	#
	# Earlier impl used `floor(pp.x / 12) * 12` which snapped every 12
	# blocks — that was the visible "jump" the player saw. Vanilla's
	# fractional offset rebuilds the mesh vertex positions each frame
	# with `f18 = i3*n4 - f13`; since we use a pre-built mesh, we achieve
	# the same effect by moving the plane itself by the negative fraction.
	var t: float = Time.get_ticks_msec() / 1000.0
	var scroll: float = t * _CLOUD_SCROLL_SPEED
	if _cloud_plane != null:
		var pp := Vector3.ZERO if _player == null else _player.global_position
		# Plane follows player, offset by -frac(d2)*12 in X and -frac(d3)*12
		# in Z where d2=(pp.x+scroll)/12, d3=pp.z/12. This keeps the mesh
		# geometry aligned to the 12-block texture grid (cell boundaries
		# fall on integer texel edges) while sliding smoothly.
		var frac_x: float = fposmod(pp.x + scroll, 12.0)
		var frac_z: float = fposmod(pp.z, 12.0)
		_cloud_plane.global_position = Vector3(pp.x - frac_x, _CLOUD_ALTITUDE_Y, pp.z - frac_z)
	if _cloud_material != null:
		_cloud_material.set_shader_parameter("scroll_offset", scroll)
	if Game.debug_clouds:
		_debug_log_clouds()


# Throttled diagnostic probe — enabled with MC_CLONE_DEBUG_CLOUDS=1. Logs
# once per second so it doesn't flood the terminal. Prints: cloud-plane
# world position, player Y, current scroll offset, and the cloud-texture
# alpha at the player-under cell (so you can tell whether the cell under
# the crosshair should be rendering cloud or sky). Useful for diagnosing
# "boxes missing floors" / "can see through clouds" mismatches.
func _debug_log_clouds() -> void:
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _debug_clouds_last_print_ms < 1000:
		return
	_debug_clouds_last_print_ms = now_ms
	var mode_name: String = ["OFF", "FAST", "FANCY"][Game.cloud_quality]
	var cloud_y: float = _cloud_plane.global_position.y if _cloud_plane != null else -1.0
	var player_y: float = _player.global_position.y if _player != null else -1.0
	var scroll: float = Time.get_ticks_msec() / 1000.0 * _CLOUD_SCROLL_SPEED
	if _CLOUD_TEXTURE == null or _player == null:
		return
	var img: Image = _CLOUD_TEXTURE.get_image()
	if img == null:
		return
	# One-shot whole-texture density stats — tells us whether the texture
	# itself is sparse or whether we're just unlucky on sampling position.
	if not _debug_clouds_stats_printed:
		_debug_clouds_stats_printed = true
		var total: int = 0
		var peak_cluster: int = 0
		for y in range(256):
			var row_run: int = 0
			for x in range(256):
				if img.get_pixel(x, y).a >= 0.5:
					total += 1
					row_run += 1
					peak_cluster = maxi(peak_cluster, row_run)
				else:
					row_run = 0
		print(
			(
				"[Clouds] texture density=%.1f%% (%d/%d texels) max_x_run=%d cells"
				% [
					100.0 * float(total) / (256.0 * 256.0),
					total,
					65536,
					peak_cluster,
				]
			)
		)
	# Sample a 7×7 grid of cells centered on the player, using the same
	# UV math the shader applies. Now that we blend the full gradient,
	# the useful metric is "any non-zero cloud" (anything alpha >= 0.01
	# that the shader wouldn't discard). The ASCII map uses density buckets:
	#   ' ' = sky (< 0.01), '.' = faint (< 0.3), '+' = partial (< 0.7), '#' = solid.
	# Vanilla clusters should show as mostly # with . and + edges.
	# Scattered 1-cell #s with big . surrounding = sparse gradient, good.
	# Nothing but # with sharp . boundaries = old binary-cutoff bug.
	const CELL_WORLD: float = 12.0
	const TEX_WORLD: float = CELL_WORLD * 256.0
	const GRID: int = 7
	const HALF: int = GRID / 2
	var rendered: int = 0  # alpha >= 0.01 discard threshold
	var solid: int = 0  # alpha >= 0.7 nearly opaque
	var max_alpha: float = 0.0
	var px: float = _player.global_position.x
	var pz: float = _player.global_position.z
	var rows: Array[String] = []
	for dz in range(-HALF, HALF + 1):
		var row := ""
		for dx in range(-HALF, HALF + 1):
			var cx: float = px + float(dx) * CELL_WORLD
			var cz: float = pz + float(dz) * CELL_WORLD
			var u: float = fposmod(cx + scroll, TEX_WORLD) / TEX_WORLD
			var v: float = fposmod(cz, TEX_WORLD) / TEX_WORLD
			var ix: int = int(u * 256.0) % 256
			var iy: int = int(v * 256.0) % 256
			var a: float = img.get_pixel(ix, iy).a
			max_alpha = maxf(max_alpha, a)
			if a < 0.01:
				row += " "
			elif a < 0.3:
				row += "."
				rendered += 1
			elif a < 0.7:
				row += "+"
				rendered += 1
			else:
				row += "#"
				rendered += 1
				solid += 1
		rows.append(row)
	# Texel under player — tells us what region of the texture we're in,
	# so we can tell whether "sparse clouds" is local or texture-wide.
	var u_player: float = fposmod(px + scroll, TEX_WORLD) / TEX_WORLD
	var v_player: float = fposmod(pz, TEX_WORLD) / TEX_WORLD
	var tx: int = int(u_player * 256.0) % 256
	var tz: int = int(v_player * 256.0) % 256
	print(
		(
			(
				"[Clouds] mode=%s cloud_y=%.1f px=%.1f py=%.1f pz=%.1f"
				+ " texel=(%d,%d) scroll=%.2f rendered=%d/49 solid=%d max=%.2f"
			)
			% [mode_name, cloud_y, px, player_y, pz, tx, tz, scroll, rendered, solid, max_alpha]
		)
	)
	if rendered > 0:
		for r in rows:
			print("[Clouds]   |" + r + "|")


func _build_celestial_quad(texture_path: String, size: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	# Quad faces +Z by default. Sun/moon should face the camera at the
	# pivot center, so place at (0, 0, ±DISTANCE) and rotate so the visible
	# face points back toward origin. QuadMesh's default normal is +Z, so
	# the sun at (0, 0, -DISTANCE) needs no rotation (its +Z face points
	# toward origin = camera). The moon at (0, 0, +DISTANCE) needs a 180°
	# Y flip so its +Z face points back at origin.
	mi.mesh = mesh
	# Custom material: unshaded textured, alpha-blended. Normal depth
	# test ON — sun sits 90 units from the player in 3D, normal z-buffer
	# correctly places it behind any closer terrain. Earlier
	# `no_depth_test = true` made the sun draw on top of the camera
	# plane, appearing as "a sun-looking object following me in my vision"
	# instead of in the sky.
	# Disable shadow casting — the 30-unit sun quad would otherwise project
	# a giant 30x30 block square shadow on the ground from the directional
	# light in the scene. Sky elements never cast.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Custom shader: sun.png is fully opaque (alpha=255 everywhere), with
	# the actual sun shape carried in the RGB and BLACK around it. We
	# derive a per-pixel alpha from RGB luminance so the black surround
	# becomes transparent and the bright sun core stays opaque. Standard
	# alpha blend then renders the sun as a glowing disk against the sky.
	#
	# Vanilla uses additive blend (glBlendFunc(GL_ONE, GL_ONE) in
	# f.java:545) which works the same way against a black-filtered
	# scene; on our pre-coloured sky it dimmed the sun core. Luminance
	# alpha-cutoff is the equivalent for a standard pipeline.
	var shader := Shader.new()
	# `FOG = vec4(0.0)` zeros Godot's per-fragment fog contribution so the
	# sun/moon quads render at their true color regardless of view-distance
	# fog. Mirrors vanilla glDisable(GL_FOG) around kb.java:540 sun/moon
	# draw calls. Godot 4 doesn't support a shader-level disable_fog
	# render_mode for spatial shaders — writing FOG is the supported way.
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform sampler2D sun_texture : filter_nearest;

void fragment() {
	vec4 c = texture(sun_texture, UV);
	float lum = max(c.r, max(c.g, c.b));
	if (lum < 0.3) {
		discard;
	}
	ALBEDO = c.rgb;
	ALPHA = 1.0;
	FOG = vec4(0.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("sun_texture", load(texture_path) as Texture2D)
	mi.material_override = mat
	return mi


func _build_cloud_plane() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(_CLOUD_PLANE_SIZE, _CLOUD_PLANE_SIZE)
	mesh.subdivide_width = 0
	mesh.subdivide_depth = 0
	mi.mesh = mesh
	# Custom shader sampling cloud texture in WORLD-XZ space (so clouds
	# stay fixed in world frame as the plane translates with the player).
	# Vanilla algorithm (vendor/alpha-1.2.6-src/src/f.java:b(float),
	# lines 588-639):
	#   • Quad UVs = world_pos.xz × (1/2048) → 8 world blocks / cloud
	#     pixel.
	#   • Standard alpha blend (glBlendFunc(GL_SRC_ALPHA,
	#     GL_ONE_MINUS_SRC_ALPHA)).
	#   • Color = sky_cloud_color × alpha 0.8. Texture's 0..1 alpha
	#     channel modulates that 0.8 — soft cloud edges come from the
	#     texture's gradient alpha. clouds.png has no fully-transparent
	#     pixels (min alpha 1, max 255, mean 52) — the soft edges ARE
	#     the cloud body. A discard cutoff loses ~80% of the fluff.
	var shader := Shader.new()
	# FOG=0 disables per-fragment fog on clouds — the cloud plane sits at
	# y≈108 in world space and would otherwise fog out at FAR. Vanilla's
	# f.java:b(float) runs its cloud pass with GL_FOG disabled.
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform sampler2D cloud_texture : filter_nearest;
uniform float scroll_offset = 0.0;
uniform float tex_world_size = 2048.0;
uniform float sky_factor = 1.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 wuv = vec2(v_world_pos.x + scroll_offset, v_world_pos.z) / tex_world_size;
	vec4 c = texture(cloud_texture, fract(wuv));
	if (c.a < 0.01) {
		discard;
	}
	float tint = mix(0.15, 1.0, sky_factor);
	ALBEDO = c.rgb * tint;
	ALPHA = c.a * 0.8;
	FOG = vec4(0.0);
}
"""
	_cloud_material = ShaderMaterial.new()
	_cloud_material.shader = shader
	_cloud_material.set_shader_parameter("cloud_texture", _CLOUD_TEXTURE)
	_cloud_material.set_shader_parameter("tex_world_size", _CLOUD_TEXTURE_WORLD_SIZE)
	mi.material_override = _cloud_material
	return mi


func _physics_process(_delta: float) -> void:
	# Push WorldTime.sky_factor into the cloud shader so they tint with the day.
	if _cloud_material != null:
		_cloud_material.set_shader_parameter("sky_factor", WorldTime.sky_factor())


# Fancy 3D box clouds — port of vanilla f.java:c(float). Each cloud cell
# is a 12-block-square × 4-block-tall BOX. Geometry is built once as a
# 6×6 grid of supercells (each supercell = 8×8 cells = 96×96×4 blocks);
# scrolling + visibility per cell come from the shader sampling the cloud
# texture in world-XZ space, NOT from rebuilding the mesh per frame.
#
# Vanilla per-face tint (f.java:698, 706, 713, 732):
#   top    × 1.0   (white-ish — sky cloud color × 1.0)
#   bottom × 0.7   (darker)
#   X side × 0.9
#   Z side × 0.8
# Encoded in vertex COLOR.r so the shader multiplies per-face.
func _build_fancy_cloud_mesh_instance() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.mesh = _build_fancy_cloud_mesh()
	# Custom shader — same WORLD-XZ sampling as the flat-cloud variant
	# but uses the per-vertex COLOR.r as a face brightness modulator
	# (vanilla per-face shading from f.java:c).
	# UV2 carries the cell-center world XZ — emitted identically for all 4
	# verts of each quad so the fragment shader reads ONE constant sample
	# position per face. Without this, fragments at opposite face edges land
	# in different cells (a top face at [x0..x0+12] has its right-edge
	# fragment land at floor((x0+12)/12)=x0/12+1 → the +X neighbor cell),
	# so parts of the face would discard against the wrong cell's alpha and
	# you'd get the "floating sides / missing floors" look.
	# Single-pass cloud shader. The earlier two-pass depth-prepass chain
	# (next_pass with ALPHA=0 pass 1) was unreliable: Godot's renderer can
	# skip the depth write when ALPHA=0 + blend_mix despite depth_draw_always,
	# leaving pass 2 with an empty depth buffer → every overlapping cloud
	# face blended → see-through walls, missing floors. Collapsing to one
	# pass with `cull_back + depth_draw_always + discard` gives us the
	# same depth-sort guarantee without the zero-alpha edge case.
	#
	# How depth_draw_always + cull_back handles cluster sorting:
	#   - cull_back eliminates back-facing faces per camera angle, so from
	#     below only bottom faces rasterize (top is back-culled); from above
	#     only tops; from the side the cluster's outward walls. No coplanar
	#     overlap at cluster-interior boundaries (A's +X wall front-facing
	#     from +X cam, B's back-culled; only A's writes depth).
	#   - discard at c.a < 0.5 kills sparse cells entirely so they don't
	#     pollute depth with invisible ghost boxes.
	#   - For non-adjacent cell fragments that overlap at the same screen
	#     pixel (e.g. distant cell rasterized after closer cell), the closer
	#     one's depth write causes the later one to fail LESS_OR_EQUAL and
	#     skip — exactly what vanilla's glColorMask prepass achieved.
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// cull_disabled matches vanilla f.java:645 (glDisable GL_CULL_FACE).
// Required so the cluster stays opaque from INSIDE: cull_back would
// kill the back-facing far outer wall when the player flies up into the
// cloud layer (y=108-112). The earlier "coplanar flicker" problem is
// moot because the neighbor-cull below discards every back-to-back
// interior wall, so only non-coplanar cluster-edge walls render.
render_mode unshaded, cull_disabled, depth_draw_always, blend_mix;

uniform sampler2D cloud_texture : filter_nearest;
uniform float scroll_offset = 0.0;
uniform float tex_world_size = 3072.0;
uniform float cell_world_size = 12.0;
uniform float sky_factor = 1.0;

varying float v_face_tint;
varying vec2 v_cell_center;
varying vec3 v_face_normal;

void vertex() {
	v_face_tint = COLOR.r;
	v_face_normal = NORMAL;
	// CPU emits cell-center XZ in UV2 (same value for all 4 verts of a
	// quad) so this varying is constant across the face after interpolation.
	vec4 world_center = MODEL_MATRIX * vec4(UV2.x, 0.0, UV2.y, 1.0);
	v_cell_center = world_center.xz;
}

void fragment() {
	vec2 wuv = vec2(v_cell_center.x + scroll_offset, v_cell_center.y) / tex_world_size;
	vec4 c = texture(cloud_texture, fract(wuv));
	// Loose cutoff — vanilla blends the full 0..1 gradient (f.java:c line
	// 698 `is2.a(r, g, b, 0.8f)` with texture modulate, no cutoff).
	if (c.a < 0.01) {
		discard;
	}
	// Interior-wall cull: for SIDE walls only (|normal.y| < 0.5), sample
	// the neighbor cell one cell-width along the outward face normal. If
	// that neighbor is also cloud, this wall is interior to a cluster —
	// discard so the cluster renders as one contiguous 3D slab instead of
	// showing bright vertical stripes between every pair of adjacent cloud
	// cells. Vanilla achieves this via its two-pass depth prepass (closer
	// outer walls occlude interior ones); since our single pass can't do
	// that reliably (depth_draw_always + blend_mix under macOS has edge
	// cases at ALPHA=0), explicit neighbor-cull is the robust equivalent.
	// Top + bottom faces never cull (sky above and below is always empty).
	if (abs(v_face_normal.y) < 0.5) {
		vec2 nb_center = v_cell_center
			+ vec2(v_face_normal.x, v_face_normal.z) * cell_world_size;
		vec4 nc = texture(
			cloud_texture,
			fract(vec2(nb_center.x + scroll_offset, nb_center.y) / tex_world_size)
		);
		if (nc.a >= 0.01) {
			discard;
		}
	}
	float day_tint = mix(0.15, 1.0, sky_factor);
	ALBEDO = c.rgb * v_face_tint * day_tint;
	// Fully opaque — vanilla's literal 0.8 × texture_alpha produces a
	// blend that looks translucent on our hardware: small single-cell
	// clumps lack the two-sided cull_disabled compound-blend boost the
	// bigger clusters get, so each face shows 20% sky through it. Hard-
	// coding 1.0 makes every rendered cell opaque regardless of depth
	// ordering or face count. Slight deviation from vanilla's formula
	// but matches the "solid white 3D rectangles" look of the wiki
	// screenshot much more closely.
	ALPHA = 1.0;
	// Clouds bypass fog — vanilla runs the cloud pass with GL_FOG off.
	FOG = vec4(0.0);
}
"""
	_cloud_material = ShaderMaterial.new()
	_cloud_material.shader = shader
	_cloud_material.set_shader_parameter("cloud_texture", _CLOUD_TEXTURE)
	# Fancy clouds use 12 world blocks per cloud-pixel (vanilla f7=12),
	# so 1 full 256-pixel texture wraps every 12×256 = 3072 blocks.
	_cloud_material.set_shader_parameter("tex_world_size", 12.0 * 256.0)
	# Cell width — interior-wall cull samples one cell-width out along the
	# outward face normal. Must match the F7 constant in _build_fancy_cloud_mesh.
	_cloud_material.set_shader_parameter("cell_world_size", 12.0)
	mi.material_override = _cloud_material
	return mi


# Vanilla f.java:c(float) algorithm — PER-CELL 3D boxes, not per-supercell.
# Each cloud cell is a 12×4×12 box. The 3D look comes from each individual
# cell having its own visible side walls (cell aligned to one cloud-texture
# pixel = 12 blocks square, exactly matching f7 = 12 in vanilla).
#
# We emit a fixed grid of cells (n5*2 supercells × n4 cells/side = 48×48
# cells = 2304 boxes). All 6 faces emitted per cell; side faces sample
# the same texel as the box's body, so they're either fully solid (if
# the cell has cloud) or fully discarded (if not).
#   n4 = 8 (cells per supercell side); n5 = 3 (supercell radius)
#   f7 = 12 (cell size in world blocks); f8 = 4 (cloud box height)
#   Per-face shading from f.java:698, 706, 713, 732 — top×1.0,
#   bottom×0.7, X-sides×0.9, Z-sides×0.8.
func _build_fancy_cloud_mesh() -> ArrayMesh:
	const N4: int = 8
	const N5: int = 3
	const F7: float = 12.0
	const F8: float = 4.0
	const SUPERCELLS_PER_SIDE: int = N5 * 2  # 6
	const CELLS_PER_SIDE: int = N4 * SUPERCELLS_PER_SIDE  # 48
	const HALF: float = float(CELLS_PER_SIDE) * F7 * 0.5  # center the grid on origin
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	# ---- Tops and bottoms: ONE quad per supercell (8×8 cells = 96×96 world
	# blocks) instead of per cell. UV2 per corner = mesh-local XZ, so after
	# shader interpolation + nearest-filter texture sample each fragment
	# reads the texel of the specific cell it falls into. Visually identical
	# to per-cell emission; ~64× fewer top/bottom vertices.
	# Walls stay per-cell below so the neighbor-texel interior cull keeps
	# its per-cell granularity.
	for scz in range(SUPERCELLS_PER_SIDE):
		for scx in range(SUPERCELLS_PER_SIDE):
			var sx0: float = float(scx) * N4 * F7 - HALF
			var sz0: float = float(scz) * N4 * F7 - HALF
			var sx1: float = sx0 + float(N4) * F7
			var sz1: float = sz0 + float(N4) * F7
			# Top (y=F8) — tint 1.0, normal +Y. Per-corner UV2 = world XZ so
			# fragments sample their own cell's texel.
			_emit_cloud_quad_uv2(
				verts,
				uvs,
				uv2s,
				colors,
				normals,
				indices,
				Vector3(sx0, F8, sz1),
				Vector3(sx1, F8, sz1),
				Vector3(sx1, F8, sz0),
				Vector3(sx0, F8, sz0),
				Vector2(sx0, sz1),
				Vector2(sx1, sz1),
				Vector2(sx1, sz0),
				Vector2(sx0, sz0),
				1.0,
				Vector3(0, 1, 0)
			)
			# Bottom (y=0) — tint 0.7, normal -Y.
			_emit_cloud_quad_uv2(
				verts,
				uvs,
				uv2s,
				colors,
				normals,
				indices,
				Vector3(sx0, 0.0, sz0),
				Vector3(sx1, 0.0, sz0),
				Vector3(sx1, 0.0, sz1),
				Vector3(sx0, 0.0, sz1),
				Vector2(sx0, sz0),
				Vector2(sx1, sz0),
				Vector2(sx1, sz1),
				Vector2(sx0, sz1),
				0.7,
				Vector3(0, -1, 0)
			)
	# ---- Walls: per-cell (unchanged) so the shader's neighbor-cull keeps
	# its per-cell sampling. Interior walls discard via the neighbor alpha
	# check; only cluster-edge walls survive, so total wall overdraw is
	# bounded by cluster silhouette — small enough that per-cell emission
	# here isn't worth merging into strips.
	for cz in range(CELLS_PER_SIDE):
		for cx in range(CELLS_PER_SIDE):
			var x0: float = float(cx) * F7 - HALF
			var z0: float = float(cz) * F7 - HALF
			var x1: float = x0 + F7
			var z1: float = z0 + F7
			var center := Vector2(x0 + F7 * 0.5, z0 + F7 * 0.5)
			# -X wall — 0.9× shade. Normal -X (shader samples neighbor at
			# center + normal*F7 = (cx-1, cz) to decide if interior).
			_emit_cloud_quad(
				verts,
				uvs,
				uv2s,
				colors,
				normals,
				indices,
				Vector3(x0, 0.0, z1),
				Vector3(x0, F8, z1),
				Vector3(x0, F8, z0),
				Vector3(x0, 0.0, z0),
				0.9,
				Vector3(-1, 0, 0),
				center
			)
			# +X wall — 0.9× shade. Normal +X.
			_emit_cloud_quad(
				verts,
				uvs,
				uv2s,
				colors,
				normals,
				indices,
				Vector3(x1, 0.0, z0),
				Vector3(x1, F8, z0),
				Vector3(x1, F8, z1),
				Vector3(x1, 0.0, z1),
				0.9,
				Vector3(1, 0, 0),
				center
			)
			# -Z wall — 0.8× shade. Normal -Z.
			_emit_cloud_quad(
				verts,
				uvs,
				uv2s,
				colors,
				normals,
				indices,
				Vector3(x0, 0.0, z0),
				Vector3(x0, F8, z0),
				Vector3(x1, F8, z0),
				Vector3(x1, 0.0, z0),
				0.8,
				Vector3(0, 0, -1),
				center
			)
			# +Z wall — 0.8× shade. Normal +Z.
			_emit_cloud_quad(
				verts,
				uvs,
				uv2s,
				colors,
				normals,
				indices,
				Vector3(x1, 0.0, z1),
				Vector3(x1, F8, z1),
				Vector3(x0, F8, z1),
				Vector3(x0, 0.0, z1),
				0.8,
				Vector3(0, 0, 1),
				center
			)
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Append a single quad (4 verts, 2 triangles) to the cloud mesh arrays.
# Per-vertex face NORMAL is emitted so the cloud shader can sample the
# neighbor cell. UV2 carries the cell-center XZ — identical for all 4
# verts so it interpolates to a constant per-fragment value (every
# fragment of a face samples the SAME texel, which is what makes the
# "is this cell cloud?" decision binary across the whole face).
# gdlint: disable=function-arguments-number
func _emit_cloud_quad(
	verts: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	colors: PackedColorArray,
	normals: PackedVector3Array,
	indices: PackedInt32Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	tint: float,
	normal: Vector3,
	cell_center: Vector2
) -> void:
	var base: int = verts.size()
	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	uvs.append(Vector2(0, 1))
	uvs.append(Vector2(1, 1))
	uvs.append(Vector2(1, 0))
	uvs.append(Vector2(0, 0))
	uv2s.append(cell_center)
	uv2s.append(cell_center)
	uv2s.append(cell_center)
	uv2s.append(cell_center)
	var col := Color(tint, tint, tint, 1.0)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	# CCW winding when viewed from "outside" the box; cull_back keeps
	# the visible side. Verts above are ordered for CCW from outside.
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)


# Supercell top/bottom variant: takes 4 distinct UV2 values (one per
# corner = mesh-local XZ of that corner), so UV2 interpolates across the
# quad and each fragment samples its own world-XZ texel. Used by the
# per-supercell top/bottom emission to stand in for 64 per-cell quads
# with identical visuals. Walls still use _emit_cloud_quad because they
# need a constant cell-center UV2 for the neighbor-texel interior cull.
# gdlint: disable=function-arguments-number
func _emit_cloud_quad_uv2(
	verts: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	colors: PackedColorArray,
	normals: PackedVector3Array,
	indices: PackedInt32Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	uv2_0: Vector2,
	uv2_1: Vector2,
	uv2_2: Vector2,
	uv2_3: Vector2,
	tint: float,
	normal: Vector3
) -> void:
	var base: int = verts.size()
	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	uvs.append(Vector2(0, 1))
	uvs.append(Vector2(1, 1))
	uvs.append(Vector2(1, 0))
	uvs.append(Vector2(0, 0))
	uv2s.append(uv2_0)
	uv2s.append(uv2_1)
	uv2s.append(uv2_2)
	uv2s.append(uv2_3)
	var col := Color(tint, tint, tint, 1.0)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)
