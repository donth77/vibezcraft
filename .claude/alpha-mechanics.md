# Minecraft Alpha (2010) Mechanics Reference

Authoritative-as-we-can-make-it reference for how Java Edition Alpha actually behaved. Used as the source of truth when implementing block, mob, and inventory mechanics in our clone. If you find a contradiction with this doc and the wiki, **the wiki is right** — please update this file.

Period covered: **June 2010 → December 2010** (Alpha v1.0.0 → Alpha v1.2.0_02).

---

## Block break drops

What you get when you break each block, with bare hands or appropriate tool. **Alpha had no Silk Touch (added Beta 1.4) and no Fortune (also Beta 1.4)** — so no enchant-based variations.

| Block | Drop | Tool requirement | Notes |
|---|---|---|---|
| **Stone** | 1 cobblestone | Wood+ pickaxe | No drop without a pickaxe |
| **Cobblestone** | 1 cobblestone | Pickaxe | |
| **Dirt** | 1 dirt | Any (shovel fastest) | |
| **Grass block** | **1 dirt** | Any | No way to get grass-as-grass in Alpha |
| **Sand** | 1 sand | Any (shovel fastest) | Falls under gravity |
| **Gravel** | **1 gravel OR 1/10 chance of flint** | Any | Flint chance since Indev (Feb 2010) |
| **Oak log** | 1 log | Any (axe fastest) | Only oak in Alpha |
| **Planks** (oak) | 1 planks | Any (axe fastest) | Crafted, not generated |
| **Leaves** | **1/20 chance of sapling**, else nothing | Any (shears didn't exist yet) | Apples NOT from leaves in Alpha (added Beta 1.1). Decay if disconnected from a log. |
| **Bedrock** | nothing | unbreakable in survival | |
| **Coal ore** | 1 coal | Wood+ pickaxe | |
| **Iron ore** | 1 iron ore (smelt → iron ingot) | Stone+ pickaxe | |
| **Gold ore** | 1 gold ore (smelt → gold ingot) | Iron+ pickaxe | |
| **Diamond ore** | 1 diamond | Iron+ pickaxe | |
| **Redstone ore** | **4–5 redstone dust** | Iron+ pickaxe | Added Alpha v1.0.14 |
| **Snow block** | **4 snowballs** | Shovel | Added Alpha v1.0.14 |
| **Snow layer** | 1 snowball per layer | Shovel | |
| **Clay block** | **4 clay balls** | Any | |
| **Glass** | **nothing** | Any | No Silk Touch — block is lost on break |
| **Obsidian** | 1 obsidian | Diamond pickaxe (long break) | |
| **Brick block** | 1 brick block | Pickaxe | |
| **TNT** | doesn't drop, just gets activated | — | |
| **Crafting table** | 1 crafting table | Any (axe fastest) | |
| **Furnace** | 1 furnace | Pickaxe | |
| **Chest** | 1 chest + scattered contents | Any (axe fastest) | |
| **Ladder** | 1 ladder | Any (axe fastest) | |
| **Torch** | 1 torch | Any | |
| **Cactus** | 1 cactus per block | Any | |
| **Reeds** (sugar cane) | 1 reed per block | Any | |
| **Pumpkin** (Alpha v1.2.0+) | 1 pumpkin | Any (axe fastest) | |
| **Jack o'lantern** (v1.2.0+) | 1 jack o'lantern | Any (axe fastest) | |
| **Glowstone** (v1.2.0+) | **1 glowstone dust per block** | Any | Modern is 2–4; Alpha was 1 |
| **Netherrack** (v1.2.0+) | 1 netherrack | Pickaxe | |
| **Soul sand** (v1.2.0+) | 1 soul sand | Any (shovel fastest) | |

### NOT in Alpha (correcting common misconceptions)

- **Lapis lazuli ore** — added Beta 1.2 (January 2011), not Alpha
- **Silk Touch** — Beta 1.4 (September 2011)
- **Fortune** — Beta 1.4
- **Apples from leaves** — Beta 1.1
- **Hunger bar** — Beta 1.8

---

## Tool tier hierarchy & break mechanics

### Mining tier

| Tier | Mines | Doesn't mine |
|---|---|---|
| Wood / Gold pickaxe | stone, coal | iron, gold, diamond, redstone, obsidian |
| Stone pickaxe | + iron | gold, diamond, redstone, obsidian |
| Iron pickaxe | + gold, diamond, redstone | obsidian (technically yes — but takes ~250 sec; diamond pick is the practical tool) |
| Diamond pickaxe | + obsidian | — |

### The two key rules

1. **Wrong tool tier = block still breaks, drops nothing.** Mining stone with bare hands "works" — it takes forever and produces no cobblestone. Same with mining iron ore with a wood pickaxe.
2. **Wrong tool kind = much slower, but drops still happen.** Mining a log with a pickaxe is slow but you still get the log. Mining stone with a shovel is slow but you still get cobble (assuming the pickaxe-tier check passes — which for stone it does at any pickaxe tier).

### Tool break-speed multipliers (relative to bare hand)

- **Bare hand: 1×** baseline
- Wood: 2×
- Stone: 4×
- Iron: 6×
- Gold: 12× (fast but low durability — niche)
- Diamond: 8×

**Break-time formula** (Alpha-canonical): `time_seconds = block_hardness × 1.5 / tool_speed_multiplier` *(when the right tool kind is used)*. Wrong kind: `× 5.0` instead of `× 1.5`.

### Tool kinds → block matchups

| Tool kind | "Correct" for |
|---|---|
| Pickaxe | stone, cobblestone, ores, iron block, gold block, brick, obsidian, glowstone, ice |
| Axe | logs, planks, crafting table, chest, furnace, ladder, wooden door, jukebox, note block, bookshelf |
| Shovel | dirt, grass, sand, gravel, snow, clay, soul sand, mycelium |
| Sword | webs (faster), in combat |
| Bare hand | works on dirt/wood/sand/gravel/leaves (any "soft" block); slow on hard blocks; produces no drops on tier-gated blocks |

### Tool durability (uses)

- Wood: 60
- Gold: 33
- Stone: 132
- Iron: 251
- Diamond: 1562

Each block-break = 1 use. Combat hits cost 2 uses on swords, 1 on others. **Durability is a Phase 5+ stretch — first pass treats tools as infinite.**

### Block hardness sample (in seconds, bare-hand baseline)

- Dirt / sand / gravel: 0.5
- Grass / clay: 0.6
- Wood log / planks: 2.0 (axe much faster)
- Leaves: 0.2 (no tool needed)
- Stone / cobble / ores: 1.5 (needs pickaxe to drop)
- Iron block: 5.0
- Gold / diamond block: 3.0
- Obsidian: **50.0** (only diamond pick produces drop)
- Bedrock: ∞ (unbreakable)

### Break-progress visuals

- **Crack overlay** appears on the block face being mined as you hold LMB
- 10 stages: empty → fully cracked, advancing as `current_time / total_break_time`
- Cracks reset to empty if you let go of LMB or look at a different block
- Vanilla MC plays the dig sound on a loop (~3 hits/sec) during the break, plus a final break sound on completion

---

## Inventory layout

- **40 slots total** (Alpha-specific): 4 armor + 27 storage + **9 hotbar** = 40
  - In Beta and later, this is 36 (the extra slot is the crafting result slot, which Alpha showed in inventory)
- Stack size: **64** for most items, **1** for tools/armor, **16** for snowballs/eggs/signs

---

## Combat & health

- Health: **10 hearts = 20 HP**
- **No hunger bar** in Alpha (added Beta 1.8). Health regenerates passively over time.
- Damage values:
  - Bare fist: 1 (½ heart)
  - Wood sword: 4
  - Stone sword: 5
  - Iron sword: 6
  - Diamond sword: 7
  - Gold sword: 4 (same as wood)
  - Fall damage: 1 per block above 3-block fall
  - Drowning: 2 per second after suffocation timer
  - Lava: 4 per half-second + on fire
  - Fire: 1 per half-second

---

## Mob drops (Alpha-era roster)

Passive:
- **Pig** — 0–2 raw porkchop (cooked if killed by fire)
- **Cow** — 0–2 leather (no beef yet — added Beta 1.8)
- **Chicken** — 0–2 feather (no raw chicken yet — Beta 1.8)
- **Sheep** — 1 wool block of body color
- **Squid** — 1–3 ink sac

Hostile (overworld):
- **Zombie** — 0–2 feather (no rotten flesh — Beta 1.8)
- **Skeleton** — 0–2 arrow + 0–2 bone (no bone meal until later)
- **Creeper** — 0–2 sulphur (gunpowder)
- **Spider** — 0–2 string
- **Slime** — 0–2 slimeball

Nether (Alpha v1.2.0+):
- **Ghast** — 0–2 sulphur
- **Zombie pigman** — 0–2 cooked porkchop (neutral mob; provoked when hit)

---

## Worldgen highlights

- **2D Perlin heightmap** (no 3D-noise overhangs — that's Beta 1.8)
- World height: **128 blocks** (modern is 384)
- Caves carved by separate noise pass
- Ores: simple Y-band distribution (coal high, diamond deep)
- Biomes were minimal (basically: forest / plains / snowy variants of grass)
- Infinite worlds (Alpha v1.0.0+) — no world borders

---

## Day/night

- Cycle is ~20 minutes real-time (10 day, ~7 night, ~1.5 each twilight)
- Hostile mobs spawn at light level ≤ 7
- Passive mobs spawn at light level ≥ 9 on grass
- No sleeping in Alpha (beds were Beta 1.3, January 2011)

---

*Sources: [Minecraft Wiki — Java Edition Alpha](https://minecraft.wiki/w/Java_Edition_Alpha), per-block "History" sections on individual wiki pages (Grass_Block, Stone, Gravel, Leaves, Redstone_Ore, etc.), [Java Edition Alpha v1.2.0](https://minecraft.wiki/w/Java_Edition_Alpha_v1.2.0).*
