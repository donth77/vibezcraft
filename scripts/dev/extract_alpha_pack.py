#!/usr/bin/env python3
# Extract Minecraft Alpha 1.2.6 textures from the vendored client.jar contents
# into a Godot-ready pack at assets/textures/packs/alpha_vanilla/, the
# per-pack items dir, and the per-pack Steve skin path.
#
# Usage (from repo root):
#   python3 scripts/dev/extract_alpha_pack.py
#
# Inputs (gitignored, not redistributed):
#   vendor/mojang/alpha-1.2.6/terrain.png       — 256×256, 16×16 tiles
#   vendor/mojang/alpha-1.2.6/gui/items.png     — 256×256, 16×16 tiles
#   vendor/mojang/alpha-1.2.6/mob/char.png      — 64×32 Steve skin
#
# Alpha's terrain.png stores grass_top and leaves as grayscale; Mojang
# tinted them per-biome at render time. Both ship GRAYSCALE in this
# pack — the chunk shader applies the tint via `grass_tint` / `leaves_tint`
# instance uniforms (defaults reverse-engineered from a reference
# Alpha-style screenshot, see shaders/chunk.gdshader for the math).
# Per-chunk biome variation (taiga, swamp, jungle) lands later by
# overriding these uniforms without re-running the extractor.
#
# Leaves are taken from terrain.png (4, 3) — the TRANSPARENT variant
# with alpha-tested gaps between leaf clusters (the iconic Alpha foliage
# look). Beta added the "fast" mode that uses the opaque (5, 3) tile;
# Alpha 1.2.6 had no such toggle.

from PIL import Image
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "vendor" / "mojang" / "alpha-1.2.6"
PACK = ROOT / "assets" / "textures" / "blocks" / "packs" / "alpha_vanilla"
ITEMS = PACK / "items"
ENTITIES = ROOT / "assets" / "textures" / "entities" / "packs" / "alpha_vanilla"

# Tint constants live in the chunk shader now — see top-of-file comment +
# shaders/chunk.gdshader's `grass_tint` / `leaves_tint` instance uniforms.

# terrain.png — (col, row) in 16×16 tiles. Only blocks we actually use.
TERRAIN_TILES = {
	"grass_top": (0, 0),  # grayscale — tinted in chunk shader
	"stone": (1, 0),
	"dirt": (2, 0),
	"grass_side": (3, 0),  # pre-baked green strip on top
	"planks": (4, 0),
	"brick": (7, 0),
	"sapling": (15, 0),
	"cobblestone": (0, 1),
	"bedrock": (1, 1),
	"sand": (2, 1),
	"gravel": (3, 1),
	"log_side": (4, 1),
	"log_top": (5, 1),
	"gold_ore": (0, 2),
	"iron_ore": (1, 2),
	"coal_ore": (2, 2),
	"obsidian": (5, 2),
	"crafting_table_top": (11, 2),
	"furnace_front": (12, 2),
	"furnace_side": (13, 2),
	"glass": (1, 3),
	"diamond_ore": (2, 3),
	"leaves": (4, 3),  # grayscale, transparent gaps — tinted in chunk shader
	"crafting_table_side": (11, 3),
	"crafting_table_front": (12, 3),
	"furnace_front_lit": (13, 3),
	"door_wood_upper": (1, 5),
	"door_iron_upper": (2, 5),
	"door_wood_lower": (1, 6),
	"door_iron_lower": (2, 6),
	# Decoration slice 1 — flowers + mushrooms (positions stable since Alpha).
	"flower_red": (12, 0),
	"flower_yellow": (13, 0),
	"mushroom_red": (12, 1),
	"mushroom_brown": (13, 1),
	# Pumpkins (Alpha 1.2.0 Halloween Update). 4 tiles:
	#   pumpkin_top  (6, 6) — stem-up disc, shared with bottom face
	#   pumpkin_side (6, 7) — plain ribbed panel for the 3 non-face sides
	#   pumpkin_face (7, 7) — carved face, dark interior (unlit)
	#   jack_o_lantern_face (8, 7) — same cut, yellow glow inside (lit)
	"pumpkin_top": (6, 6),
	"pumpkin_side": (6, 7),
	"pumpkin_face": (7, 7),
	"jack_o_lantern_face": (8, 7),
	# Bookshelf [BETA 1.3 exception] — block added Feb 2011, after Alpha
	# 1.2.6 freeze, but the texture slot at (3, 2) was reserved in Alpha
	# terrain.png already (verified by tile inspection). Faces: top +
	# bottom use planks (4, 0); the 4 sides use this bookshelf_side tile.
	# Ships here because books are otherwise useless until enchanting
	# (Beta 1.9) and decorating with a shelf gives the item a purpose now.
	"bookshelf_side": (3, 2),
	# Classic-era solid blocks. Iron/gold/diamond at row 1; sponge at
	# (0, 3); wool white at (0, 4). Colored wools are procedurally
	# tinted below since Alpha 1.2.6 only had the white tile.
	"iron_block": (6, 1),
	"gold_block": (7, 1),
	"diamond_block": (8, 1),
	"sponge": (0, 3),
	"wool_white": (0, 4),
	# Clay block — vanilla lj.java spawns from WorldGenClay (hy.java)
	# at terrain.png index 72 = (8, 4). Mid-gray-blue, light texture
	# variation gives it a "clay deposit" look in lakes / beaches.
	"clay": (8, 4),
	# Stone slab — vanilla qj.java::a(int n2) returns 6 for top/bottom
	# face (= terrain.png (6, 0)) and 5 for sides (= (5, 0)). The side
	# tile has a baked bevel line so the half-slab variant reads
	# correctly when stretched vertically.
	"stone_slab_top": (6, 0),
	"stone_slab_side": (5, 0),
	# Crop growth stages (BlockCrops, vanilla nq.az). 8 sprites at
	# terrain.png row 5, cols 8..15 (vanilla terrain.png convention).
	# Stage 0 is mostly transparent (tiny sprouts); stage 7 is mature
	# wheat. The mesher swaps the sprite per cell meta — see
	# scripts/world/mesher.gd::_emit_cross_quads.
	"crops_stage_0": (8, 5),
	"crops_stage_1": (9, 5),
	"crops_stage_2": (10, 5),
	"crops_stage_3": (11, 5),
	"crops_stage_4": (12, 5),
	"crops_stage_5": (13, 5),
	"crops_stage_6": (14, 5),
	"crops_stage_7": (15, 5),
	# `furnace_top` is intentionally NOT here. Vanilla Alpha 1.2.6
	# BlockFurnace.getBlockTextureFromSide (mj.java:46-52) returns
	# `nq.t.bg` (= the STONE texture index) for both top (n5=1) and
	# bottom (n5=0) faces — there's no separate furnace_top tile in
	# Alpha terrain.png. Earlier this script pointed at (14, 3) which is
	# empty/magenta in the vendored Alpha atlas. Aliased to "stone"
	# below; matches vanilla rendering exactly.
}

# Alpha doesn't have farmland (Beta 1.8 added it with hoes). Dirt stands in.
TERRAIN_ALIASES = {
	"farmland": "dirt",
	# Vanilla Alpha 1.2.6 BlockFurnace renders top + bottom faces with the
	# STONE texture (mj.java:46-52 returns nq.t.bg). No separate furnace_top
	# tile exists in Alpha terrain.png — Beta added that later.
	"furnace_top": "stone",
}

# items.png — tool tiers at columns (wood, stone, iron, diamond, gold).
# Armor tiers match items.gd (iron/gold/diamond only — leather & chain unused).
#
# Tool row layout (verified against Alpha 1.2.6 items.png by shape):
#   row 4 = sword, 5 = shovel, 6 = pickaxe, 7 = axe, 8 = hoe.
# An earlier version of this script had sword at row 5 and shovel at row 8,
# which produced pack files where every *_sword.png held a shovel sprite.
ITEM_TILES = {
	"wooden_sword": (0, 4),
	"stone_sword": (1, 4),
	"iron_sword": (2, 4),
	"diamond_sword": (3, 4),
	"gold_sword": (4, 4),
	"wooden_shovel": (0, 5),
	"stone_shovel": (1, 5),
	"iron_shovel": (2, 5),
	"diamond_shovel": (3, 5),
	"gold_shovel": (4, 5),
	"wooden_pickaxe": (0, 6),
	"stone_pickaxe": (1, 6),
	"iron_pickaxe": (2, 6),
	"diamond_pickaxe": (3, 6),
	"gold_pickaxe": (4, 6),
	"wooden_axe": (0, 7),
	"stone_axe": (1, 7),
	"iron_axe": (2, 7),
	"diamond_axe": (3, 7),
	"gold_axe": (4, 7),
	"wooden_hoe": (0, 8),
	# Materials:
	"coal": (7, 0),
	"iron_ingot": (7, 1),
	"gold_ingot": (7, 2),
	"diamond": (7, 3),
	"stick": (5, 3),
	"flint": (6, 0),
	# Vanilla Alpha 1.2.6 items.png row 0: leather/chain/iron/diamond/gold
	# helmets at cols 0-4, then flint_and_steel at col 5, flint at col 6,
	# coal at col 7. Verified by visual inspection of the vendored items.png.
	"flint_and_steel": (5, 0),
	"wooden_door": (11, 2),
	"iron_door": (12, 2),
	"leather": (7, 5),
	# Armor: rows 0=helmet, 1=chest, 2=legs, 3=boots; col 2=iron, 3=diamond, 4=gold.
	"iron_helmet": (2, 0),
	"diamond_helmet": (3, 0),
	"gold_helmet": (4, 0),
	"iron_chestplate": (2, 1),
	"diamond_chestplate": (3, 1),
	"gold_chestplate": (4, 1),
	"iron_leggings": (2, 2),
	"diamond_leggings": (3, 2),
	"gold_leggings": (4, 2),
	"iron_boots": (2, 3),
	"diamond_boots": (3, 3),
	"gold_boots": (4, 3),
	# Redstone dust — Alpha 1.2.6 items.png (col=8, row=3). Static sprite
	# in inventory; the powered/path connection rendering is a worldgen
	# block job, deferred until we ship the redstone power system.
	"redstone": (8, 3),
	# Clock base — items.png (col=6, row=4). Per dx.aQ(91).a(70) the clock
	# icon lives at items.png index 70 = (6, 4). Carries the magenta marker
	# pixels (R==B, G==0, R>0) that vanilla gp.java substitutes with rotated
	# dial samples to animate the sun/moon disc — see item_icons.gd.
	"clock": (6, 4),
	# Compass base — items.png (col=6, row=3). Per dx.aO(89).a(54) the
	# compass icon lives at items.png index 54 = (6, 3). Plain circular
	# bezel; vanilla ae.java draws the red/gray needle on top each frame
	# (see _render_compass_icon). Earlier extraction had this at (12, 4)
	# which is actually the lava_bucket sprite — overwriting it broke the
	# lava bucket icon.
	"compass": (6, 3),
	# Food + crafting materials added in Indev/Alpha. Tile positions
	# verified against dx.java item registrations (where `.a(N)` is the
	# items.png 16×16 sprite index, N = row*16 + col):
	#   apple           dx.h(4,4).a(10)   → (10, 0)   Indev
	#   bow             dx.i(5).a(21)     → (5, 1)    Indev
	#   arrow           dx.j(6).a(37)     → (5, 2)    Indev
	#   wheat_seeds     dx.Q(39).a(9)     → (9, 0)    Indev
	#   wheat           dx.R(40).a(25)    → (9, 1)    Indev
	#   bread           dx.S(41).a(41)    → (9, 2)    Indev
	#   leather_*       dx.T..W           → (0, 0..3) Indev
	#   raw_porkchop    dx.ao(63,3).a(87) → (7, 5)    Indev
	#   cooked_porkchop dx.ap(64,8).a(88) → (8, 5)    Indev
	#   golden_apple    dx.ar(66,42).a(11)→ (11, 0)   Infdev
	#   saddle          dx.ay(73).a(104)  → (8, 6)    Infdev (loot only)
	#   snowball        dx.aB(76).a(14)   → (14, 0)   Alpha v1.0.4
	#   milk_bucket     dx.aE(79).a(77)   → (13, 4)   Alpha v1.0.5
	#   brick           dx.aF(80).a(22)   → (6, 1)    Alpha v1.0.6
	#   clay_ball       dx.aG(81).a(57)   → (9, 3)    Alpha v1.0.6
	#   paper           dx.aI(83).a(58)   → (10, 3)   Alpha v1.0.6
	#   book            dx.aJ(84).a(59)   → (11, 3)   Alpha v1.0.6
	#   slimeball       dx.aK(85).a(30)   → (14, 1)   Alpha v1.0.11
	#   egg             dx.aN(88).a(12)   → (12, 0)   Alpha v1.0.14
	#   fishing_rod     dx.aP(90).a(69)   → (5, 4)    Alpha v1.0.17
	#   raw_fish        dx.aS(93,2).a(89) → (9, 5)    Alpha v1.0.16
	#   cooked_fish     dx.aT(94,5).a(90) → (10, 5)   Alpha v1.0.16
	#   string          dx.I(31).a(8)     → (8, 0)    Indev
	#   feather         dx.J(32).a(24)    → (8, 1)    Indev
	#   bowl            dx.C(25).a(71)    → (7, 4)    Indev
	#   mushroom_stew   dx.D(26,10).a(72) → (8, 4)    Indev
	"apple": (10, 0),
	"wheat_seeds": (9, 0),
	"wheat": (9, 1),
	"bread": (9, 2),
	"leather_helmet": (0, 0),
	"leather_chestplate": (0, 1),
	"leather_leggings": (0, 2),
	"leather_boots": (0, 3),
	"raw_porkchop": (7, 5),
	"cooked_porkchop": (8, 5),
	"golden_apple": (11, 0),
	"saddle": (8, 6),
	"brick_item": (6, 1),
	"paper": (10, 3),
	"book": (11, 3),
	"string": (8, 0),
	"feather": (8, 1),
	"bowl": (7, 4),
	"mushroom_stew": (8, 4),
	# Fishing — Alpha v1.0.16 (raw/cooked fish) + v1.0.17 (fishing rod).
	# dx.aP(90).a(69), dx.aS(93,2).a(89), dx.aT(94,5).a(90).
	"fishing_rod": (5, 4),
	"raw_fish": (9, 5),
	"cooked_fish": (10, 5),
	# Mob drops + Beta sugar.
	#   egg          dx.aN(88).a(12)  → (12, 0) Alpha v1.0.14 (chicken)
	#   milk_bucket  dx.aE(79).a(77)  → (13, 4) Alpha v1.0.5 (right-click cow)
	#   sugar        Beta 1.2 — sprite at items.png (13, 0); 1 sugar_cane → 1 sugar
	"egg": (12, 0),
	"milk_bucket": (13, 4),
	"sugar": (13, 0),
	# Clay ball — vanilla dx.aG(81).a(57) → items.png index 57 = (9, 3).
	# Drops 4 per clay-block break; smelts 1:1 into brick item.
	"clay_ball": (9, 3),
	# Sign item — vanilla dx.as(67).a(42) → items.png index 42 = (10, 2).
	# Wooden sign sprite; placed by right-clicking a face.
	"sign": (10, 2),
	# Boat item — vanilla ItemBoat (id 333). Sprite at items.png tile
	# (8, 8) — a side-view wooden hull. Tile (8, 6) is the SADDLE
	# (Infdev-era), which looks superficially similar (brown 16×16 hull-
	# ish shape) and was mistakenly used here before. Verified against
	# vendor/mojang/alpha-1.2.6/gui/items.png.
	"boat": (8, 8),
	# Gunpowder — vanilla Alpha dx.K(33).a(40) → sprite 40 = (8, 2).
	# The existing assets/textures/items/gunpowder.png was extracted
	# from (7, 8) which is actually MINECART, so the inventory icon
	# was wrong. This entry overrides via the per-pack items dir
	# (item_icons.gd's _load_item_sprite tries the pack dir FIRST,
	# then falls back to assets/textures/items/).
	"gunpowder": (8, 2),
	# Slimeball — vanilla dx.aK(85).a(30) → sprite 30 = (14, 1).
	# Dropped by size-1 slimes only (vanilla ns.java::g_()).
	"slimeball": (14, 1),
}

# Items added in Beta+ that don't have an Alpha 1.2.6 sprite. Drawn
# procedurally below at `main` time so they at least get a recognizable
# inventory icon instead of an empty TextureRect.
PROCEDURAL_ITEMS: dict = {
	# Sugar — Beta 1.2. White granules approximation: solid white centered
	# on a transparent 16×16, with a slight off-white speckle for texture.
	# Replace with vendored Beta sprite when we have one.
	"sugar": "sugar_white_granules",
}

# Procedural terrain tiles — same idea but emitted into the pack dir
# (next to the rest of terrain.png extractions), not into items/.
# (tall_grass entry removed — Beta 1.6 block, not Alpha 1.2.6)
#
# Wool — Alpha 1.2.6 had ONE wool tile (white) plus 16 meta values
# in nq.ab (BlockCloth), but the colored variant TEXTURES weren't
# added until Beta 1.2 (along with the dye system). We tint the
# white wool with vanilla MC's per-color dye constants to produce
# the missing 15 tiles. White is extracted direct (no proc).
PROCEDURAL_TERRAIN: dict = {
	# Vanilla BlockCloth color RGB constants (Beta 1.2 EnumDyeColor).
	# Indexed by meta value 1..15 — 0 is white (extracted from terrain
	# directly, no tinting).
	"wool_orange": (0xE0, 0x6D, 0x29),  # meta 1
	"wool_magenta": (0xBE, 0x49, 0xC8),  # meta 2
	"wool_light_blue": (0x6B, 0x8A, 0xC9),  # meta 3
	"wool_yellow": (0xB7, 0xAE, 0x21),  # meta 4
	"wool_lime": (0x40, 0xC6, 0x33),  # meta 5
	"wool_pink": (0xD0, 0x80, 0x9A),  # meta 6
	"wool_gray": (0x42, 0x42, 0x42),  # meta 7
	"wool_light_gray": (0x9A, 0xA0, 0xA0),  # meta 8
	"wool_cyan": (0x27, 0x6A, 0x88),  # meta 9
	"wool_purple": (0x7D, 0x2F, 0xB1),  # meta 10
	"wool_blue": (0x2F, 0x36, 0x99),  # meta 11
	"wool_brown": (0x57, 0x33, 0x1B),  # meta 12
	"wool_green": (0x36, 0x51, 0x1B),  # meta 13
	"wool_red": (0xA2, 0x2D, 0x29),  # meta 14
	"wool_black": (0x1A, 0x16, 0x16),  # meta 15
}


def _tint_white_wool(white_img: "Image.Image", tint: tuple) -> "Image.Image":
	"""Multiply the white-wool tile's RGB by the dye tint, per-pixel.
	Alpha 1.2.6 (and modern MC) does the same multiply via shader at
	render time for biome-tinted blocks; doing it at extract time
	keeps the runtime free of biome-tint plumbing for wool.
	"""
	out = Image.new("RGBA", white_img.size)
	px = out.load()
	src = white_img.load()
	for y in range(white_img.height):
		for x in range(white_img.width):
			r, g, b, a = src[x, y]
			# Normalize white to 1.0 then multiply by tint. The white
			# wool tile has slight per-pixel variation (the "weave"
			# texture) which the multiply preserves as luminance
			# variation in the tinted result.
			lum = r / 255.0  # white-ish, R≈G≈B; pick R as luminance
			px[x, y] = (
				int(tint[0] * lum),
				int(tint[1] * lum),
				int(tint[2] * lum),
				a,
			)
	return out


def _draw_sugar() -> Image.Image:
	"""Canonical Beta-era sugar sprite — diamond-shaped pile of white
	granules with a 1-px dark outline and right-side shadow. Pixel-for-
	pixel reproduction of Mojang's items/sugar.png (taken from MC 1.6.4,
	unchanged since Beta 1.2 added the item). The earlier 8×7 white block
	read as a generic "tile" in the inventory and was indistinguishable
	from bone meal at a glance."""
	D = (84, 84, 104, 255)   # outline
	b = (185, 185, 203, 255) # heavy shadow
	l = (213, 213, 223, 255) # mid shadow
	L = (234, 234, 234, 255) # near-white
	W = (255, 255, 255, 255) # highlight
	N = (0, 0, 0, 0)         # transparent
	M = {'.': N, 'D': D, 'b': b, 'l': l, 'L': L, 'W': W}
	rows = [
		"................",
		"................",
		"................",
		".......DD.......",
		"......DWlD......",
		".....DWWllD.....",
		"....DLWLLllD....",
		"...DWWLWWlblD...",
		"..DWLLWWLLlblD..",
		"..DWLWWLWWlblD..",
		"..DlWWLLWbllbD..",
		"...DllWWllbbD...",
		"....DDllblDD....",
		"......DDDD......",
		"................",
		"................",
	]
	img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
	px = img.load()
	for y, row in enumerate(rows):
		for x, ch in enumerate(row):
			px[x, y] = M[ch]
	return img

# Items with no Alpha 1.2.6 source — fall back by aliasing another sprite.
ITEM_ALIASES = {
	"charcoal": "coal",  # added in Beta 1.2
}


def tile(atlas: Image.Image, col: int, row: int) -> Image.Image:
	return atlas.crop((col * 16, row * 16, col * 16 + 16, row * 16 + 16))


def _flip_h(img: Image.Image) -> Image.Image:
	return img.transpose(Image.FLIP_LEFT_RIGHT)


def _mirror_limb_block(arm: Image.Image) -> Image.Image:
	# Takes a 16×16 right-arm (or right-leg) block from the skin and returns
	# the matching left-limb block. The 16×16 block is laid out as:
	#   rows 0–3 : top cap (cols 4–7) + bottom cap (cols 8–11)
	#   rows 4–15: side faces — right (cols 0–3), front (cols 4–7),
	#              left (cols 8–11), back (cols 12–15)
	# Mirroring a whole block horizontally is wrong: it puts the back face
	# where the right face should be. Vanilla mirrors each face within its
	# own region: caps flip horizontally in place, front/back flip in place,
	# and left/right faces swap with each other (outside↔inside) since the
	# left limb's outside face corresponds to the right limb's outside face
	# but reflected.
	m = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
	# Top cap (cols 4–7, rows 0–3) — flip in place.
	m.paste(_flip_h(arm.crop((4, 0, 8, 4))), (4, 0))
	# Bottom cap (cols 8–11, rows 0–3) — flip in place.
	m.paste(_flip_h(arm.crop((8, 0, 12, 4))), (8, 0))
	# Right face (outside of right limb) → Left face (outside of left limb).
	m.paste(_flip_h(arm.crop((0, 4, 4, 16))), (8, 4))
	# Front face — flip in place.
	m.paste(_flip_h(arm.crop((4, 4, 8, 16))), (4, 4))
	# Left face (inside of right limb) → Right face (inside of left limb).
	m.paste(_flip_h(arm.crop((8, 4, 12, 16))), (0, 4))
	# Back face — flip in place.
	m.paste(_flip_h(arm.crop((12, 4, 16, 16))), (12, 4))
	return m


# grass_side is left raw — Alpha bakes the green strip into the texture
# (unlike grass_top and leaves, which ship grayscale for biome tinting).
# Applying a multiply tint to the whole tile darkens the dirt half.


def main() -> None:
	PACK.mkdir(parents=True, exist_ok=True)
	ITEMS.mkdir(parents=True, exist_ok=True)
	ENTITIES.mkdir(parents=True, exist_ok=True)
	# Leather armor textures — vanilla Alpha names them cloth_{1,2}.png
	# (the armor was originally called "Studded Leather"). Pulled into
	# our armor dir as leather_layer_{1,2}.png to match item-id naming.
	# We extract once and only re-copy if the source jar is present,
	# since this lives in vendor/ which is git-ignored.
	armor_dst = ROOT / "assets" / "textures" / "entities" / "armor"
	armor_dst.mkdir(parents=True, exist_ok=True)
	jar = SRC / "client.jar"
	if jar.exists():
		import zipfile
		with zipfile.ZipFile(jar) as zf:
			for src, dst in [("armor/cloth_1.png", "leather_layer_1.png"),
								("armor/cloth_2.png", "leather_layer_2.png")]:
				try:
					(armor_dst / dst).write_bytes(zf.read(src))
				except KeyError:
					pass  # jar variant without that file — skip silently

	terrain = Image.open(SRC / "terrain.png").convert("RGBA")
	items = Image.open(SRC / "gui" / "items.png").convert("RGBA")
	char = Image.open(SRC / "mob" / "char.png").convert("RGBA")

	for name, (c, r) in TERRAIN_TILES.items():
		img = tile(terrain, c, r)
		# grass_top + leaves both ship grayscale — tinted at render time in
		# chunk.gdshader via `grass_tint` / `leaves_tint` instance uniforms.
		img.save(PACK / f"{name}.png")

	for alias, source in TERRAIN_ALIASES.items():
		src_img = Image.open(PACK / f"{source}.png")
		src_img.save(PACK / f"{alias}.png")

	for name, (c, r) in ITEM_TILES.items():
		tile(items, c, r).save(ITEMS / f"{name}.png")

	for alias, source in ITEM_ALIASES.items():
		src_img = Image.open(ITEMS / f"{source}.png")
		src_img.save(ITEMS / f"{alias}.png")

	# Procedural items — Beta-era additions with no Alpha sprite source.
	# Drawn locally so the pack still gets a recognizable icon. Each
	# generator below returns a 16×16 PIL Image written to ITEMS/.
	for name in PROCEDURAL_ITEMS:
		if name == "sugar":
			_draw_sugar().save(ITEMS / f"{name}.png")

	# Procedural terrain tiles — currently only the 15 colored wools
	# (tinted from the white wool tile we just extracted to PACK/).
	white_wool_path = PACK / "wool_white.png"
	if white_wool_path.exists():
		white_wool = Image.open(white_wool_path).convert("RGBA")
		for name, tint in PROCEDURAL_TERRAIN.items():
			if name.startswith("wool_"):
				_tint_white_wool(white_wool, tint).save(PACK / f"{name}.png")

	# Alpha's Steve skin is 64×32 — the left arm and left leg don't exist in
	# the texture; the game renders them by mirroring the right side. Our
	# character_model.gd targets post-1.8 64×64 skins which have distinct
	# left-limb pixels, so we materialize them here. Same algorithm as
	# vanilla's ImageBufferDownload legacy conversion: per-face mirror, not
	# whole-block flip (a whole-block flip scrambles face regions because
	# "right face" and "left face" swap positions in the mirror).
	upgraded = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
	upgraded.paste(char, (0, 0))
	right_arm = char.crop((40, 16, 56, 32))
	upgraded.paste(_mirror_limb_block(right_arm), (32, 48))
	right_leg = char.crop((0, 16, 16, 32))
	upgraded.paste(_mirror_limb_block(right_leg), (16, 48))
	upgraded.save(ENTITIES / "steve.png")

	# Bobber sprite — vanilla jw.java (RenderFish) pulls an 8×8 tile from
	# particles.png at (col=1, row=2) = pixel (8, 16)→(16, 24). Sprite is
	# the bobber body (white + red stripe) plus the trailing fishing line
	# below. Rendered in vanilla as a 0.5-m camera-facing billboard.
	particles_path = SRC / "particles.png"
	if not particles_path.exists():
		# Some Alpha mirrors put particles.png inside the jar only.
		jar = SRC / "client.jar"
		if jar.exists():
			import zipfile
			with zipfile.ZipFile(jar) as zf:
				try:
					particles_data = zf.read("particles.png")
					(SRC / "particles.png").write_bytes(particles_data)
				except KeyError:
					particles_data = None
	if particles_path.exists():
		particles = Image.open(particles_path).convert("RGBA")
		particles.crop((8, 16, 16, 24)).save(ENTITIES / "bobber.png")

	count = len(TERRAIN_TILES) + len(TERRAIN_ALIASES)
	item_count = len(ITEM_TILES) + len(ITEM_ALIASES)
	print(f"wrote {count} blocks, {item_count} items, 1 steve skin to alpha_vanilla pack")


if __name__ == "__main__":
	main()
