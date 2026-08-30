# Nether Playtest Guide

Covers the whole Nether feature — dimension isolation, Alpha-exact
terrain and caves, the four new blocks, portals and two-way travel, the
zombie pigman, the ghast and its fireball, and natural spawning.
Everything below is implemented and covered by the automated suite; this
pass is looking for what a test suite structurally cannot catch: how it
looks, how it feels, and how it behaves in a real streaming world rather
than a fake one.

Commits under test: `15fce5f`, `b64f0fc`, `f325b3e`, `e8d04ed`,
`8572b2f`, `6c4ba70`, `6093542`, `0ce2533`, `a08dc75`, `a27d5b8`, and
the Batch 10 commit this guide ships with. All local — nothing pushed.

---

## Before you start

**Use a fresh world**, or at least be ready to walk somewhere you have
never been. Chunks you have already visited are persisted, so an
existing save has no Nether at all until you build a portal, and its
Overworld chunks will not change.

| Key | What |
|---|---|
| `F4` | Item spawner — where you pull obsidian, flint and steel, etc. |
| `F6` | Mob spawner — pigman and ghast are the last two entries |
| `G` or `F1` | Creative — flight, instant break, no fall damage |
| `F3` | Debug overlay — coordinates, looked-at block, FPS |

**Grab from `F4` before you begin:** obsidian ×20, flint and steel, a
diamond pickaxe, a bow and arrows, a bucket, a water bucket, a bed, a
compass, a clock, and a stack of cobblestone.

Run the desktop build with `godot --path . main.tscn`.

**The Nether has audio.** All twelve portal, pigman and ghast sound
events play, at their Alpha volume and pitch. Listen for them as you go:

| Sound | When |
|---|---|
| `portal.portal` | A lit portal's hum, one display tick in a hundred |
| `portal.trigger` / `portal.travel` | Stepping in, and completing the trip |
| `mob.zombiepig.zpig` ×4 | Pigman idle |
| `mob.zombiepig.zpigangry` ×4 | The shout when a group turns on you |
| `mob.zombiepig.zpighurt` ×2, `zpigdeath` | Hitting one, killing one |
| `mob.ghast.moan` ×7 | Ghast idle — seven clips, so it never loops |
| `mob.ghast.scream` ×5, `death` | Hitting one, killing one |
| `mob.ghast.charge` / `fireball4` | Charge counter 10, and the shot at 20 |

A ghast plays at ten times a normal mob's volume — that is Alpha's
`h()`, not a bug. If any of these is silent, it is a real failure now;
`tests/test_nether_audio.gd` asserts every path resolves.

---

## Track A — Building and lighting a portal

Stand somewhere flat with headroom.

| # | Do this | Expect |
|---|---|---|
| A1 | Build a 4-wide × 5-tall obsidian ring, leaving the 2×3 interior empty. Skip the four **corners** entirely | The frame looks incomplete — that is correct, Alpha never tests the corners |
| A2 | Right-click the bottom interior block with flint and steel | The interior fills with a swirling purple sheet. No fire block is left behind |
| A3 | Walk up to it | Particles drift out of the surface, perpendicular to the sheet, on both sides |
| A4 | Look at it edge-on | A thin slab, about a quarter of a block — not a flat billboard, not a full cube |
| A5 | Walk into the portal cell | You pass straight through. No collision, no selection outline, no break progress |
| A6 | Try to mine it | Nothing happens at all |
| A7 | Now fill one corner with cobblestone and light a second frame | Lights identically — corners are irrelevant either way |
| A8 | Build a frame on the **other** horizontal axis and light it | Works the same; the sheet faces the other way |

**Fails if:** the frame needs its corners, fire survives inside a lit
portal, the portal blocks movement or can be mined, or the sheet renders
as a full cube.

---

## Track B — Breaking a portal

| # | Do this | Expect |
|---|---|---|
| B1 | Break one obsidian block from the side of a lit frame | The whole sheet disappears |
| B2 | Rebuild, light it, then build a SECOND portal sharing a wall one block away | Both light |
| B3 | Break a frame block belonging to only one of them | Only that one dissolves. The other is untouched |

**Fails if:** breaking one portal takes its neighbour with it, or if
cells linger after their frame is gone.

---

## Track C — Travel

Turn creative OFF for C1–C4 so the timing is honest.

| # | Do this | Expect |
|---|---|---|
| C1 | Stand still inside the portal and count | About four seconds before the screen changes — 81 ticks |
| C2 | Repeat, but step out after two seconds and back in | The meter drains four times faster than it fills, so the second attempt takes noticeably longer than four seconds from re-entry |
| C3 | Walk straight through without stopping | Nothing happens. A pass-through never travels |
| C4 | Let it complete | Loading screen reading **"Entering the Nether"**, then a red-lit cave. You arrive standing in a portal |
| C5 | Do not move | You do NOT immediately bounce back — the ten-tick cooldown holds |
| C6 | Note your Overworld and Nether coordinates with `F3` | Nether X/Z are one eighth of the Overworld's. Y is unchanged |
| C7 | Step back into the arrival portal and wait | **"Leaving the Nether"**, and you come out at or very near the portal you left from |
| C8 | Travel down again, walk 200 blocks, build and light a new portal, go through | You arrive in the Overworld ~1600 blocks from the first portal |
| C9 | Go back through that second portal | You return to the second Nether portal, not the first |

**Fails if:** travel takes wildly more or less than four seconds, a
walk-through teleports you, you bounce back and forth on arrival, the
loading label is generic, or the 8:1 scaling is wrong in either
direction.

---

## Track D — Save and restart, both sides

| # | Do this | Expect |
|---|---|---|
| D1 | In the Nether, place a few cobblestone blocks and drop an item | Normal behaviour |
| D2 | Pause → Save and quit. Reload the world | You resume **in the Nether**, at the same spot, with your inventory, your blocks and the dropped item |
| D3 | Travel to the Overworld, save and quit, reload | You resume in the Overworld |
| D4 | Go back through | The same Nether portal, and your blocks from D1 are still there |
| D5 | Check the save directory: `user://World{N}/` | A `DIM-1/` subdirectory holds the Nether's `region/` and `entities.bin`. The Overworld's files are still at the world root, unmoved |

**Fails if:** a restart puts you in the wrong dimension, blocks or
entities are lost, or Overworld save files were relocated.

---

## Track E — The four new blocks

| # | Do this | Expect |
|---|---|---|
| E1 | Look at the Nether floor and walls | Netherrack everywhere, a distinctly red rock |
| E2 | Mine netherrack with a pickaxe | Fast — hardness 0.4 |
| E3 | Set fire on top of netherrack with flint and steel | It burns **forever**. Come back later and it is still burning |
| E4 | Find soul sand (brown, speckled) and walk across it | You sink slightly and move noticeably slower. Your jump height is unchanged |
| E5 | Find glowstone on a ceiling | It glows brightly — light level 15 |
| E6 | Break glowstone | Exactly ONE glowstone dust, never the block, never 2–4 |
| E7 | Craft 9 dust in a 3×3 | One glowstone block |
| E8 | Try 4 dust in a 2×2 | No recipe. That is the modern one |
| E9 | Place all four blocks in the Overworld and check icons in the hotbar and inventory | All four render as baked 3D block icons; glowstone dust is a flat sprite |
| E10 | Hold each in first and third person, and drop each on the ground | Blocks render as cubes; dust renders as an extruded sprite |

**Fails if:** fire on netherrack goes out, soul sand changes jump
height, glowstone drops more than one dust, or any icon is missing or a
magenta placeholder.

---

## Track F — Environment

| # | Do this | Expect |
|---|---|---|
| F1 | Look up in the Nether | No sky, no sun, no moon, no stars, no clouds. A dark red fog closes in |
| F2 | Stand in an unlit corner | Gloomy, not pitch black. An unlit Nether cell is about twice as bright as an unlit Overworld one |
| F3 | Wait several minutes | Nothing changes. There is no day/night cycle down here |
| F4 | Empty a water bucket | It evaporates instantly with a hiss. No water block is placed |
| F5 | Place lava and watch it spread | It reaches much further than Overworld lava — seven blocks rather than three |
| F6 | Right-click a bed | A message; you do NOT sleep, time does NOT pass, and your spawn point does NOT move. The bed does not explode — Alpha 1.2.6 has no exploding bed |
| F7 | Hold a compass, then a clock | Both spin aimlessly. Two compasses would disagree with each other |
| F8 | Take the compass and clock back to the Overworld | Both work normally again |

**Fails if:** a sky or sun renders, unlit cells are pure black, water
places, a bed works or explodes, or the instruments still point true.

---

## Track G — Zombie pigman

Spawn one with `F6` if you cannot find one, or wait — they are common.

| # | Do this | Expect |
|---|---|---|
| G1 | Walk right up to a pigman and stand there | It ignores you completely. Neutral means neutral |
| G2 | Look at it | It holds a golden sword out in front of it, arms locked horizontal like a zombie |
| G3 | Back off and watch it wander | An unhurried amble |
| G4 | Hit it once | It turns on you — and so does **every other pigman within 32 blocks**, including ones you cannot see |
| G5 | Watch its speed now | Almost twice as fast. It will run you down |
| G6 | Run away and hide for a full minute, then come back | Still hostile. Alpha has no forgiveness timer; that grudge is permanent |
| G7 | Save and quit, reload, find it again | Still hostile |
| G8 | Let it hit you | Five damage — two and a half hearts. It hurts |
| G9 | Lure one into lava, or set it on fire | Completely unharmed. No flames render on it at all |
| G10 | Kill one | 0–2 cooked porkchops. Never the sword, never gold |
| G11 | Watch a pigman at 30 m, then 60 m, then 120 m | Still holding its sword at every distance it is visible at |

**Fails if:** a pigman attacks unprovoked, the group does not react, it
calms down over time, it burns, or it drops its sword.

---

## Track H — Ghast

`F6` → ghast. Do this over open space.

| # | Do this | Expect |
|---|---|---|
| H1 | Spawn one | It appears in **open air**, not embedded in the ceiling or floor |
| H2 | Watch it with no player nearby (fly away and look back) | It drifts aimlessly, changing course every few seconds. Nine tentacles trail beneath it and sway |
| H3 | Approach to within 64 blocks with a clear line of sight | It turns to face you |
| H4 | Keep watching | It puffs up — wider and flatter — and its face turns red |
| H5 | Keep still | It fires a fireball. Then it visibly relaxes and takes about three seconds before it can start charging again |
| H6 | Break line of sight mid-charge (duck behind a pillar) | The charge winds back DOWN rather than resetting; the red fades |
| H7 | Let a fireball hit terrain | A small explosion — about a third of TNT — and scattered fires on the exposed floor |
| H8 | Hit a fireball with anything (sword, fist, arrow) | It reverses along your look direction |
| H9 | Deflect one back into the ghast | A point-blank power-1 blast is 9 damage against 10 health — it drops to its last half-heart. A second deflection or one arrow finishes it. (Alpha has no modern one-shot deflection kill) |
| H10 | Shoot a ghast with a bow | Two arrows |
| H11 | Set one on fire, or fly it into lava | Unharmed |
| H12 | Kill one | 0–2 gunpowder. Never a ghast tear — those do not exist in Alpha |
| H13 | Fire a fireball into open sky and follow it | It keeps going. There is no time-to-live |

**Fails if:** a ghast spawns inside terrain, chases you like a zombie,
fires without line of sight, survives more than two solid hits, burns,
or drops tears.

---

## Track I — Natural spawning

Turn creative off, find an unexplored area, and just exist for a few
minutes.

| # | Do this | Expect |
|---|---|---|
| I1 | Explore the Nether and note every mob you see | **Only** zombie pigmen and ghasts. Nothing else, ever |
| I2 | Look specifically for pigs, cows, sheep and chickens | None. There is no passive list at all down here |
| I3 | Look for zombies, skeletons, spiders, creepers, slimes | None |
| I4 | Stand in a brightly lit area — beside lava, or under glowstone | Pigmen still spawn. There is no light gate in the Nether |
| I5 | Count pigmen in one place | Groups of up to four |
| I6 | Count ghasts | Always alone, never a pair |
| I7 | Go back to the Overworld at night | Zombies, skeletons, spiders and creepers, exactly as before. Nothing about Overworld spawning has changed |
| I8 | Check the Overworld in daylight in a lit area | No hostiles. The light gate is still there where it belongs |

**Fails if:** any Overworld mob appears in the Nether, any passive mob
appears in the Nether, ghasts appear in pairs, or Overworld spawning
behaves differently from before this feature.

---

## Track J — Streaming and stress

| # | Do this | Expect |
|---|---|---|
| J1 | Sprint 500 blocks in a straight line through the Nether | Terrain streams in without visible seams between chunks. Ceilings and floors line up |
| J2 | Watch the fog line as chunks load | No flashing, no holes, no chunks appearing lit wrongly and then correcting |
| J3 | Fly up to Y 127 | A solid bedrock roof |
| J4 | Dig down to Y 0 | A solid bedrock floor. Below the lava sea at Y 31 |
| J5 | Travel back and forth through a portal ten times in quick succession | No duplicate mobs, no leftover Overworld terrain, no growing memory, no stalls beyond the loading screen |
| J6 | Do J5 while a ghast is mid-charge and a fireball is in flight | Everything is cleanly gone on the other side |
| J7 | Watch FPS on `F3` during a fight with several pigmen and a ghast | Comparable to an equivalent Overworld night fight |

**Fails if:** chunk seams appear, mobs duplicate across a transition, or
frame time degrades noticeably relative to the Overworld.

---

## Track K — Texture packs

Repeat a short slice of Tracks E and G in each pack. Switch with
`MC_CLONE_TEXTURE_PACK=<pack> godot --path . main.tscn`.

| # | Pack | Expect |
|---|---|---|
| K1 | `alpha_vanilla` | Every Nether texture is the extracted Alpha art |
| K2 | `programmer_art` | Every Nether texture resolves — through the pack's own file or the documented `alpha_vanilla` fallback |
| K3 | `pixel_perfection` (default) | Same: no magenta placeholders, no missing mob textures, no untextured portal |

**Fails if:** any pack shows a placeholder or an untextured surface for
netherrack, soul sand, glowstone, glowstone dust, the portal, the
pigman, or either ghast texture.

---

## Reporting

For anything that fails, note: the track and row, your coordinates and
dimension, the texture pack, and whether creative was on. A screenshot
of `F3` at the moment of failure is worth more than a description.
