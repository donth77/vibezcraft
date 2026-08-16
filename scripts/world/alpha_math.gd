class_name AlphaMath
extends RefCounted

# Alpha 1.2.6's `fi.java` (MathHelper).
#
# Alpha does not call Math.sin at runtime. It builds a 65536-entry table
# of FLOAT sines once and indexes it with `(int)(angle * 10430.378f) &
# 0xFFFF`. The quantisation is coarse enough to matter: it changes which
# blocks a cave tunnel clips, and it is what gives the portal texture its
# exact swirl.
#
# Extracted here in Batch 7 so the Nether cave generator and the portal
# texture share one table instead of building two. The cave oracle
# fixtures are what prove the extraction changed nothing.

# fi.java:8 — `10430.378f` is a FLOAT literal, so its value is
# 10430.3779296875. Using the double 10430.378 shifts the index near the
# ends of the range.
const SIN_SCALE: float = 10430.3779296875
# fi.java:11 — cosine is the same table a quarter turn along.
const COS_OFFSET: float = 16384.0
const TABLE_SIZE: int = 65536
const MASK: int = 0xFFFF

# Java's `(float)Math.PI`, which is a different number from the double
# PI once it reaches a float expression.
const PI_F32: float = 3.1415927410125732

static var _sin_table: PackedFloat32Array = PackedFloat32Array()


static func _ensure_table() -> void:
	if _sin_table.size() == TABLE_SIZE:
		return
	_sin_table.resize(TABLE_SIZE)
	for i: int in range(TABLE_SIZE):
		# fi.java:56 — built in double precision and stored as float, so
		# the rounding happens once, here.
		_sin_table[i] = sin(float(i) * PI * 2.0 / float(TABLE_SIZE))


# fi.a(float) — sine by table lookup.
static func sin_table(angle: float) -> float:
	_ensure_table()
	return _sin_table[int(f32(f32(angle) * SIN_SCALE)) & MASK]


# fi.b(float) — cosine.
static func cos_table(angle: float) -> float:
	_ensure_table()
	return _sin_table[int(f32(f32(f32(angle) * SIN_SCALE) + COS_OFFSET)) & MASK]


# fi.b(double) — floor toward negative infinity, as an int.
static func floor_int(v: float) -> int:
	var n: int = int(v)
	return n - 1 if v < float(n) else n


# Round a double through float32, matching a Java `float` expression.
#
# Java rounds after EVERY float operation, so callers apply this per
# operation rather than once per expression — the helpers below make that
# readable against the source.
static func f32(v: float) -> float:
	var b := PackedFloat32Array([v])
	return b[0]


static func fmul(a: float, b: float) -> float:
	return f32(a * b)


static func fdiv(a: float, b: float) -> float:
	return f32(a / b)


static func fadd(a: float, b: float) -> float:
	return f32(a + b)


static func fsub(a: float, b: float) -> float:
	return f32(a - b)
