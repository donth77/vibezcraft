# Legal Audit — Open-Sourcing Readiness

> **Disclaimer:** This is a technical audit by a developer, not legal advice. If you're considering public distribution, have a real lawyer review the project. Mojang / Microsoft have historically been permissive of fan-made clones but retain the right to act when they feel IP is at risk.

Scope: everything currently **tracked by git** (i.e. would be pushed to GitHub if the repo went public today). Untracked files on your local disk are out of scope; the existing `.gitignore` already keeps `vendor/` and the native-build outputs out of the published set.

Audit date: 2026-04-20.

---

## Verdict at a glance

The project is **not yet safe to open-source**. Code is fine. The asset pipeline has two categories of problem:

1. **Definitely Mojang-owned material** is currently tracked (audio SFX, GUI textures, block-break crack overlays, the font reference `ascii.png`).
2. **License compatibility** — one of the safe-to-redistribute texture packs (PixelPerfectionCE, CC BY-SA 4.0) has a share-alike clause that conflicts with MIT / Apache and constrains what license the project can adopt.

Clearing item 1 is the absolute blocker. Item 2 is a project-license decision that should be made before the first public push.

---

## Tracked asset inventory

### ✅ Safe to redistribute (with attribution)

| Path | Source | License | Attribution present? |
|---|---|---|---|
| `assets/textures/blocks/packs/programmer_art/*.png` | [deathcap/ProgrammerArt](https://github.com/deathcap/ProgrammerArt) | CC BY 4.0 | ✅ `ATTRIBUTION.md` in folder |
| `assets/fonts/Minecraft.otf` | [IdreesInc/Minecraft-Font](https://github.com/IdreesInc/Minecraft-Font) (community recreation — *not* the Mojang font) | SIL OFL v1.1 | ✅ `assets/fonts/ATTRIBUTION.md` |

### ⚠️ Safe *only if project license is compatible*

| Path | Source | License | Catch |
|---|---|---|---|
| `assets/textures/blocks/packs/pixel_perfection/*.png` | [Athemis/PixelPerfectionCE](https://github.com/Athemis/PixelPerfectionCE) | CC BY-SA 4.0 | **Share-alike.** If you ship these bundled in the repo, any derivative of the combined work must also be CC BY-SA 4.0. MIT / Apache-2.0 **cannot** be used as the project license while these are included. Options: (a) remove the pack from the repo and download on demand, (b) dual-license code (MIT) + assets (CC BY-SA), (c) adopt CC BY-SA 4.0 / GPL-3 for the whole project. |
| `assets/textures/entities/packs/pixel_perfection/steve.png` | Same as above | CC BY-SA 4.0 (if it's actually from the PixelPerfectionCE Steve skin) | **Verify this file is really from PixelPerfectionCE** and not extracted from vanilla. Character-design IP on Steve-the-avatar is Mojang's; a community recreation with an explicit CC license is fine, a rip is not. |

### ⚠️ Needs attribution / license verification (no attribution file currently)

| Path | Likely source | Action |
|---|---|---|
| `assets/textures/blocks/packs/pixellab/*.png` (40 files) | AI-generated via Pixellab | Read Pixellab's ToS for the subscription tier used. Most AI-art services grant a *non-exclusive* license — whether that permits *redistribution under an open-source license* is service-specific. Add an `ATTRIBUTION.md` once verified, or drop the pack if ToS forbids redistribution. |

### ❌ High-risk — almost certainly Mojang-owned, currently tracked

These files are either explicitly labeled as Mojang artwork (per the existing attribution file) or have filenames / content that match Mojang assets exactly. **Each one should be removed, replaced, or moved to an ignored local-only folder before the repo goes public.**

| Path | Evidence |
|---|---|
| `assets/textures/gui/inventory.png` | `assets/fonts/ATTRIBUTION.md` admits: *"This is original Mojang artwork — included here only for personal/non-commercial use as part of an Alpha clone study project."* A public open-source license does not satisfy "personal/non-commercial". |
| `assets/textures/gui/crafting_table.png` | Same provenance as `inventory.png` (InventivetalentDev/minecraft-assets mirror of Mojang). |
| `assets/textures/gui/widgets.png` | Same. |
| `assets/textures/gui/icons.png` | Same. |
| `assets/textures/gui/furnace.png` | Same. |
| `assets/textures/gui/armor_slots/empty_armor_slot_*.png` | Vanilla Minecraft empty-armor-slot icons; distinctive. |
| `assets/fonts/ascii.png` | Attribution file admits *"This is original Mojang artwork"*. Marked "reference only, not used at runtime" — but it's still tracked, so it would still be redistributed. |
| `assets/textures/effects/destroy_stages.png` + `assets/textures/effects/raw/destroy_stages_individual/destroy_stage_0..9.png` | Vanilla block-break crack overlays. 10 individual PNGs + 1 composite. |
| `assets/audio/sfx/Grass_dig1..4.ogg` | Exact Mojang filenames (note the capital G). |
| `assets/audio/sfx/Gravel_dig1..4.ogg` | Same — capitalized Mojang filename. |
| `assets/audio/sfx/Sand_dig1..4.ogg` | Same. |
| `assets/audio/sfx/Stone_dig1..4.ogg` | Same. |
| `assets/audio/sfx/Wood_dig1..4.ogg` | Same. |
| `assets/audio/sfx/Pop.ogg` | Mojang's item-pickup sound. |
| `assets/audio/sfx/step/{cloth,grass,gravel,sand,stone,wood}{1..4}.ogg` (24 files) | Mojang footstep sound set. |
| `assets/audio/sfx/damage/{fallbig,fallsmall,hit1..3}.ogg` | Mojang damage sound set. |
| `assets/audio/sfx/tool_break.ogg` | Mojang tool-break sound. |
| `assets/textures/items/stick.png` | Verify source — may be an extracted Mojang item sprite or a community replacement. Only 2 item PNGs are tracked (`stick.png` and `wooden_pickaxe.png`) out of 82 locally. If these came from vanilla, they go in the same bucket. |
| `assets/textures/items/wooden_pickaxe.png` | Same — verify. |

### 🟢 Not tracked, won't be published

Present locally but excluded by `.gitignore` or simply never `git add`-ed:

- `vendor/mojang/` — raw Mojang JARs / reference material. Explicitly gitignored ✅
- `assets/textures/blocks/packs/alpha_vanilla/*` — extracted from the Mojang Alpha JAR by `scripts/dev/extract_alpha_pack.py`. Currently 0 files tracked ✅
- `assets/textures/entities/packs/alpha_vanilla/steve.png` — not tracked ✅
- `assets/textures/items/` other than `stick.png` / `wooden_pickaxe.png` — 78 files untracked ✅

Keep them that way.

---

## Code risk

### Low risk — clean-room reimplementation

The GDScript + C++ under `scripts/`, `src/`, and shaders under `shaders/` is all your own work. Game *mechanics* (block breaking, crafting recipes, ore distribution, tree shape) are not copyrightable under U.S. law (*Data East* / *Atari v. Philips* line of cases). A from-scratch clone of Minecraft's behavior is legally fine — Terasology, Minetest/Luanti, and dozens of others live as open-source clones.

### Medium risk — mc-dev citations

Several comments in the code explicitly name Bukkit/mc-dev as a source. For example, in `scripts/world/worldgen.gd`:

- *"Deterministic port of vanilla WorldGenMinable.generate (Bukkit/mc-dev)"*
- *"verbatim from Bukkit/mc-dev"*
- *"Mirrors vanilla BlockFalling.m() in Bukkit/mc-dev"*

The Bukkit/mc-dev repository itself is legally gray — it redistributes decompiled Mojang server code without a license. Citing it as your reference in comments gives an adversarial lawyer a direct hook into an infringement argument, **even though the algorithms and numeric constants you reimplemented are not themselves copyrightable**. Action: rewrite these comments to cite the observable in-game behavior, the Minecraft Wiki, or "community reverse-engineering notes" — **not** mc-dev specifically.

Also: `scripts/game.gd` currently says:

```
#   • "alpha_vanilla"   — extracted from Mojang Alpha 1.2.6 (default)
```

This comment and the `texture_pack` default of `"alpha_vanilla"` should be changed before public push:
- Change the default to `"programmer_art"` (the CC BY 4.0 pack).
- Rewrite the comment to say *"local-only pack extracted for development, not shipped"* or drop the `alpha_vanilla` mention entirely.

### Low risk — `scripts/dev/extract_alpha_pack.py`

A Python tool that extracts block/item/entity textures from a Mojang Alpha JAR into the local `alpha_vanilla` pack. The tool itself is your code and legal to publish — format-conversion tooling of this kind is common and protected. But it implies workflow: someone reading the repo learns how to extract Mojang assets. Not a legal problem, but worth noting:

- Keep it, but add a header comment making it clear the script processes files the user must legally possess, and the output is intentionally gitignored.
- Consider moving it to a `tools/` directory with a README that says as much.

---

## Trademark

- Project name **"VibezCraft"** — distinctive enough; the `-craft` suffix is used by many games and is not a Mojang trademark. ✅
- `README.md` currently says *"from-scratch clone of Minecraft Java Edition Alpha (2010)"* — this is **nominative fair use** (describing what the project is) and is the standard pattern all Minecraft clones use. Keep it, but add a disclaimer block:

```
This project is not affiliated with, endorsed by, sponsored by, or
associated with Mojang AB, Microsoft, or the Minecraft franchise.
"Minecraft" is a trademark of Mojang Synergies AB.
```

---

## Recommended pre-open-source checklist

Ordered from most to least urgent.

**Before any public push:**

1. **Delete all tracked Mojang-derived assets:**
   ```
   git rm  assets/textures/gui/inventory.png assets/textures/gui/inventory.png.import
   git rm  assets/textures/gui/crafting_table.png*
   git rm  assets/textures/gui/widgets.png*
   git rm  assets/textures/gui/icons.png*
   git rm  assets/textures/gui/furnace.png*
   git rm  assets/textures/gui/armor_slots/empty_armor_slot_*.png*
   git rm  assets/fonts/ascii.png*
   git rm  assets/textures/effects/destroy_stages.png*
   git rm -r assets/textures/effects/raw/destroy_stages_individual/
   git rm  assets/audio/sfx/{Grass,Gravel,Sand,Stone,Wood}_dig*.ogg*
   git rm  assets/audio/sfx/Pop.ogg*
   git rm  assets/audio/sfx/tool_break.ogg*
   git rm -r assets/audio/sfx/step/ assets/audio/sfx/damage/
   ```
   Replace with either: (a) community CC-licensed alternatives (OpenGameArt, Freesound under CC0 / CC BY), (b) originals you recorded / drew, or (c) procedurally-generated placeholders.

2. **Gitignore the local-only Mojang-derived packs** so they can never be accidentally added later:
   ```
   # Append to .gitignore
   assets/textures/blocks/packs/alpha_vanilla/
   assets/textures/entities/packs/alpha_vanilla/
   ```

3. **Verify `stick.png` and `wooden_pickaxe.png`** — if either came from a Mojang extract, remove and replace. Otherwise add them to an `items/ATTRIBUTION.md` naming their source.

4. **Verify `assets/textures/entities/packs/pixel_perfection/steve.png`** came from the PixelPerfectionCE repo (check the exact file against the source). If yes, add to `ATTRIBUTION.md`. If it's actually a Mojang Steve skin, remove it.

5. **Verify the pixellab pack's license.** Open Pixellab's ToS at your subscription tier. If redistribution is permitted, add `assets/textures/blocks/packs/pixellab/ATTRIBUTION.md` naming Pixellab, the subscription, and the redistribution clause. If not permitted, delete the pack from the repo (it can live in `vendor/` locally).

6. **Decide the project license** and pick one compatible with every included asset:
   - If you drop / reimplement `pixel_perfection/`: MIT or Apache-2.0 are fine.
   - If you keep `pixel_perfection/`: CC BY-SA 4.0 is share-alike, so either license the whole project under a compatible copyleft license **or** dual-license (e.g. code MIT, `assets/` CC BY-SA).
   - Recommended: **Apache-2.0 for code, CC BY-SA 4.0 for assets**, documented in `LICENSE` + `LICENSE-ASSETS`.

7. **Add `ATTRIBUTIONS.md`** at repo root aggregating every bundled third-party asset / library (programmer_art, pixel_perfection, Minecraft-Font, pixellab, godot-cpp, GUT).

8. **Rewrite mc-dev-citing comments.** The algorithms stay; the source citation changes. e.g. `# Deterministic port of vanilla WorldGenMinable.generate (Bukkit/mc-dev)` → `# Mirrors vanilla Alpha's ore-vein distribution (ellipsoid-along-line, 2x2 NE-spill, reconstructed from the Minecraft Wiki's WorldGen pages and observed in-game yields).`

9. **Change default texture pack** in `scripts/game.gd` from `"alpha_vanilla"` to `"programmer_art"`. Remove the `alpha_vanilla` line from the texture-pack docstring or soften it to "local-only; not shipped".

10. **Add a disclaimer block** to `README.md` as in the Trademark section above.

**After the first push:**

11. Don't monetize — Mojang tolerates fan clones far more when nobody is making money. A Ko-fi "buy me a coffee" is usually fine; a paid Steam release or merch store is a red flag.

12. If Mojang ever sends a takedown request, comply immediately. You keep the git history locally; losing the public repo is not losing the work.

---

## TL;DR

| Item | Status | Action |
|---|---|---|
| Code (GDScript + C++) | 🟢 Clean-room, safe | Soften mc-dev comments |
| `programmer_art` textures | 🟢 CC BY 4.0, attributed | — |
| `pixel_perfection` textures | 🟡 CC BY-SA 4.0 — share-alike traps project license | Pick compatible license or drop |
| `Minecraft.otf` community font | 🟢 SIL OFL | — |
| `pixellab` textures | 🟡 ToS-dependent | Verify redistribution rights |
| GUI textures (`inventory.png`, `widgets.png`, etc.) | 🔴 Mojang artwork | **Remove before push** |
| Audio SFX (`*_dig*.ogg`, `step/`, `damage/`, `Pop.ogg`) | 🔴 Mojang | **Remove before push** |
| `destroy_stages*.png` | 🔴 Mojang | **Remove before push** |
| `ascii.png` | 🔴 Mojang reference-only, still tracked | **Remove before push** |
| `alpha_vanilla` texture pack | 🟢 Not tracked — stays local | Add to `.gitignore` to be safe |

**Make the red rows green, pick a license, then we can ship.**
