# Pixellab Asset Prompts

Per-batch prompt specs for generating block/item textures via Pixellab.ai. Drop completed PNGs into `assets/textures/blocks/raw/`. Claude wires them into the atlas during integration.

---

## Style anchor (lock this once, reuse for every prompt in the project)

**Style description (paste into every prompt or set as default):**
> 16×16 pixel art texture, hand-drawn pixel art reminiscent of early Minecraft (Alpha era, 2010), muted natural palette, ≤8 colors per texture, no anti-aliasing, slight color noise for organic feel, flat lighting (no baked highlights or shadows — those come from the shader)

**Pixellab settings (apply to all):**
- Dimensions: 16×16
- Tileable: **ON** for all block faces (critical — blocks stack)
- Style reference: after generating the first 1–2 textures, pin them as references for the rest
- Output: PNG, RGBA, sRGB

**Workflow:**
1. Generate `stone.png` first — it's our style anchor
2. Pin it as a style reference in Pixellab
3. Generate the rest in the order listed below

---

## Batch 1 — Phase 2 minimum block set (11 textures)

| # | Filename | Prompt | Tileable |
|---|---|---|---|
| 1 | `stone.png` | Plain gray stone block texture, light cracks, subtle gray-to-charcoal noise | yes |
| 2 | `cobblestone.png` | Cobblestone — irregular gray stones packed tightly, dark mortar between | yes |
| 3 | `dirt.png` | Plain brown dirt, small specks of darker soil and tiny pebbles | yes |
| 4 | `grass_top.png` | Top-down view of grass, varied greens, blades of grass implied with pixel clusters | yes |
| 5 | `grass_side.png` | Side view: brown dirt on bottom, vibrant green grass overhang on top edge ~3 pixels tall | yes (horizontally, top edge fixed) |
| 6 | `bedrock.png` | Very dark gray, almost black stone with chaotic cracks and lighter highlights | yes |
| 7 | `sand.png` | Soft pale yellow sand, fine grain noise | yes |
| 8 | `log_top.png` | End-grain of a tree log: concentric brown rings, slightly off-center | no (single block face) |
| 9 | `log_side.png` | Vertical wood bark: vertical brown striations, lighter highlights, knots optional | yes (vertically — tile a tree trunk) |
| 10 | `planks.png` | Horizontal wooden planks, light brown, subtle grain, plank-edge lines every 4 pixels | yes |
| 11 | `leaves.png` | Dense dark green leaves, varied greens with pinpricks of yellow/light green for depth | yes |

---

## When the batch is done

1. Download all 11 PNGs from Pixellab to wherever your browser defaults (typically `~/Downloads/`) — use the exact filenames listed above
2. Tell Claude they're ready — I'll move them into `assets/textures/blocks/raw/`, validate dimensions, pack them into a single atlas at `assets/textures/blocks/atlas.png`, and emit `assets/textures/blocks/atlas_uvs.tres` with the per-block UV rectangles
3. The chunk shader (built in Phase 2) samples the atlas

## Future batches

- **Batch 2 (Phase 4):** item icons (drops, hand-held versions of tools)
- **Batch 3 (Phase 5):** crafting table, furnace (multi-face), all tool tiers
- **Batch 4 (Phase 6):** mob skins, sky/sun/moon
