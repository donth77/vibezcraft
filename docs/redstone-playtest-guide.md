# Redstone Playtest Guide

Covers Phase 8 batches 1–4: the ore economy, the power model, the
lever, redstone wire, the torch inverter, and the button and pressure
plates — Alpha's complete redstone set, plus the Batch 5 hardening pass.
Everything below is implemented and covered by 583 passing tests — this pass is looking for the things a test suite
structurally cannot catch: how it *looks*, how it *feels*, and how it
behaves in a real streaming world rather than a fake one.

Commits under test: `4667c89`, `f791623`, `ab5e574`, `982253d`,
`9839e7d`, `1768516`, `844bf17`, `f6f3972`, `e044218`, `46426dd`. All
local — nothing pushed.

---

## Before you start

**Use a fresh world.** Chunks you've already visited are persisted, so
previously explored areas of an existing save will have no redstone ore
in them. That's expected, not a bug.

| Key | What |
|---|---|
| `F4` | Item spawner (the grid you'll pull everything from) |
| `G` or `F1` | Creative mode — flight, instant break |
| `F3` | Debug overlay — coordinates, looked-at block |
| `F6` | Mob spawner (only needed for one optional test) |

**Grab from `F4` before you begin:** redstone dust, lever, redstone
torch, stone button, both pressure plates, redstone ore, glowing
redstone ore, stone, cobblestone, a wooden door, an iron door, TNT, an
iron pickaxe, a stone pickaxe, iron ingots, gold ingots, and a
half-slab.

Run the desktop build with `godot --path . main.tscn`.

---

## Track A — Ore economy

Dig or fly down to **Y 8–14**. Redstone sits in the same deep band as
diamond but is 8× more common, so you should hit veins quickly.

| # | Do this | Expect |
|---|---|---|
| A1 | Look around the deep band | Red-speckled ore in veins of roughly 4–8 blocks. Nothing above Y 16. |
| A2 | **Walk** across an exposed ore block | Red sparkle particles, and the block visibly lights up |
| A3 | **Punch** an ore block (hold left-click) | Sparkles immediately, before the block breaks |
| A4 | **Right-click** an ore block while holding a torch | Sparkles *and* the torch still places — the sparkle must not eat the click |
| A5 | Glow one in a dark cave | A real pool of light around it, dimmer than a torch |
| A6 | Break a glowing one | The light disappears cleanly — no stuck bright patch, no dark square |
| A7 | Glow ore embedded in a wall | Sparkles only on the exposed face(s), never through solid stone |
| A8 | Glow one and walk away, count | Goes dark on its own in roughly **15–25 seconds** |
| A9 | Re-touch a lit one repeatedly | Re-sparkles, but the timer must not extend or stack |
| A10 | Mine with an **iron** pickaxe | **4 or 5** dust — both counts should show up across several breaks |
| A11 | Mine with a **stone** pickaxe | Block breaks, **zero** dust |
| A12 | Mine with bare hands | Nothing |
| A13 | Mine a *glowing* one | Still 4–5 dust |
| A14 | Craft: iron ring + dust in the middle | Compass (needle should track spawn) |
| A15 | Craft: gold ring + dust in the middle | Clock (dial should track time of day) |

**Optional (`F6`):** spawn a pig or chicken next to exposed ore and let
it wander across. Mobs are walking entities too, and this is the one
contact path with no automated coverage.

---

## Track B — Power basics: lever, doors, TNT

This is the model everything else rests on. Test it before wire.

| # | Do this | Expect |
|---|---|---|
| B1 | Place a lever on a **wall**, right-click it | Handle visibly flips; click sound pitches **up** on, **down** off |
| B2 | Place a lever on the **floor** | Works too. Place several — the ground rotation is **randomised** per placement, so they won't all face the same way. That's vanilla. |
| B3 | Lever directly beside an **iron door**, flip it | Door opens |
| B4 | Punch that iron door by hand | Still refuses to open — iron doors stay hand-immune |
| B5 | Lever beside a **wooden door** | Opens on power, closes when you flip it back |
| B6 | Put the lever on a **stone block**, door on the *far side* of that block | Door opens. This is indirect power relaying through a solid cube — the subtlest part of the model |
| B7 | Swap that stone for a **half-slab** or **stairs**, retry | Does **not** work. Non-cubes never conduct |
| B8 | Two solid blocks between lever and door | Does **not** work. The relay is one block only — Alpha has no repeater |
| B9 | Lever beside **TNT**, flip it | TNT primes with the normal fuse and detonates |
| B10 | Break the block a lever is mounted on | Lever pops off as an item |
| B11 | Power a door, then flip the lever off and on repeatedly | Door tracks it every time, no stuck states |
| B12 | Lever on the **side of a block**, wire running along the ground **past the base of that block** | Wire lights up. This is the most common circuit in the game and it was broken until the last audit pass — worth an extra minute |
| B13 | Same, but flip the lever back off | Wire goes dark again |

---

## Track C — Redstone wire

Place wire by **right-clicking the top of a solid block with redstone
dust**. Wire needs a full solid cube underneath it.

### C1 — The decay oracle

Lay a **straight line of 16 wire** on flat stone, and put a lever at one
end (on a block adjacent to the first wire cell).

Flip the lever on. Walking the line from the source outward, the wire
should be at full strength at the source and completely dark at the far
end — 15 steps of decay, one per block. The 16th cell and anything
beyond it is unpowered.

Flip the lever off: **the entire line goes dark.**

### C2 — Shape and appearance

| # | Do this | Expect |
|---|---|---|
| C2a | Lay a straight run | Wire renders as a thin line along the run's axis |
| C2b | Make a corner, a T, and a 4-way cross | Renders as a cross shape, not a line |
| C2c | Place a single isolated wire | Cross shape |
| C2d | Toggle the lever with wire visible | Texture swaps **unpowered ↔ powered**, binary. There is deliberately **no** brightness gradient along the run — that's a Beta feature, and Alpha doesn't have it |
| C2e | Run wire up against a solid block that has wire on top of it | Dust visibly climbs the side of that block |

### C3 — Vertical routing

| # | Do this | Expect |
|---|---|---|
| C3a | Wire up a single-block **step up** (staircase) | Power climbs the step |
| C3b | Put a solid block *directly over* the wire just before the step, retry | Power does **not** climb. Roofed wire can't step up — this asymmetry is vanilla |
| C3c | Wire down a single-block **step down** | Power drops down |
| C3d | Block the side of that drop with a solid block | Power does **not** drop |

### C4 — Driving things

| # | Do this | Expect |
|---|---|---|
| C4a | Run wire from a lever into a door | Door opens, and closes when you flip off |
| C4b | Run wire *over* a solid block with a door beside that block | Door opens — wire powers the block beneath it |
| C4c | Run wire into TNT | Primes |
| C4d | Corner the wire so it turns immediately before the door | Corners feed nothing sideways — run the last stretch **straight** into what you're driving. This is genuine Alpha behavior, not a bug |
| C4e | Break the block under a run of wire | That wire pops off as dust |

### C5 — Streaming and persistence

This is where a real world differs from a test harness — pay attention
here.

| # | Do this | Expect |
|---|---|---|
| C5a | Build a wire run that **crosses a chunk boundary** (`F3` shows coords; boundaries are every 16 blocks) | Renders connected across the seam and conducts through it |
| C5b | Walk far away until those chunks unload, come back | Still correct, still powered |
| C5c | Save and quit, reload the world | Circuit is exactly as you left it |
| C5d | Build a circuit spanning **3 chunks**, quit, reload, flip the lever | Works end to end |
| C5e | Leave a lit ore glowing, save, reload | It still reverts afterward |

---

## Track D — Redstone torch

The torch is Alpha's **inverter** and its **only** timing primitive.
Every logic gate in Alpha is built out of these two facts.

| # | Do this | Expect |
|---|---|---|
| D1 | Place a redstone torch on a wall or floor | Lights up, casts light (dimmer than a normal torch) |
| D2 | Power the block it's attached to (lever on that same block) | Torch turns **off** — that's the inversion |
| D3 | Watch closely when you flip the lever | The flip is not instant: it lands 2 ticks (~0.1 s) later |
| D4 | Flip the lever back off | Torch relights |
| D5 | Torch on a wall, wire running away from it | Wire is powered while the torch is lit |
| D6 | Put a torch **under** a solid block, wire on **top** of that block | Wire reads full strength. This is the classic Alpha circuit — the torch strong-powers only the block directly above it |
| D7 | Run wire into a block, torch on the far side of that block | You've built a **NOT gate**: wire on = torch off |
| D8 | Break the block a torch is mounted on | Torch pops off as an item |
| D9 | Mine a torch while it's **off** | You still get a normal (lit) redstone torch back |

### D10 — Burnout (the fun one)

Build a torch that feeds its own mount block through one wire — a
feedback loop. It will oscillate, and then **burn out**: 8 off-transitions
inside 100 ticks kills it. Expect a fizz sound, a puff of particles, and
the torch going dark and staying dark. Wait a few seconds and it should
**recover** on its own.

A torch that toggles slowly (well spaced out) must never burn out.

---

## Track E — Button and pressure plates

| # | Do this | Expect |
|---|---|---|
| E1 | Try to place a button on the **floor** | Rejected — buttons are wall-only in Alpha |
| E2 | Place a button on a **wall**, right-click it | Sinks in visibly, click sound |
| E3 | Time it | Releases itself after almost exactly **1 second** |
| E4 | Right-click it again while held | Nothing — presses don't stack or extend |
| E5 | Button beside a door | 1-second auto-close door |
| E6 | Stand on a **wooden** plate | Presses; releases when you step off |
| E7 | Stand on a **stone** plate | Same |
| E8 | **Drop an item** onto a wooden plate | **Presses** — wooden plates take everything |
| E9 | **Drop an item** onto a stone plate | Does **not** press — stone plates take living entities only. This difference is the whole reason both plates exist |
| E10 | Let a mob (`F6`) walk onto a stone plate | Presses |
| E11 | Stand in the cell **next to** a plate, pressed right up against it | It may still trip, and that's correct: vanilla compares your whole collision box against the plate's box, not your feet against its cell. A small item in the same spot won't |
| E12 | Jump straight up off a plate | Releases |
| E13 | Plate wired to a door down a corridor | Door opens as you approach |
| E14 | Break the block under a plate | Plate pops off as an item |

---

## Track F — Hardening and world events

These are the cases a fake test world can't reach. They're the highest
value checks in the whole guide.

| # | Do this | Expect |
|---|---|---|
| F1 | Build a powered circuit, walk away until the chunks unload, come back | Still in the correct state |
| F2 | Powered wire run crossing a chunk seam — quit, reload, **then flip the lever off** | The whole run goes dark, both sides of the seam |
| F3 | Leave a lever **on**, quit, reload | Wire is still powered on load, not stale-dark |
| F4 | Blow up the lever driving an open door (TNT next to it) | Door closes — losing the source de-powers what it fed |
| F4b | Same, but with the door on the **far side of the block the lever is mounted on** | Door still closes. This is the harder version — the door is two cells from the lever, outside its own update radius |
| F5 | Pour water over a run of wire | Wire washes away and drops as dust |
| F6 | Pour water over a torch, button, or plate | Same — they're flimsy attachments in Alpha |
| F7 | Pour water over redstone **ore** | Ore is unaffected. It's an ordinary solid block |
| F8 | Leave a button pressed, quit, reload | It still releases afterward — pending ticks survive with their remaining delay, not a fresh full delay |
| F9 | Build a rail junction with **exactly 3** connected rails, then flip a lever next to it | The junction re-curves the moment power changes, and back again when it's cut. Extremely obscure — this is the only way redstone touches rails in Alpha |
| F10 | Do the same with a **4-way** rail crossing | Nothing happens. Vanilla only re-shapes 3-connection junctions (`oc.a(...) == 3` is an equality) |
| F11 | Stand a **minecart** on a wooden pressure plate, then a stone one | Wood fires, stone doesn't — stone plates only detect living things |
| F12 | Drop an **item** onto a wooden plate, and shoot an **arrow** into one | Both fire it. Both leave a stone plate alone |

---

## Deliberate deviations — please don't report these as bugs

| What you'll see | Why |
|---|---|
| Wire has no colour gradient by power level | Alpha uses a binary texture swap; the red gradient is a Beta addition |
| A corner/T/cross wire doesn't power sideways | Vanilla `lu.java` — only straight runs feed past their ends, plus the block below |
| Ore is confined to Y 1–16 | Our shared ore pipeline clamps final cells; vanilla's vein can spill slightly higher |
| Lit ore reverts on a ~20 s timer | Vanilla uses its random-tick sweep; our tick budget differs, so the duration is matched explicitly |
| Floor levers face random directions | `pl.java` really does roll for it; player-facing orientation came later |
| Lever handle is a two-position box | Reads correctly, but isn't a pixel-exact rotated model — easy to refine if it bothers you |
| Only one block of relay through solids | Correct: Alpha has no repeater |
| Torch burnout puffs red motes, not grey smoke | We have no generic smoke emitter yet; the sound and timing are vanilla |
| Buttons refuse to go on floors or ceilings | `iy.java` checks only the four horizontal neighbours |
| Plate recipes are 2 wide, not 3 | Vanilla's 3-wide plates collide with our slab recipes — Alpha's slab is cobblestone-based, ours is stone |
| A long run takes a moment to go fully dark | Depowering ripples cell by cell rather than snapping off. Vanilla's recursion does the same — it's why big old-Minecraft circuits visibly drain |

---

## Known gaps

- **Performance is measured headlessly, not in-engine.** All figures
  below come from `tests/test_redstone_performance.gd` on a fake world
  (Godot 4.6.2, macOS 26.4.1, Apple M2 Max, debug build). They are not
  frame times from a running session, which is the measurement only your
  playtest can take.

  | Case | Result |
  |---|---|
  | Settled circuit, 100 neighbour updates | median **10 µs**, p95 **12 µs** |
  | 1,024-cell field powering up from dark | **2,047** relaxations, ~18 ms total |
  | 1,024-cell field depowering (every source pulled at once) | **16,012** relaxations, ~530 ms of work, spread over **~245 frames** |
  | Worst single frame during that depower | median **2.24 ms**, p95 **2.63 ms** |

  The thing to take from the table: a settled circuit is free, an
  ordinary edit finishes inside one frame, and even a deliberately
  absurd 1,024-cell field never blocks a frame for more than about
  2.5 ms — it just takes a few seconds of visible draining to finish.
  Vanilla behaves the same way, which is why big old-Minecraft circuits
  visibly drain rather than snapping off.
- **The web export has not been rebuilt or smoke-tested** with any of
  this. No native code changed, so no wasm rebuild is required for
  correctness, but the browser build hasn't been exercised.
- **No interactive desktop session has been run.** Everything below the
  logic layer — how it looks, how it sounds, how it feels — is
  unverified by construction. That is what this guide is for.

---

## Remaining validation

**All nine Alpha redstone blocks are in, and every batch's automated
gate passes.** What is still genuinely open is the part automation
can't reach:

| Area | Status |
|---|---|
| Power model, wire decay, torch timing, burnout | **pass** — exact oracles, checked against the decompile |
| Convergence on a 1,024-cell network | **pass** — `tests/test_redstone_performance.gd` |
| Entity contact on plates (player, mobs, items, arrows, carts) | **pass** — real coordinates, `tests/test_entity_bounds.gd` |
| Fluid washout drops | **pass** — real flow, `tests/test_fluid_washout.gd` |
| Rail tie-break and its runtime re-evaluation | **pass** — `tests/test_rail_shape.gd` |
| Notification queue budget, dedup, resume | **pass** — `tests/test_redstone_state.gd` |
| Every visual, every sound, every feel question | **manual pending** — this guide |
| Real save/reload across a session boundary | **manual pending** — Track F |
| In-engine frame cost of a large circuit | **manual pending** — headless only so far |
| Web export | **not tested** |

Things that were never in Alpha and are deliberately absent: repeater,
dispenser, note block, piston, powered/detector rail, trapdoor.

---

## Known pre-existing issues (not from this work)

- **Occasional crash on quit.** A teardown race in the static mob
  dictionaries (`MobBase._active_mobs` / `_sep_grid`). Predates all
  redstone work, happens after the world is already saved, and doesn't
  reproduce every time. Worth fixing separately.
- **`[STUCK]` mob lines in the log.** Diagnostics from the earlier
  fall-through hardening pass, not errors.

---

## What the pre-playtest audit already found

I audited the implementation against the decompile and benchmarked it
before handing this over, so a few things you might otherwise have hit
are already fixed:

- **Propagation was O(total network size)** rather than O(what changed).
  A lever flip on a 16-wire line dropped a frame; a large circuit would
  have frozen the game for over a second.
- **Standing on a pressure plate grew the tick queue on every
  footstep** — vanilla ignores contact on an already-pressed plate and
  we weren't.
- **Every block id change fanned out its neighbour updates twice.**

A second, deeper audit then found four more — and these are the ones
worth knowing about, because three of them would have wasted your
session outright:

- **Pressure plates could not be triggered by anything.** Detection
  compared a plate's 0.25 m-tall box against an entity's *origin point*,
  and the player's origin is the centre of a 1.8 m capsule — about
  0.9 m above the feet, always outside the box. Every plate test passed,
  because each one put its fake sample point inside the box. Now uses
  real collision bounds, and items/arrows/carts/boats have a contact
  route too. **Track E was untestable before this.**
- **A lever on a wall did nothing to wire on the floor beside it.** The
  single most common circuit in the game. Vanilla notifies twice when a
  switch flips — around itself *and* around the block it is mounted on
  — and that second fanout is the only thing that carries strong power
  out to the mount's other neighbours. We only did the first. Buttons,
  plates and torches had the same gap.
- **Water deleted redstone instead of washing it off.** Vanilla hands
  the displaced block to the drop path; we skipped it. Dust, torches,
  levers, buttons and plates are all recoverable again. **F5/F6 would
  have failed.**
- **Wire propagation discarded work at a fixed 8,192-step cap**, leaving
  large networks permanently half-powered. Bursts now pause and resume
  across frames with their queue intact, and hold their notifications
  until the network actually settles.

Two smaller parity gaps went with them: buttons and plates were missing
from the power-source set (so wire rendered as unconnected beside them
and mis-applied its isolated-wire output rule), and TNT could be
detonated by an unrelated neighbour edit because the changed-neighbour
guard wasn't implemented.

Worth knowing because it means the *logic* has now been checked three
times over — by tests, against the source, and by a second adversarial
pass. What remains genuinely unverified is everything visual and
everything about feel, which is exactly what your session is for.

---

## Reporting back

For anything that looks wrong, the most useful things to tell me are:

1. **Which item number** (A7, C3b, …) — that pins the expected behavior
2. **The layout** — what was next to what, and which way things faced
3. **Whether it's visual or behavioral** — wrong appearance vs wrong result
4. Whether it survived a **reload**

Visual polish (particle size, wire tile alignment, lever handle shape,
click volume) is quick to adjust — flag anything that reads oddly even
if it technically works.
