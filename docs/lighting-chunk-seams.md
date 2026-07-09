# Chunk-Seam Lighting: Investigation Report & Fix Plan

**Status:** investigation complete, fix not started
**Date:** 2026-07-03
**Origin:** GitHub issue #4 — "lighting is bugged on surfaces. you can see the
skybox between the blocks as slight lines" (grazing-angle grass grid) and the
bright seam line visible in the dark-cave screenshot from the same report.

---

## 1. Executive summary

Both reported lighting artifacts are the **same problem at chunk seams**, in
two layers:

1. **Permanent:** a face that lies on a chunk boundary lights itself from a
   cell in the *neighboring chunk*, but chunks carry **no cross-chunk light
   data**. The out-of-bounds lookup falls back to the sky-light default of
   **15 (full daylight)**, so every exposed seam face renders fully lit
   forever — a noon-bright stripe across dark cave walls, night terrain, and
   torch-lit interiors.
2. **Transient but long-lived:** a chunk's *first* mesh is built on a worker
   with empty neighbor data, so it emits its entire 4-sided boundary wall
   un-culled — and per (1), fully lit. The heal (re-mesh once the neighbor
   lands) works, but heal re-meshes drain through a **1-per-frame apply
   budget**, so while exploring at Normal/Far render distance the player is
   surrounded by tens of seconds' worth of un-healed seams. Their fully-lit
   buried walls peek out at grazing angles as the faint pale 16-block grid in
   the reporter's screenshot (4× MSAA on desktop resolves the sub-pixel
   slivers into clean lines; web/no-MSAA mostly hides them).

The fix is to plumb **edge light slices** through the existing edge-slice
mechanism (blocks + meta already ride it), plus two smaller follow-ups:
re-dirty the adjacent chunk when a border-column cell is relit, and stop seam
heals from starving in the apply queue.

---

## 2. Symptoms

| Report | Where seen | Actual artifact |
|---|---|---|
| "skybox between the blocks as slight lines" | daylight grass plain, grazing angle, desktop release | Faint pale grid at **16-block spacing** (measured against the 1-block selection box in the screenshot — it is NOT per-block). Sub-pixel slivers of fully-lit buried boundary walls, MSAA-resolved into lines. |
| Bright warm seam on a dark cave ceiling/wall | underground, low light | A strip of seam faces lit at sky=15 in a light-0 cave. Permanent — does not heal. |
| (same class, unreported) | night surface, torch-lit rooms crossing a seam | Any exposed seam face renders at full bright. |

---

## 3. Root cause analysis

### 3.1 How face lighting works today

The mesher lights each face **flat**, by sampling the light of the *neighbor
cell the face looks into* — the open cell holding the light that reaches it:

- `scripts/world/mesher.gd:614-627` — per-face light: `chunk.get_sky_light(x
  + no.x, y + no.y, z + no.z)` packed into vertex COLOR (sky in R, block
  light in G), consumed by the brightness LUT in `chunk_common.gdshaderinc`.
- Same rule mirrored byte-for-byte in `src/mesher_native.cpp`
  (`mesh_chunk_data_lit/_lit2`), guarded by `tests/test_mesher_native.gd`.

### 3.2 Defect 1 — no cross-chunk light data (permanent)

For a face on the chunk border, the sampled neighbor cell is outside the
chunk. Chunks carry 1-cell-thick **edge slices of neighbor blocks and meta**
(`scripts/world/chunk.gd:87-94`) — added by optimization #2 for cross-chunk
face *culling* — but **light was never plumbed into the slices**:

- `chunk.gd:204-205` — `get_block(x=-1, …)` consults `edge_blocks_west`. ✅
- `chunk.gd:293-296` — `get_sky_light` has **no edge branch**; any OOB read
  returns the vanilla sky default **15**. `get_block_light` (`:307-310`)
  returns 0.

Net effect: **every face on a chunk border is lit as if it faced full
daylight (sky 15, block 0), regardless of the true light there.** In
daylight this is invisible (true value ≈ 15 anyway); anywhere darker, the
seam glows. There is **no cheap in-chunk fallback**: the BFS stores light in
*open* cells only, and for a border face the correct open cell is across the
seam by definition — the data must physically cross the boundary.

### 3.3 Defect 2 — initial-mesh boundary walls + heal backlog (transient)

- `scripts/world/chunk_manager.gd:688-693` (comment is explicit): the
  worker's initial mesh **always** runs with empty neighbor slices ("workers
  can't safely read main-thread data; the first correct mesh happens on the
  next frame"). Empty slice → `get_block` OOB → AIR → the boundary wall is
  emitted **un-culled**, and per Defect 1, **lit at 15**.
- The heal: when a neighbor chunk lands, both chunks are re-dirtied
  (`chunk_manager.gd:694-709`) and the re-mesh culls the buried wall via the
  now-populated edge slices (`chunk_node.gd::_attach_neighbor_edges`).
- The bottleneck: background re-mesh results drain through
  `apply_budget_per_frame = 1` (`chunk_manager.gd:73`; only player edits set
  `_priority_apply` and skip the queue). A render-distance change or a long
  walk enqueues hundreds–thousands of seam heals at ~60/s — the visible
  world stays covered in fully-lit seam walls for tens of seconds to
  minutes. At grazing angles their top edges peek out along the surface as
  the pale grid.

### 3.4 Eliminated hypotheses (for the record)

- **Per-block atlas bleed / mipmapping** — atlas is nearest-filtered with no
  mipmaps and half-texel UV insets (`block_atlas.gd:293-351`); and the
  measured grid is 16-block, not per-block.
- **Geometry gaps / T-junctions** — vertices are exact integers; abutting
  triangles share bit-identical edges, which the rasterizer treats as
  watertight even across draw calls.
- **Leftover edge-outline shader** — removed in the phase-6 lighting
  rewrite; `optimizations.md` reference is stale.
- **MSAA as the cause** — MSAA is only the *presenter*: it resolves the
  sub-pixel lit slivers into clean faint lines (which is why desktop shows
  them and web mostly doesn't). Disabling MSAA would trade lines for
  sparkle, not fix anything.
- **Flat-lighting one-LUT-step seams** — real but tiny; the observed cave
  seam is a many-step jump to full bright, only explained by the OOB-15
  default.

### 3.5 Evidence index

| Fact | Location |
|---|---|
| Face light sampled from neighbor cell | `scripts/world/mesher.gd:614-627` |
| OOB sky-light default = 15 | `scripts/world/chunk.gd:293-296` |
| Edge slices exist for blocks + meta only | `scripts/world/chunk.gd:87-94` |
| `get_block` consults edge slices, light accessors don't | `chunk.gd:204` vs `chunk.gd:293` |
| Initial worker mesh always has empty edges | `scripts/world/chunk_manager.gd:688-693` |
| Neighbor-arrival heal (re-dirty both sides) | `chunk_manager.gd:694-709` |
| Heal applies throttled to 1/frame | `chunk_manager.gd:73` (`apply_budget_per_frame`) |
| Relight dirties only the written chunk | `chunk_manager.gd::set_world_sky_light` |
| Native mirrors the same light rule (parity-tested) | `src/mesher_native.cpp`, `tests/test_mesher_native.gd` |
| Cross-chunk culling design + GDScript-fallback caveat | `.claude/optimizations.md` §2 |

---

## 4. Fix plan

### Phase 1 — edge light slices (kills the permanent seams)

Mirror the existing edge-slice mechanism for sky + block light, end to end:

1. **`scripts/world/chunk.gd`**
   - Add `edge_sky_light_{west,east,north,south}` and
     `edge_block_light_{west,east,north,south}` (`PackedByteArray`,
     `SIZE_Y × SIZE_Z` / `SIZE_Y × SIZE_X`, same layout as `edge_blocks_*`).
   - Extend `_edge_slices_x/_edge_slices_z` (and the four `*_edge_slices()`
     wrappers) to also copy the light planes.
   - `get_sky_light` / `get_block_light`: add the same edge-consult branches
     `get_block` has at `chunk.gd:204` (x == -1 → west slice, x == SIZE_X →
     east, z likewise). Fallbacks stay 15 / 0 when the slice is empty —
     preserving today's behavior for genuinely unloaded neighbors.
2. **`scripts/world/chunk_node.gd::_attach_neighbor_edges`** — snapshot the
   four neighbors' light planes alongside blocks + meta. (~16 KB extra copy
   per re-mesh; negligible.)
3. **GDScript mesher** — no change needed: `mesher.gd` reads light through
   `chunk.get_sky_light/get_block_light`, which now see the edges.
4. **Native mesher (recompile required)**
   - New entry point **`mesh_chunk_data_lit3`** taking the 8 extra edge-light
     arrays (follow the house pattern: keep `_lit2` bound so a stale binary
     falls back to the legacy combo, probe `_native_has_lit3` in
     `mesher.gd::mesh_chunk_fast`).
   - Add a `read_light(...)` helper mirroring `read_block`'s edge-consult
     logic; route the per-face light sampling through it.
   - `src/register_types.cpp` untouched (same class), `.h` declaration +
     `ClassDB` bind for the new method.
5. **Tests**
   - `tests/test_mesher_native.gd`: new parity fixture — two adjacent chunks
     where the seam column is dark on one side (e.g. sealed cave at the
     border), assert GDScript vs native byte-parity AND that seam-face COLOR
     no longer encodes 15/15.
   - `tests/test_lighting.gd`: unit-assert `Chunk.get_sky_light(-1, y, z)`
     returns the attached edge value and the 15-default only when the slice
     is empty.
6. **Web build**: wasm extension rebuild with the pinned emsdk 4.0.20.

**Effort:** M (the C++ + parity discipline is the bulk). No save-format or
shader changes; vertex COLOR encoding is unchanged.

### Phase 2 — relight near borders re-dirties the neighbor

With edge light live, a light change in chunk B's border column must re-mesh
chunk A (A's seam faces sample those cells via the slices). Today
`set_world_sky_light`/`set_world_block_light` mark only the written chunk
dirty.

- In both setters: if `local_x` is 0 / `SIZE_X-1` or `local_z` is 0 /
  `SIZE_Z-1`, also set the adjacent chunk(s) dirty (same corner logic as the
  block-edit path at `chunk_manager.gd:1285-1293`).
- Cost: relight BFS already batches; the extra dirty is coalesced by the
  per-chunk dirty flag.

**Effort:** S. Without it, Phase 1 fixes static scenes but torch place/break
near a seam leaves stale seam lighting on the neighbor.

### Phase 3 — heal latency (shrinks the transient grid)

Measure first (count queued applies after a render-distance change), then
either:

- **Preferred:** let seam-heal re-meshes share the priority lane — a chunk
  re-dirtied by a neighbor's arrival sets `_priority_apply` (bounded: it can
  only happen once per seam), or
- bump `apply_budget_per_frame` for re-meshes whose chunk is within N chunks
  of the player.

Either way the pale grid becomes a sub-second flicker at the loading
frontier instead of a minutes-long overlay. Watch the wasm frame budget —
this knob was tuned for web (`optimizations.md`); gate any budget increase
to desktop if it measurably regresses throttled wasm.

**Effort:** S–M (measurement + one queue-policy change).

### Phase 4 (deferred) — smooth lighting

Vanilla Beta's "smooth lighting" (per-vertex corner-averaged light + the AO
look) would also eliminate the remaining *legitimate* 1-LUT-step face seams
and is the natural sequel once cross-chunk light data exists (corner
averaging needs the same edge slices). Deliberately out of scope here: it
changes the vertex COLOR contract, every parity fixture, and the game's
look. Track it in `.claude/optimizations.md` as its own entry.

### Sequencing

Phase 1 → 2 ship together (2 is small and 1 is incomplete without it).
Phase 3 is independent and can land before or after. Suggested commits:

1. `fix(lighting): cross-chunk edge light slices — seam faces light correctly`
2. `fix(lighting): border relight re-dirties the adjacent chunk`
3. `perf(chunks): prioritize seam-heal re-meshes` (with measurements in the body)

---

## 5. Risks & invariants to preserve

- **Byte-for-byte native parity** — every change lands in the GDScript
  reference and C++ together; `test_mesher_native.gd` is the gate.
- **Threading contract** — edge light is snapshotted on the main thread in
  `_attach_neighbor_edges`, workers only read their copies (same rule as
  blocks/meta today).
- **Stale-binary fallback** — keep `_lit2` (and `_lit`) bound; probe for
  `_lit3` like `_native_has_lit2` does, so an old dylib degrades gracefully.
- **OOB semantics elsewhere** — `Chunk.get_sky_light` returning 15 for
  *empty-slice* OOB is load-bearing for the lighting BFS at world edges;
  only the attached-slice branch changes behavior.
- **No new materials/shaders** — the fix is data-only; the brightness LUT
  and vertex COLOR encoding are untouched.

## 6. Acceptance criteria

- [ ] Cave wall/ceiling crossing a chunk seam shows no bright stripe (parity
      fixture + manual check at a seam, F8 light probe on both sides).
- [ ] Night surface and torch-lit rooms show no seam lines.
- [ ] Placing/breaking a torch in a border column updates the neighbor
      chunk's seam faces within a frame.
- [ ] Grazing-angle grass grid reduced to a brief flicker at the loading
      frontier after a render-distance change (before/after screenshots).
- [ ] `test_mesher_native.gd` + `test_lighting.gd` green; full GUT suite
      green; web export boots with the rebuilt wasm extension.

## 7. Appendix — related items already resolved (context)

- **Mob lighting pops** (herds flipping brightness): shared species materials
  were mutated with per-mob light; fixed via per-light-level material
  variants (`e309114`).
- **Sky/fog** ("fog only covers parts that are there"): `fog_sky_affect`
  0 → 0.35 (`516e4f9`); taste knob, revisit alongside Phase 1 since seam
  fixes change how distant terrain reads.
- **Cloud field-edge walls + colour** (`516e4f9`) — unrelated to voxel
  lighting but reported in the same issue.
