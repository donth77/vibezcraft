# Performance Plan

A measurement-first plan for keeping VibezCraft fast. The guiding rule: **no optimization work — and especially no language port — without a profile that justifies it.**

---

## 1. Purpose & non-goals

**Purpose**
- Establish frame-time / memory / chunk-latency budgets.
- Wire in lightweight, always-on instrumentation so regressions show up in CI rather than "it feels slower now."
- Define *thresholds* that trigger escalation (e.g. "if meshing > 25 ms p95, revisit").

**Non-goals**
- Speculative optimization. We do not tune what we haven't measured.
- Blanket language rewrites. If GDExtension enters the picture it targets one hot path at a time.
- Visual-quality regressions (MSAA off, shadow cuts) masquerading as perf wins.

---

## 2. Target budgets

Target hardware baseline: **M1 MacBook Air, 8 GB, integrated GPU, 60 Hz**. Anything slower is out-of-scope for Phase ≤7.

| Metric | Budget | Notes |
|---|---|---|
| Main-thread frame time | ≤ 16.6 ms (60 FPS) at render distance 8 | 8 ms headroom at spawn |
| Main-thread chunk materialize | ≤ 4 ms p95 per chunk | Cap is 1 per frame already |
| Worker-thread chunk gen + mesh | ≤ 30 ms p95 per chunk | Runs off-thread; invisible to frame |
| Chunk load latency (spawn → visible) | ≤ 200 ms p95 | From enqueue to `add_child` |
| Resident memory at render distance 8 | ≤ 400 MB | ~225 chunks |
| GC / allocation spikes | No single-frame allocation > 1 MB | Catches untyped-GDScript traps |
| Startup time (headless) | ≤ 2.5 s to first rendered frame | Warm-start baseline |

**Render-distance ladder:** 3 (default, must run at 60 FPS on the baseline), 8 (stretch, must be playable), 12 (aspirational, ok if GPU-bound).

---

## 3. Instrumentation to add

All numbers come from `Time.get_ticks_usec()` + a tiny in-repo profiler, not external tools. Keep it always-on so we notice regressions during normal dev.

**New file: `scripts/dev/perf_probe.gd`** (class_name `PerfProbe`)
- `PerfProbe.begin(label)` → `int` token (start time)
- `PerfProbe.end(label, token)` → records sample
- Ring buffer of last N=512 samples per label
- `PerfProbe.snapshot() -> Dictionary` for tests / debug overlay
- Zero-overhead fast-path when `PerfProbe.enabled = false`

**Sites to instrument (all existing files):**

| File | Label | What it measures |
|---|---|---|
| `worldgen.gd:generate_chunk` | `worldgen.generate_chunk` | Full chunk gen (surface + ores + trees) |
| `worldgen.gd:_scatter_ores` | `worldgen.ores` | Ore pass alone |
| `worldgen.gd:_scatter_trees` | `worldgen.trees` | Tree pass alone |
| `mesher.gd:mesh_chunk` | `mesher.mesh_chunk` | Meshing per chunk |
| `chunk_manager.gd:_materialize_chunk` | `chunk_mgr.materialize` | Main-thread add_child + GPU upload |
| `chunk_manager.gd:_compute_chunk_data` | `chunk_mgr.worker_total` | Wall-clock of worker task |
| `chunk_node.gd:_apply_mesh_data` | `chunk_node.apply` | ArrayMesh build + trimesh shape |
| `chunk_manager.gd:_process` | `chunk_mgr.tick` | Per-frame chunk-streaming overhead |

**Queue-depth counters (gauges, not timers):**
- `chunk_mgr.pending_count` — workers in flight
- `chunk_mgr.ready_count` — results waiting to materialize
- `chunk_mgr.spawn_queue_size`

**Debug overlay (F3-style):**
- Extend the existing debug mode (backtick toggles) with a perf pane showing p50/p95 for each label + queue depths. Opt-in via a second keybind so regular play isn't cluttered.

---

## 4. Benchmark scenarios

Five reproducible scenarios, run headlessly via a new `tests/perf/` harness that exercises `Worldgen` / `Mesher` directly. No rendering needed for most of these — we want deterministic, reproducible numbers.

1. **Cold-gen throughput.** Generate 64 chunks at fresh coords on one worker. Report total ms, p50/p95 per chunk.
2. **Meshing throughput.** For the 64 generated chunks, call `Mesher.mesh_chunk` sequentially. Same stats.
3. **Streaming burst.** Spawn player at world origin, simulate render distance 8 (225 chunks loaded). Report wall-clock to "all chunks materialized" and peak pending/ready queue depth.
4. **Walk stress.** With the world loaded, translate the player by (+SIZE_X, 0) every 500 ms for 60 s. Report chunk materialize p95, any frame > 16.6 ms.
5. **Teleport stress.** Jump the player +10 chunks every 2 s. Measures eviction + re-stream correctness and memory stability.

Each scenario writes a JSON report to `tests/perf/out/{scenario}_{commit}.json`. Commit the schema, gitignore the output directory.

---

## 5. Data collection & CI

**Local:**
```sh
godot --headless --path . -s tests/perf/run_all.gd -- --out=tests/perf/out/
```
Produces a `report.json` plus a Markdown summary.

**CI (when we add it):**
- Run scenarios 1 + 2 on every PR (fast, < 30 s, no render).
- Compare against `main`'s last run. Fail the PR if p95 regresses > 20% on any label.
- Run scenarios 3–5 nightly (slower, needs a render loop).

**Historical tracking:**
- Keep the last 90 days of nightly reports in a `perf-history` branch or an external gist. Plot p95 over time; long-term drift surfaces things no single PR caused.

---

## 6. Decision gates

**Tier A — act immediately**
Any budget in §2 exceeded on baseline hardware.

**Tier B — queue for next slice**
p95 within 20% of budget, trending up over 3 consecutive nightly runs.

**Tier C — monitor only**
p50 shift with stable p95; probably benign, keep watching.

**GDExtension / C++ trigger**
A hot path remains > 2× budget after:
1. It's been tuned within GDScript (typed vars, PackedArrays, unchecked accessors, WorkerThreadPool).
2. At least one round of algorithmic improvement has been tried (e.g. greedy meshing before porting the mesher).
3. The gain from porting is estimated at ≥ 3× based on a spiked prototype, not a hunch.

Only then port that single function as a GDExtension module. Keep the GDScript version available behind an `@export var use_native_mesher := true` flag for A/B.

---

## 7. Optimization playbook (ordered)

When instrumentation flags a hot path, work down this list before reaching for a native port:

1. **Type everything.** Untyped GDScript is ~2–3× slower than typed.
2. **Pack loops.** Replace `Array` of `Vector3` with `PackedVector3Array`.
3. **Cache lookups.** Hoist `BlockAtlas.uv_rect(name)` out of inner loops; pre-resolve block→atlas-rect maps at startup.
4. **Skip bounds checks on trusted paths.** (Already applied to worldgen via `*_unchecked` accessors.)
5. **Avoid per-call allocations.** Reuse buffers; don't create `Array` / `Dictionary` inside a per-face loop.
6. **Data-orient hot state.** E.g. the parallel-match pattern in `Blocks` / `Items` → single dict lookup by id.
7. **Algorithm change.** Greedy meshing, cross-chunk face culling, heightmap caching — see `optimizations.md`.
8. **Move to worker thread.** Only if the work is pure and main-thread-visible today.
9. **Port to GDExtension C++.** See trigger above.

---

## 8. Known candidates (priority order)

Before we even measure, educated guesses at what will show up:

| Rank | Path | Why I suspect it |
|---|---|---|
| 1 | `Mesher.mesh_chunk` | ~18k `set_block`-equivalent iterations; untyped `_FACE_VERTS` arrays in inner loop |
| 2 | `Worldgen.generate_chunk` surface pass | 16×16×~70 per-block set (already partly optimized with unchecked) |
| 3 | `chunk_node._apply_mesh_data` | `create_trimesh_shape()` is main-thread; 10–100 ms on dense chunks |
| 4 | `BlockAtlas.uv_rect` | Called per-face in meshing (thousands of dict lookups) |
| 5 | `chunk_manager._update_chunk_set` | Rebuilds `needed` dict each frame; small but runs every tick |

None of these are confirmed problems. Ranked by gut + code inspection, not measurement. First deliverable of this plan is turning the above into numbers.

---

## 9. Milestones

- **M1 — instrumentation lands.** `PerfProbe` + the 8 instrumented sites + the debug overlay toggle. No behavior change. ~½ day.
- **M2 — perf harness.** `tests/perf/` with scenarios 1–2. JSON output format frozen. ~½ day.
- **M3 — baseline captured.** One clean run on baseline hardware per scenario. Committed to the repo as `tests/perf/baselines/{scenario}.json`. Any future PR must justify a p95 regression vs. baseline.
- **M4 — CI integration.** Per-PR regression check for scenarios 1–2. ~½ day once we have a CI provider chosen.
- **M5 — scenarios 3–5 in harness.** Render-in-the-loop, slower, nightly. ~1 day.
- **M6 — first optimization cycle.** Only after M3 shows real hotspots. Scope per the playbook in §7.

Do not start M6 before M3. Optimization without baseline is theater.

---

## 10. Explicit non-commitments

- We will **not** add Mono/C# to this project unless instrumentation flags a profile-driven need.
- We will **not** port meshing/worldgen to GDExtension C++ preemptively.
- We will **not** disable MSAA, shadows, or textures to "fix" a perf number until we've verified it's GPU-bound on the baseline device.
- We will **not** chase micro-optimizations (`is_opaque` inlining, prime-constant tweaks) without a measurement justifying them.

---

## Appendix — quick-start commands

Once M1 lands:

```sh
# Run with perf overlay on (backtick + F3)
godot --path . main.tscn

# Run the headless perf harness
godot --headless --path . -s tests/perf/run_all.gd -- --scenarios=1,2 --out=tests/perf/out/

# Diff vs. baseline
python tools/perf_diff.py tests/perf/baselines/ tests/perf/out/
```
