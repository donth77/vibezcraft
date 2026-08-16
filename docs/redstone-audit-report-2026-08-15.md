# Redstone Implementation and Performance Audit

**Audit date:** 2026-08-15
**Audited snapshot:** `d3586ad` (`46426dd` was the latest redstone behaviour commit)
**Remediation:** completed 2026-08-15. Working tree only — nothing has been committed or pushed.
**Reference documents:** `.claude/redstone-plan.md`, `docs/redstone-playtest-guide.md`
**Test environment:** Godot 4.6.2, macOS 26.4.1, Apple M2 Max, 32 GiB RAM, arm64, headless debug build
**Scope:** Static implementation review, automated correctness tests, headless project smoke test,
and focused wire-propagation stress measurements. No interactive desktop or web playtest was
performed.

---

## Status

All seven findings are resolved. The audit's three release blockers (RS-01, RS-02, RS-03) were
confirmed against the code and the decompile, fixed, and pinned by new tests. Verifying them
surfaced **an eighth defect the audit did not find** — see RS-08, which was arguably the most
player-visible of the set.

| Finding | Severity | Outcome |
|---|---|---|
| RS-01 wire work discarded at the cap | High | **Fixed** — resumable bursts |
| RS-02 live pressure-plate detection | High | **Fixed** — real collision bounds + contact routing |
| RS-03 fluid washout drops | High | **Fixed** — vanilla water/lava split |
| RS-04 buttons/plates absent from the source set | Medium | **Fixed** |
| RS-05 rail test was a placeholder | Medium | **Fixed** — and the runtime gap closed rather than deferred |
| RS-06 TNT changed-neighbour guard | Medium | **Fixed** — source id threaded through the queue |
| RS-07 missing planned coverage | Medium | **Fixed** — seven new test files, +82 tests |
| **RS-08 switches never notified their mount** | **High** | **Fixed** — found while verifying RS-07 |
| **RS-09 powered switches didn't notify on removal** | Medium | **Fixed** — same root cause as RS-08 |

**Release recommendation: proceed to the manual playtest.** Every automated gate the plan defines
now passes. What is still unverified is what automation cannot reach — visuals, audio, feel, real
streaming, and in-engine frame time — which is precisely the scope of
`docs/redstone-playtest-guide.md`.

---

## Verification performed

Post-remediation. All runs under a sandboxed `HOME` so the suite cannot touch real saves.

| Check | Result | Notes |
|---|---:|---|
| Full GUT suite | **PASS — 665/665** | 63 scripts, 1,946,870 assertions, 160.2 s. Was 583/583 across 56 scripts before this work: **+82 tests, +7 files** |
| Focused redstone suite (`test_redstone*`) | **PASS — 167/167** | 11 scripts |
| The four new non-`redstone`-prefixed files | **PASS — 48/48** | entity bounds, fluid washout, rail shape, redstone mesher |
| Adversarial 1,024-wire fixture | **PASS — 8/8** | `tests/test_redstone_performance.gd` |
| `gdformat --check scripts/ tests/` | **PASS** | 192 files unchanged |
| `gdlint scripts/ tests/` | **PASS** | no problems found |
| Headless project boot | **PASS** | boots to a live world, player spawns, all five natives load, **0 script or parse errors**. Project-level `--check-only` still hangs on this project (pre-existing) and was substituted with `--import` + a real boot |
| Interactive desktop playtest | **NOT RUN** | environment cannot perform it; the guide covers it |
| Web export smoke test | **NOT RUN** | no native code changed, so no wasm rebuild is required for correctness |

Pre-existing warnings unrelated to redstone, unchanged by this work: orphan-node and freed-lambda
messages during scene teardown; a `SubViewport`/`SubViewportContainer` stretch warning from
`sign_edit_screen.gd`; `[STUCK]` mob diagnostics from the earlier fall-through hardening pass; and
the known shutdown race in `MobBase._active_mobs` / `_sep_grid`. None fail a run.

---

## Findings and what was done

### RS-01 — wire work was discarded at the cap *(confirmed, fixed)*

The audit's reproduction was accurate: `update_wire` processed at most 8,192 entries, warned, and
returned with its local queue lost. A 1,024-cell depower left 999 cells stale.

The root cause is worth stating precisely, because it is not a tuning problem. Alpha's wire decays
**one level per relaxation**, so a field where every cell must fall 15 → 0 requires roughly fifteen
sweeps of the whole field — 16,012 relaxations, measured. No cap that discards its queue can ever
finish that; a larger cap only moves the failure.

**Fix.** The worklist became a resumable *burst* held in module state: queue, membership set,
visited set, reconcile flag and pending zero-crossing notifications all survive a pause.
`ChunkManager._process` pumps it once per frame, exactly as it already resumed the block-update
queue. Notifications are withheld until the queue actually empties, so no consumer can observe a
half-propagated network — including one paused across a frame boundary. A manager that does not
advertise `redstone_defers_wire_bursts()` (bare test doubles) still runs the whole fixpoint
synchronously.

Two secondary problems fell out of measuring it:

- The per-drain bound is now **wall-clock** (`WIRE_USEC_PER_DRAIN = 2000`), not a step count. A step
  costs ~33 µs on this machine and several times that on mobile web, so a fixed step budget would
  mean something different on every host.
- `Array.pop_front()` is O(n) in Godot. With a multi-thousand-entry queue the drain was quadratic
  and produced 35 ms spikes. Replaced with a head index plus amortised compaction.

**Tests.** `tests/test_redstone_performance.gd` — 7 tests including the adversarial 1,024-cell
depower, which asserts that the first drain does *not* finish (so the resume path is genuinely
exercised), that it converges to all-zero metadata, and that nothing is left pending. A separate
test drives a 1 µs budget to prove the time bound is wired up deterministically, without asserting
on wall clock in a unit suite.

### RS-02 — live pressure-plate detection *(confirmed, fixed)*

Confirmed and worse than the audit suggested: **no pressure plate could be triggered by anything at
all.** `entities_overlap_box` tested `AABB.has_point(entity.global_position)`, and the player's
`global_position` is the centre of a 1.8 m capsule — about 0.9 m above the feet — against a
detection box 0.25 m tall. The origin is never inside it. Track E was untestable as shipped.

**Fix.** Detection uses real collision bounds (`AABB.intersects`), the way vanilla does
(`ap.java:110`). The derivation moved into a new `EntityBounds` class that reads each entity's own
`CollisionShape3D` — player capsule, mob boxes, cart and boat hulls — and falls back to vanilla's
`setSize` footprints for the two colliderless `Node3D` entities. Dropped items, arrows, minecarts
and boats now route through a shared `report_entity_contact` hook on cell change, and the player is
swept from `ChunkManager._process` so falling or jumping onto a plate wakes it even without a
footstep. The `from_contact` guard added in `46426dd` is preserved and re-tested.

**Tests.** `tests/test_entity_bounds.gd` — 15 tests built from real `Node3D`s with the shapes the
entities actually construct, positioned the way the game positions them. It pins the 0.9 m offset
as its own assertion, covers a cart whose *edge* rather than centre overlaps, and asserts the
wooden/stone split for items and arrows.

### RS-03 — fluid washout drops *(confirmed, fixed)*

Confirmed against `ja.java:101-113`: water hands the displaced block to `dropBlockAsItems`; lava
plays the mix effect and drops nothing. Our `_place_flowing` skipped both. The in-code comment
claiming this "matches Alpha behavior for plants" was simply wrong.

**Fix.** A single `BlockFluids.wash_away` hook before the overwrite, implementing the water/lava
split. This is deliberately the general vanilla rule rather than a redstone special case, so plants
and other displaced blocks drop correctly too.

**Tests.** `tests/test_fluid_washout.gd` — 8 tests running **real flow** (not the
`is_replaceable()` predicate the old test used) and asserting on spawned drops: dust from wire,
lit torch from either torch id, self-drops for lever/button/both plates, ore unaffected, lava
recovering nothing, and no self-drops when water spreads over water.

### RS-04 — buttons and plates absent from the source set *(confirmed, fixed)*

Confirmed: `iy.java:206` and `ap.java:139` both return true from `e()`; our `is_power_source` listed
only lever, both torches and wire.

**Fix.** Added, with a comment recording that this is a capability question, not a state question.

**Tests.** `tests/test_redstone_sources.gd` — a table over sixteen block ids plus separate coverage
of each of the three consumers (connectivity, directional output, the changed-neighbour guard).
`tests/test_mesher_redstone.gd` covers the rendering half, which had no redstone coverage at all
before: wire topology beside buttons and plates, climb quads, the roofed-wire rule, pressed-state
travel for buttons and plates, and that no attachment emits a collider.

### RS-05 — the rail test was a placeholder *(confirmed, fixed; the gap closed, not deferred)*

Confirmed — the test loaded `interaction.gd` and checked its constant map existed.

Re-reading `jn.java:65-99` showed the deferral was also unnecessary. Vanilla **does** re-shape on a
power change, guarded by `n5 > 0 && nq.m[n5].e() && oc.a(...) == 3` — the same changed-neighbour
source guard TNT uses, plus an exact 3-connection test. Once RS-06 threaded the source id through
the queue, the remaining work was to make the shape logic reachable from the redstone module.

**Fix.** The shape rules moved out of `interaction.gd` into a new `RailShape` class, so placement
and the redstone re-evaluation share one implementation. `Redstone._update_rail` implements
`jn.java:89` including the `== 3` equality (a four-way crossing is deliberately left alone).

**Tests.** `tests/test_rail_shape.gd` — 14 tests. Every three-way layout's exact powered and
unpowered meta, read off the decompiled ordering by hand rather than generated from the code under
test; the straights, curves and ramps; and the runtime guards.

**Guide.** F9 now describes behaviour that exists. F10–F12 were added, and the contradictory
"Known gaps" entry and deviation row were removed.

### RS-06 — TNT changed-neighbour guard *(confirmed, fixed)*

Confirmed: `v.java:23` guards on `n5 > 0 && nq.m[n5].e() && cy.o(...)` and we implemented only the
third clause.

**Fix.** Notification queue entries became `Vector4i(x, y, z, source_id)`, deduplicated on the whole
pair. `enqueue_block_notification` defaults the source to whatever now occupies the changed cell,
which is what vanilla passes — so breaking a component reports AIR and correctly fails the guard.

**Tests.** Negative cases in `tests/test_redstone_integration.gd`: a powered TNT cell with dirt
stacked next to it does not ignite, while a source-capable change on the same cell still does; and
an AIR-origin notification never primes.

### RS-07 — missing planned coverage *(confirmed, fixed)*

Seven new test files and 82 new tests in total: `test_redstone_state.gd` (real `ChunkManager` +
`Chunk`), `test_redstone_performance.gd`, `test_entity_bounds.gd`, `test_fluid_washout.gd`,
`test_rail_shape.gd`, `test_redstone_sources.gd` and `test_mesher_redstone.gd`, plus new cases in
`test_redstone_integration.gd` and the held-plate pending-tick persistence case in
`test_redstone_persistence.gd` that the audit called out.

`test_redstone_state.gd` covers what the audit specifically named: atomic id/meta commits,
metadata-only writes reaching the queue, the 4,096-item budget pausing and resuming with an exact
accounting of what it consumed, dedup on cell *and* source, nested writes during a drain, and a
chunk reload whose stale wire metadata is repaired by `_reconcile_redstone_edges`.

### RS-08 — switches never notified their mount *(not in the audit; found while writing RS-07's tests)*

Writing an end-to-end wire test against the real manager exposed a defect none of the audit's static
review found, and it is the most player-visible of the set: **a lever on a wall did nothing to wire
running along the floor beside it.**

`pl.java:145-157` notifies **twice** when a lever is flipped — around the lever, and around the
block it is mounted on. That second fanout is the only mechanism by which strong power leaves a
switch: the mount's other neighbours are two cells from the lever, outside its own seven-cell
fanout. `ap.java:92-93` does the same for plates, and `bo.java:48-53` notifies around all six of a
torch's neighbours. We implemented only the first fanout in every case.

Every existing test passed because they all called `Redstone.update_wire` directly on a fake world
rather than letting the real notification queue carry the update.

**Fix.** `Redstone.notify_around_mount` and `notify_around_all_neighbours`, called from the lever
toggle, button press and release, plate press and release, and both torch transitions.

The same gap existed on the way out: vanilla's `Block.onBlockRemoval` pushes a final update around
the mount when a component that is still ON disappears. Without it, blowing up or washing away a
powered lever leaves whatever it drove *through its mount* stuck open — the guide's F4, which the
seven-cell fanout alone cannot reach because the door is two cells from the lever.
`Redstone.on_block_removed` now runs from `ChunkManager.set_world_block` on any id change, however
it was caused.

One bug was introduced and caught during this fix: plates were initially routed through
`notify_around_mount`, which derives the mount from metadata — and a plate's metadata is its
pressed flag, so a pressed plate (meta 1) read as west-wall-mounted and notified sideways instead
of downward. Split into `notify_around_support` with its own regression test.

**Guide.** B12/B13 were added specifically to exercise it during the playtest; F4 already covered
the removal half.

---

## Performance

Fixture: `tests/test_redstone_performance.gd`. A 32 × 32 connected wire field (1,024 cells) on a
dictionary-backed fake world, every cell independently held at 15 by its own floor-mounted torch
through its own support block. Headless debug build; hardware as stated at the top. No warm-up.

| Measurement | Before | After |
|---|---:|---:|
| Settled seed, median (100 samples) | 7.4 µs | **10 µs** |
| Settled seed, p95 | — | **12 µs** |
| Power-up from dark, 1,024 cells | 33.6 ms | **~18 ms** (2,047 relaxations) |
| Depower, 1,024 cells | 331.8 ms, **abandoned at 999 stale cells** | **~530 ms, converges to all-zero** (16,012 relaxations, 15,052 writes) |
| Worst frame during that depower | n/a (single blocking burst) | median **2.24 ms**, p95 **2.63 ms**, max **3.35 ms** over ~245 drains |
| Cost of one relaxation | — | ~33 µs |

Reading the table honestly: the depower now does *more* total work than the truncated version did,
because it actually finishes. What changed is that it is correct and that no single frame is
blocked. Convergence takes ~245 frames — a few seconds of visible draining — which is inherent to
Alpha's one-level-per-relaxation decay, matches vanilla's behaviour on large circuits, and is not
reachable by any real circuit (a single source reaches 15 cells). An ordinary edit settles inside
one drain.

The plan's original "converge within 10 frames" clause was wrong for the adversarial case and has
been removed from §7.7 rather than quietly left unmet. The guarantee the budget provides is that no
frame is blocked, not that convergence is instant.

**Still outstanding:** these are fake-world timings. The plan's 30 s warm-up + 60 s in-engine
desktop sample has not been run, and cannot be from this environment.

---

## Documentation reconciliation

1. **Plan §3.2.4 contradiction — resolved.** The line read "a corner/T/cross powers only along its
   actual arms", which is the opposite of `lu.java:270-280` (each slot test requires the absence of
   both perpendicular connections, so a bend or branch stops horizontal output entirely). The
   implementation was correct; the plan text was wrong and is now stated with its derivation.
2. **"Not built yet" — replaced** with a *Remaining validation* table carrying explicit
   pass / manual pending / not tested status per area.
3. **F9 vs Known Gaps — resolved** by implementing the behaviour (see RS-05), so the guide, the
   deviation register and the implementation now agree.
4. **"~2 ms regardless of circuit size" — replaced** with the fixture-specific table above,
   reproduced in both the guide and plan §7.7 with machine, build mode, fixture shape and sample
   counts.
5. **Release checklist — now status-tracked.** All twenty criteria carry pass / manual pending /
   not tested with named evidence. Per-batch gates in §9 are unchanged; none were weakened. One
   criterion remains genuinely unmet: no desktop or web session has been run.
6. **Version control — resolved.** `.gitignore` ignored all of `docs/`. Changed `docs/` to `docs/*`
   plus `!docs/redstone-*.md`, which is the minimum that works (git will not re-include a file whose
   parent *directory* is excluded). Every other file in `docs/` stays ignored, and the unrelated
   uncommitted `.gitignore` edits were preserved.

---

## Second audit — parity sweep against the decompile (2026-08-15, later)

Prompted by a playtest run that turned up broken placement, this pass asked a different question
from the first one: not "is what we built correct?" but "did we build all of it?". Both halves were
answered from the source rather than from the plan.

**Consumers.** Every class in Alpha 1.2.6 that reads a redstone power query:

| Class | What it is | Ours |
|---|---|---|
| `gv.java` | door | `Redstone._update_door` |
| `jn.java` | rail junction | `Redstone._update_rail` |
| `v.java` | TNT | `Redstone._update_tnt` |
| `lu.java` | wire (reads its own inputs) | `Redstone.computed_wire_power` |
| `bo.java` | torch (reads its mount via `cy.k`) | `Redstone.torch_mount_powered` |

That table is the complete grep for `cy.o()` / `cy.n()` / `cy.k()` across all 400+ decompiled
classes. There is no sixth consumer, so there is no redstone-driven block missing from our port.

**Producers.** Every class whose `e()` (`isPowerSource`) returns true: `pl.java` (lever),
`iy.java` (button), `ap.java` (both plates), `bo.java` (both torch ids), and `lu.java` (wire,
behind its recomputation guard). All six ids are in `Redstone.is_power_source` — as of RS-04;
before that fix the button and both plates were missing.

**Registration values, read off `nq.java` and confirmed in `blocks.gd`:**

| | Vanilla | Ours |
|---|---|---|
| Glowing ore light | `.a(0.625f)` → 9 | 9 |
| Lit redstone torch light | `.a(0.5f)` → 7 | 7 |
| Unlit ore / off torch | no `.a()` → 0 | 0 |
| Ore drop | `an.java:55` `4 + nextInt(2)` | 4-5 |
| Ore hardness | `.c(3.0f)` | 3.0 |
| Ore resistance | `.b(5.0f)`, identical to `hz.java` iron/coal ore | same value we give every ore |
| Button pulse / torch delay / burnout | 20t / 2t / 8-in-100t | same |
| Plate box | inset 1/8, height 1/4 | same |
| Lever mounts | 4 walls + floor, no ceiling (`pl.java:27-39`) | same |
| Button mounts | 4 walls only (`iy.java:30-39`) | same |

**Recipes.** Lever, redstone torch, stone button, both plates, compass and clock are all present.
The two plate recipes are the documented 2-wide deviation (§11); everything else is the vanilla
pattern. Dust has no recipe in Alpha and correctly has none here.

**Not in Alpha, so correctly absent:** redstone lamp (Java 1.2, 2012), repeater (Beta 1.3),
dispenser and note block (Beta 1.2), piston (Beta 1.7), powered and detector rails (Beta 1.5).

### What this pass actually found

Nothing wrong with the model — and three more defects at the seam where a player touches it:

- **RS-10: redstone dust could not be placed at all.** The branch existed and was correct, but sat
  *below* `if stack.item_id >= 100 ... return false` in `_place_block_from_held`, which rejects
  every item id. Dead code. Right-clicking with dust did nothing. Fixed by dispatching it with the
  other item-placed blocks (sign, bed, rail, doors), and guarded by
  `tests/test_item_placement.gd`, which asserts dispatch order for all nine of them.
- **RS-11: the inventory icon smeared sprite tiles across a cube.** `BlockIconRenderer` wraps one
  texture around six faces, which only works for a solid tile. Lever, dust and both torches are
  sprites on transparency (8-21% opaque, against 44% for the thinnest legitimate cube), so they
  rendered as a sprite floating on three faces of an invisible cube.
- **RS-12: the held and dropped renderers disagreed with the icon and with each other.** Three
  call sites each carried their own hand-maintained sprite-vs-cube list — `player.gd` keyed on
  CROSS+LADDER, `dropped_item.gd` on CROSS+TORCH, `block_icon_renderer.gd` on an id list. Unified
  behind `Blocks.has_sprite_tile()`. A sweep of all 100 block ids confirms nothing sparse is left
  on a cube path.

The pattern across every defect found in both audits is worth stating plainly: **the simulation was
right and the seams were wrong.** Plate detection compared the wrong coordinate convention;
switches skipped the second fanout; water skipped the drop call; three renderers disagreed;
placement was unreachable. All of it was invisible to the test suite because every redstone test
drove the world model directly — `Redstone.update_wire`, `set_world_block` — and none went through
the path a player uses. The tests added since (`test_redstone_state.gd` against a real
`ChunkManager`, `test_entity_bounds.gd` against real node conventions, `test_item_placement.gd`
against dispatch order) exist to close that specific gap.

---

## Remaining risks

- **Nothing has been played.** Every visual, every sound, and every question of feel is unverified
  by construction. Two of the fixes above (RS-02, RS-08) mean parts of Tracks B and E have *never*
  worked in a real session, so they have no history of anyone having looked at them.
- **In-engine frame cost is unmeasured.** The per-frame budget is enforced by wall clock, so it
  should hold on slower hosts, but that is reasoning rather than measurement.
- **The web export has not been rebuilt or smoke-tested.** No native code changed, so no wasm
  rebuild is required for correctness.
- **A pre-existing shutdown race** in `MobBase._active_mobs` / `_sep_grid` still occasionally
  crashes on quit. It predates all redstone work, happens after the world is saved, and is
  unrelated to anything here.
