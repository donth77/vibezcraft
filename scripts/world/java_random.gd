class_name JavaRandom
extends RefCounted

# Bit-exact port of java.util.Random (OpenJDK). Same seed + same method
# sequence → byte-identical output as vanilla Java. This is the ground
# truth for any Alpha 1.2.6 worldgen feature: caves, veins, decorators
# all derive from a Random seeded per-chunk (vendor/alpha-1.2.6-src/src/
# dl.java:12-17 shows the per-chunk seeding ritual), and reproducing their
# positions exactly requires the same PRNG.
#
# Algorithm (java.util.Random source, lines paraphrased):
#   CONSTRUCTOR:
#     seed = (inputSeed ^ 0x5DEECE66D) & ((1 << 48) - 1)
#   next(int bits):
#     seed = (seed * 0x5DEECE66D + 0xB) & ((1 << 48) - 1)
#     return (int)(seed >>> (48 - bits))
#   nextInt(int bound):
#     if bound is power of 2: return (int)((bound * (long)next(31)) >> 31)
#     else: rejection-sample with next(31) until bits - val + (bound-1) >= 0
#   nextFloat / nextDouble / nextBoolean / nextLong: derived from next()
#
# GDScript `int` is 64-bit signed. Java's multiplication of two 48-bit
# values fits in 96 bits; we rely on GDScript's wrap-on-overflow (which
# matches Java's signed-int wrap semantics) and immediately mask to 48
# bits, which discards any spurious high-bit garbage. Verified byte-exact
# against known Java output vectors in tests/test_java_random.gd.

const MULTIPLIER: int = 25214903917  # 0x5DEECE66D
const INCREMENT: int = 11  # 0xB
const MASK: int = 281474976710655  # (1 << 48) - 1

var _seed: int = 0


func _init(seed: int = 0) -> void:
	set_seed(seed)


# Equivalent to Java's Random.setSeed(long).
func set_seed(seed: int) -> void:
	_seed = (seed ^ MULTIPLIER) & MASK


# Returns the next `bits` random bits (0..31). Java's Random.next(int).
# Critical detail: Java does (seed * mult + incr) in 64-bit signed long,
# relying on two's-complement wrap. GDScript's `int` is also 64-bit signed,
# BUT the multiplication seed (48 bits) × MULTIPLIER (35 bits) produces a
# 83-bit true product, which exceeds int64's 63-bit safe range and
# corrupts in GDScript (observed: 2nd nextInt() diverging after bit 5469).
# Work around by splitting `seed` into two 24-bit halves so each partial
# product fits in 24+35 = 59 bits, well inside int64. Mathematically:
#     (seed * mult + incr) mod 2^48
#   = ((hi << 24 + lo) * mult + incr) mod 2^48
#   = (lo * mult + ((hi * mult) mod 2^24 << 24) + incr) mod 2^48
func next(bits: int) -> int:
	var seed_lo: int = _seed & 0xFFFFFF  # low 24 bits
	var seed_hi: int = (_seed >> 24) & 0xFFFFFF  # high 24 bits (seed fits in 48)
	var lo_prod: int = seed_lo * MULTIPLIER  # ≤ 2^59 — safe
	var hi_prod_low: int = (seed_hi * MULTIPLIER) & 0xFFFFFF  # keep only low 24 bits
	_seed = (lo_prod + (hi_prod_low << 24) + INCREMENT) & MASK
	return _seed >> (48 - bits)


# Java's Random.nextInt() — uniform int32 in [-2^31, 2^31).
func next_int() -> int:
	return _to_signed_32(next(32))


# Java's Random.nextInt(int bound) — uniform in [0, bound). Power-of-2
# fast path + rejection sampling for arbitrary bounds (OpenJDK source).
func next_int_bounded(bound: int) -> int:
	if bound <= 0:
		push_error("JavaRandom.next_int_bounded: bound must be > 0")
		return 0
	if (bound & -bound) == bound:
		# Power of 2 — exact bijection via 31-bit multiply.
		return (bound * next(31)) >> 31
	var bits: int = next(31)
	var val: int = bits % bound
	# Loop condition from OpenJDK: reject samples that would bias the
	# distribution at the top end of the range.
	while bits - val + (bound - 1) < 0:
		bits = next(31)
		val = bits % bound
	return val


# Java's Random.nextLong() — signed int64.
func next_long() -> int:
	# OpenJDK: (long)next(32) << 32 + next(32). First term is sign-extended
	# to 64 bits, second is treated as unsigned 32 bits.
	var high: int = _to_signed_32(next(32))
	var low: int = next(32)
	return (high << 32) + low


# Java's Random.nextBoolean().
func next_boolean() -> bool:
	return next(1) != 0


# Java's Random.nextFloat() — uniform in [0, 1) with 24-bit precision.
func next_float() -> float:
	return float(next(24)) / 16777216.0


# Java's Random.nextDouble() — uniform in [0, 1) with 53-bit precision.
func next_double() -> float:
	var high: int = next(26)
	var low: int = next(27)
	return float((high << 27) + low) / 9007199254740992.0


# Sign-extend a 32-bit unsigned value to signed int64. Java's nextInt()
# returns a signed int; `next(32)` yields a value in [0, 2^32), and any
# value >= 2^31 represents a negative int32.
static func _to_signed_32(val: int) -> int:
	if val >= 2147483648:
		return val - 4294967296
	return val
