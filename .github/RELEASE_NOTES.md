# VibezCraft 1.1.0

VibezCraft 1.1.0 is a major update. Everything below is new or changed since 1.0.1. The biggest additions are the Nether and a full Alpha-era redstone system, plus the redstone repeater from Beta 1.3.

This release also adds controller support, touch controls for web builds, new recovery tools, and many improvements to lighting, combat, physics, saving, and performance.

## Explore the Nether

- Build an obsidian portal, light it with flint and steel, and stand inside to travel between dimensions. Nether travel uses the classic 8:1 distance scale.
- The Nether has its own terrain, caves, lava seas, bedrock roof, lighting, fog, and saved world data.
- New blocks include netherrack, soul sand, and glowstone. Fire burns forever on netherrack, soul sand slows movement, and glowstone drops dust that can be crafted back into a block.
- Water buckets evaporate in the Nether, beds cannot be used there, and lava spreads farther than it does in the Overworld.
- Zombie pigmen are neutral until attacked. Hitting one also angers nearby pigmen.
- Ghasts fly through open caves and shoot fireballs. Fireballs can be knocked back at them.
- Portals, ghasts, and zombie pigmen have their original Alpha sound sets. Portals also have animated textures, screen effects, and travel sounds.
- Blocks, mobs, dropped items, and portal locations are saved separately for each dimension. Projectiles and other moving entities no longer leak across transitions.

## Build with redstone

- Redstone ore now generates deep underground. It lights up and gives off particles when touched, then drops redstone dust when mined with an iron or better pickaxe.
- Redstone wire carries a signal from strength 15 down to 1. It can branch, climb blocks, cross chunk borders, and keep its state after saving and loading.
- Levers provide steady power. Stone buttons provide a short pulse.
- Stone pressure plates react to players and mobs. Wooden pressure plates also react to dropped items, arrows, boats, and minecarts.
- Redstone torches act as inverters. They use the classic two-tick delay and can burn out when switched too quickly.
- Power can open wooden and iron doors, prime TNT, and choose the branch at an ambiguous rail junction. This release does not add powered rails.
- The redstone repeater is now craftable and placeable. It accepts power from the back, sends a full-strength signal from the front, and has four delay settings. Right-click it to change the delay.
- Redstone parts have proper recipes, names, icons, held-item models, dropped-item models, sounds, particles, and entries in the item spawner.
- Circuits update across chunk borders and recover correctly after loading. Water can wash away attached redstone parts, while explosions can break a circuit and turn off its outputs.

## More ways to play

- Controllers now work on desktop and web builds. The default layout follows the familiar Bedrock-style controls for movement, looking, combat, inventory, hotbar selection, perspective, dropping items, and pausing.
- Controller bindings have their own section in the Controls menu. Controller and keyboard bindings can be changed without overwriting each other.
- Web builds now support touch controls, touch look sensitivity, fullscreen controls, and phone-friendly performance settings.
- Touch inventory controls include tap, drag, take half, place one, quick close, and drop gestures.
- Opening an inventory or menu now stops movement and jumping input from affecting the player behind the screen.

The downloads below are desktop builds. The web and touch work is available when building the project from source.

## Get unstuck and protect your world

- A new **Pause → Options → Unstuck / Debug** screen shows a debug report and a rolling event log.
- **Teleport to Spawn** safely returns you to the world spawn if you become trapped or fall through the terrain.
- **Copy Debug Log** copies recent spawn, chunk, collision, fall, teleport, and recovery events so they can be pasted into a bug report.
- The game can now recover a player who becomes stuck inside solid blocks. It also checks the voxel floor directly when chunk collision is missing or still loading.
- Corrupt saved chunks are rebuilt from the world seed instead of loading as empty holes.
- Saving is more reliable for fluids, containers, pending block updates, chunk unloads, and dimension changes.
- Dropped items now take damage from fire and lava, and water can put them out. A normal death still drops your items so you can return and collect them before they despawn.

## Gameplay and visual improvements

- Spiders can climb walls, using the behavior added in Beta 1.5.
- Mob attacks and arrows now knock the player back.
- Hit sounds only play when an attack deals damage. Placing a block now swings the player's arm.
- Hearts flash when damage is taken and shake when health is very low.
- Sand and gravel settle during world generation, fall as soon as they lose support, and sink through liquids instead of floating above them.
- Day and night lighting now follows Alpha's light-level rules. Chunk borders, cave edges, mobs, dropped items, particles, water, lava, and held blocks use the same lighting model.
- Mob lighting no longer flickers between nearby mobs, and one primed creeper no longer makes every creeper flash.
- Clouds have complete sides, more natural day and night colors, and better distance fog.
- Water splashes, drowning bubbles, boat wakes, lava pops, redstone dust, torch smoke, and portal particles now behave more like the original game.
- Paintings render correctly in exported builds, and the player head texture wraps cleanly around the model.
- Mob swimming, sinking, drowning, fire contact, and target checks were brought closer to Alpha behavior.

## Smoother performance

- Nether terrain generation now uses a native C++ path, with the GDScript version kept as a fallback.
- Special block shapes use the native chunk mesher in web builds. Common shaders are prepared during loading to reduce first-use stutters.
- Large redstone networks update in smaller, resumable batches. Repeaters and pressure plates avoid duplicate work that could cause frame drops.
- Far-away mobs fully sleep until the player returns. Nearby mobs do less unnecessary pathfinding and line-of-sight work.
- Ghast fireballs, explosions, chunk-border lighting, and chunk remeshing were tuned to reduce stalls while exploring or fighting.

## Downloads

- **macOS:** `VibezCraft-macOS-universal.dmg` — signed and notarized for Apple Silicon and Intel Macs.
- **Windows installer:** `VibezCraft-Windows-Setup.exe` — recommended for most Windows players.
- **Windows portable:** `VibezCraft-Windows-x86_64.zip` — unzip and run without installing.

The Windows builds are not code-signed, so Windows SmartScreen may show a warning on first launch.

Worlds from 1.0.1 remain compatible and stay in the normal VibezCraft application-data folder.
