#!/usr/bin/env python3
# Extract Minecraft Alpha 1.2.6 textures from the vendored client.jar contents
# into a Godot-ready pack at assets/textures/blocks/packs/alpha_vanilla/, the
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
# Alpha's terrain.png stores grass_top and opaque leaves as grayscale
# (Mojang tinted them per-biome at render time). Modern Minecraft still does
# this, but our pack layout expects pre-tinted PNGs so every block can ship
# a single face texture without a tint shader. We hand-apply the vanilla
# default-biome tint here: grass_top → #79C05A, leaves → #48B518.

from PIL import Image
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "vendor" / "mojang" / "alpha-1.2.6"
PACK = ROOT / "assets" / "textures" / "blocks" / "packs" / "alpha_vanilla"
ITEMS = PACK / "items"
ENTITIES = ROOT / "assets" / "textures" / "entities" / "packs" / "alpha_vanilla"

# Vanilla default-biome tints (ColorizerGrass / ColorizerFoliage lookup at
# temperature=0.5, humidity=0.5 — the Alpha spawn biome).
GRASS_TINT = (0x79, 0xC0, 0x5A)
FOLIAGE_TINT = (0x48, 0xB5, 0x18)

# terrain.png — (col, row) in 16×16 tiles. Only blocks we actually use.
TERRAIN_TILES = {
	"grass_top": (0, 0),  # grayscale — tinted below
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
	"leaves": (5, 3),  # grayscale (opaque variant) — tinted below
	"crafting_table_side": (11, 3),
	"crafting_table_front": (12, 3),
	"furnace_front_lit": (13, 3),
	"furnace_top": (14, 3),
}

# Alpha doesn't have farmland (Beta 1.8 added it with hoes). Dirt stands in.
TERRAIN_ALIASES = {
	"farmland": "dirt",
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
}

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


def multiply_tint(img: Image.Image, tint: tuple[int, int, int]) -> Image.Image:
	# Multiply grayscale × tint color — the same math Mojang runs in the
	# tint shader. Alpha channel is preserved from the source.
	out = img.copy()
	px = out.load()
	w, h = out.size
	for y in range(h):
		for x in range(w):
			r, g, b, a = px[x, y]
			px[x, y] = (
				(r * tint[0]) // 255,
				(g * tint[1]) // 255,
				(b * tint[2]) // 255,
				a,
			)
	return out


# grass_side is left raw — Alpha bakes the green strip into the texture
# (unlike grass_top and leaves, which ship grayscale for biome tinting).
# Applying a multiply tint to the whole tile darkens the dirt half.


def main() -> None:
	PACK.mkdir(parents=True, exist_ok=True)
	ITEMS.mkdir(parents=True, exist_ok=True)
	ENTITIES.mkdir(parents=True, exist_ok=True)

	terrain = Image.open(SRC / "terrain.png").convert("RGBA")
	items = Image.open(SRC / "gui" / "items.png").convert("RGBA")
	char = Image.open(SRC / "mob" / "char.png").convert("RGBA")

	for name, (c, r) in TERRAIN_TILES.items():
		img = tile(terrain, c, r)
		if name in ("grass_top", "leaves"):
			img = multiply_tint(img, GRASS_TINT if name == "grass_top" else FOLIAGE_TINT)
		img.save(PACK / f"{name}.png")

	for alias, source in TERRAIN_ALIASES.items():
		src_img = Image.open(PACK / f"{source}.png")
		src_img.save(PACK / f"{alias}.png")

	for name, (c, r) in ITEM_TILES.items():
		tile(items, c, r).save(ITEMS / f"{name}.png")

	for alias, source in ITEM_ALIASES.items():
		src_img = Image.open(ITEMS / f"{source}.png")
		src_img.save(ITEMS / f"{alias}.png")

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

	count = len(TERRAIN_TILES) + len(TERRAIN_ALIASES)
	item_count = len(ITEM_TILES) + len(ITEM_ALIASES)
	print(f"wrote {count} blocks, {item_count} items, 1 steve skin to alpha_vanilla pack")


if __name__ == "__main__":
	main()
