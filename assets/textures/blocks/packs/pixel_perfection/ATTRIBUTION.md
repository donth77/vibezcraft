# PixelPerfectionCE — Attribution

Block textures in this folder are from the **PixelPerfectionCE** Minecraft resource pack (the Community Edition continuation of the original Pixel Perfection pack):

- **Source:** https://github.com/Athemis/PixelPerfectionCE
- **License:** [Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)](https://creativecommons.org/licenses/by-sa/4.0/)
- **Authors:** Athemis and PixelPerfectionCE contributors (see GitHub repo history). Derived from the original Pixel Perfection pack by XSSheep.

## Modifications

Files renamed from upstream PixelPerfectionCE (modern MC 1.13+) naming to this project's Alpha-faithful naming convention:

- `grass_block_top.png` → `grass_top.png`
- `grass_block_side.png` → `grass_side.png`
- `oak_log.png` → `log_side.png`
- `oak_log_top.png` → `log_top.png`
- `oak_planks.png` → `planks.png`
- `oak_leaves.png` → `leaves.png` and `leaves_opaque.png`
- `bricks.png` → `brick.png`
- `bookshelf.png` → `bookshelf_side.png`
- `wheat_stage0..7.png` → `crops_stage_0..7.png`
- `iron_door_bottom/top.png` → `door_iron_lower/upper.png`
- `oak_door_bottom/top.png` → `door_wood_lower/upper.png`
- `poppy.png` → `flower_red.png`
- `dandelion.png` → `flower_yellow.png`
- `jack_o_lantern.png` → `jack_o_lantern_face.png`
- `carved_pumpkin.png` → `pumpkin_face.png`
- `rail_corner.png` → `rail_turn.png`
- `spawner.png` → `mob_spawner.png`
- `brown_mushroom.png` / `red_mushroom.png` → `mushroom_brown.png` / `mushroom_red.png`
- `{color}_wool.png` → `wool_{color}.png`
- All other files (`stone`, `cobblestone`, `dirt`, `sand`, `bedrock`, `obsidian`, `cactus_*`, `clay`, `diamond_block`, `furnace_side`, `gold_block`, `ice`, `iron_block`, `jukebox_*`, `ladder`, `mossy_cobblestone`, `pumpkin_side/top`, `rail`, `slime_block`, `snow`, `sponge`, `stone_slab_*`, `sugar_cane`, `tnt_*`, `torch`) unmodified.

## Tiles not provided by PixelPerfectionCE

Modern MC renders these via entity models, so the upstream pack does not ship per-face block tiles. At runtime BlockAtlas falls back to the `alpha_vanilla` pack for any tile not present here:

- `chest_front/side/top.png` (entity model in modern MC)
- `bed_foot_*` and `bed_head_*` (entity model)
- `painting_atlas.png` (per-painting files; atlas would need rebuilding)

## Required attribution under CC BY-SA 4.0

Per the license, redistribution requires (1) attribution of authors, (2) a link to the license, (3) indication of any changes. **ShareAlike clause:** any derivative work containing these textures must be licensed under CC BY-SA 4.0 or compatible.
