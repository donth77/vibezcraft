class_name Recipes
extends RefCounted

# In-memory recipe registry. Recipes are loaded once at boot from a JSON
# file and matched against a player-supplied input grid.
#
# Input grid is a flat Array[int] of length width*height; each entry is an
# item_id (Blocks.AIR == 0 means an empty cell). match_grid() returns a
# {item_id, count} Dictionary or {} if nothing matches.
#
# Shaped recipes are position-sensitive but the pattern can be located at
# any offset inside the grid (vanilla MC behavior — the wooden pick recipe
# matches in any of 4 positions in a 3x3 grid). Whitespace inside a pattern
# string is significant ("internal" empty cells); leading/trailing empty
# rows + columns are trimmed at load time so the pattern's bounding box is
# what gets slid across the grid.

const _DEFAULT_RECIPES_PATH: String = "res://data/recipes.json"

# Each shaped recipe: {pattern: Array[Array[int]], result_id: int, result_count: int}
# Each shapeless recipe: {ingredients: Array[int], result_id: int, result_count: int}
static var _shaped: Array = []
static var _shapeless: Array = []
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	load_from_json(_DEFAULT_RECIPES_PATH)


static func load_from_json(path: String) -> void:
	_shaped.clear()
	_shapeless.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[Recipes] failed to open " + path)
		return
	var raw: String = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[Recipes] failed to parse JSON at " + path)
		return
	var json: Dictionary = parsed
	for entry: Dictionary in json.get("shaped", []):
		var rec: Dictionary = _parse_shaped(entry)
		if not rec.is_empty():
			_shaped.append(rec)
	for entry: Dictionary in json.get("shapeless", []):
		var rec: Dictionary = _parse_shapeless(entry)
		if not rec.is_empty():
			_shapeless.append(rec)
	_loaded = true


# Matches the input grid against all loaded recipes. Returns the first
# matching result, or {} if none match. Shaped recipes take priority.
static func match_grid(grid: Array, width: int, height: int) -> Dictionary:
	if grid.size() != width * height:
		return {}  # caller bug — return no-match rather than crashing
	for rec: Dictionary in _shaped:
		if _match_shaped(grid, width, height, rec):
			return {"item_id": rec.result_id, "count": rec.result_count}
	for rec: Dictionary in _shapeless:
		if _match_shapeless(grid, rec):
			return {"item_id": rec.result_id, "count": rec.result_count}
	return {}


# --- Internals ---


static func _parse_shaped(entry: Dictionary) -> Dictionary:
	var pattern_strs: Array = entry.get("pattern", [])
	var key: Dictionary = entry.get("key", {})
	var key_ids: Dictionary = {}
	for k: String in key.keys():
		var id: int = Items.id_from_name(key[k])
		if id < 0:
			push_error("[Recipes] unknown ingredient in key: " + str(key[k]))
			return {}
		key_ids[k] = id
	var rows: Array = []
	for s: String in pattern_strs:
		var row: Array = []
		for ch: String in s:
			if ch == " ":
				row.append(Blocks.AIR)
			elif key_ids.has(ch):
				row.append(key_ids[ch])
			else:
				push_error("[Recipes] unknown pattern char '%s' in %s" % [ch, entry.get("id", "?")])
				return {}
		rows.append(row)
	var trimmed: Array = _trim_pattern(rows)
	if trimmed.is_empty():
		return {}
	var result: Dictionary = entry.get("result", {})
	var result_id: int = Items.id_from_name(result.get("id", ""))
	if result_id < 0:
		push_error("[Recipes] unknown result: " + str(result.get("id", "")))
		return {}
	return {
		"pattern": trimmed,
		"result_id": result_id,
		"result_count": int(result.get("count", 1)),
	}


static func _parse_shapeless(entry: Dictionary) -> Dictionary:
	var ingredient_names: Array = entry.get("ingredients", [])
	var ids: Array = []
	for n: String in ingredient_names:
		var id: int = Items.id_from_name(n)
		if id < 0:
			push_error("[Recipes] unknown shapeless ingredient: " + n)
			return {}
		ids.append(id)
	var result: Dictionary = entry.get("result", {})
	var result_id: int = Items.id_from_name(result.get("id", ""))
	if result_id < 0:
		return {}
	return {
		"ingredients": ids,
		"result_id": result_id,
		"result_count": int(result.get("count", 1)),
	}


# Trim leading/trailing empty rows + columns so the pattern's bounding box
# is what we slide across the grid. Internal empties (e.g. " S ") stay.
static func _trim_pattern(rows: Array) -> Array:
	var trimmed: Array = rows.duplicate(true)
	while not trimmed.is_empty() and _row_empty(trimmed[0]):
		trimmed.pop_front()
	while not trimmed.is_empty() and _row_empty(trimmed[-1]):
		trimmed.pop_back()
	if trimmed.is_empty():
		return []
	# Find min/max columns containing any non-empty cell.
	var width: int = 0
	for row: Array in trimmed:
		width = maxi(width, row.size())
	var min_col: int = width
	var max_col: int = -1
	for row: Array in trimmed:
		for c in range(row.size()):
			if row[c] != Blocks.AIR:
				min_col = mini(min_col, c)
				max_col = maxi(max_col, c)
	if max_col < min_col:
		return []
	var out: Array = []
	for row: Array in trimmed:
		var new_row: Array = []
		for c in range(min_col, max_col + 1):
			new_row.append(row[c] if c < row.size() else Blocks.AIR)
		out.append(new_row)
	return out


static func _row_empty(row: Array) -> bool:
	for v: int in row:
		if v != Blocks.AIR:
			return false
	return true


static func _match_shaped(grid: Array, width: int, height: int, rec: Dictionary) -> bool:
	var pattern: Array = rec.pattern
	if pattern.is_empty():
		return false
	var ph: int = pattern.size()
	var pw: int = pattern[0].size()
	if ph > height or pw > width:
		return false
	for off_r in range(height - ph + 1):
		for off_c in range(width - pw + 1):
			if _match_at(grid, width, height, pattern, off_r, off_c):
				return true
	return false


# Verifies the pattern matches at a specific (row, col) offset AND that all
# cells outside the pattern's footprint in the grid are empty. The "outside
# must be empty" check is what prevents a 1x1 recipe from matching whenever
# the right item appears anywhere in a grid that also has other stuff.
static func _match_at(
	grid: Array, width: int, height: int, pattern: Array, off_r: int, off_c: int
) -> bool:
	var ph: int = pattern.size()
	var pw: int = pattern[0].size()
	for r in range(height):
		for c in range(width):
			var grid_id: int = grid[r * width + c]
			var inside_pattern: bool = (
				r >= off_r and r < off_r + ph and c >= off_c and c < off_c + pw
			)
			var expected: int = pattern[r - off_r][c - off_c] if inside_pattern else Blocks.AIR
			if grid_id != expected:
				return false
	return true


# Multiset equality: ignores order, ignores empty cells.
static func _match_shapeless(grid: Array, rec: Dictionary) -> bool:
	var ingredients: Array = rec.ingredients
	var grid_items: Array = []
	for v: int in grid:
		if v != Blocks.AIR:
			grid_items.append(v)
	if grid_items.size() != ingredients.size():
		return false
	grid_items.sort()
	var sorted_ings: Array = ingredients.duplicate()
	sorted_ings.sort()
	for i in range(grid_items.size()):
		if grid_items[i] != sorted_ings[i]:
			return false
	return true
