# gdlint: disable=max-public-methods
# gdlint: disable=max-file-lines
extends Node

# Block-sound playback. Maintains a small pool of AudioStreamPlayer nodes so
# multiple sounds can overlap. Played from a global autoload so callers don't
# need to manage their own player.

const POOL_SIZE: int = 6
const PITCH_JITTER: float = 0.1  # ±10% per play, like vanilla MC

const _DIG_SOUNDS: Dictionary = {
	"stone":
	[
		"res://assets/audio/sfx/Stone_dig1.ogg",
		"res://assets/audio/sfx/Stone_dig2.ogg",
		"res://assets/audio/sfx/Stone_dig3.ogg",
		"res://assets/audio/sfx/Stone_dig4.ogg",
	],
	"grass":
	[
		"res://assets/audio/sfx/Grass_dig1.ogg",
		"res://assets/audio/sfx/Grass_dig2.ogg",
		"res://assets/audio/sfx/Grass_dig3.ogg",
		"res://assets/audio/sfx/Grass_dig4.ogg",
	],
	"wood":
	[
		"res://assets/audio/sfx/Wood_dig1.ogg",
		"res://assets/audio/sfx/Wood_dig2.ogg",
		"res://assets/audio/sfx/Wood_dig3.ogg",
		"res://assets/audio/sfx/Wood_dig4.ogg",
	],
	"sand":
	[
		"res://assets/audio/sfx/Sand_dig1.ogg",
		"res://assets/audio/sfx/Sand_dig2.ogg",
		"res://assets/audio/sfx/Sand_dig3.ogg",
		"res://assets/audio/sfx/Sand_dig4.ogg",
	],
	"gravel":
	[
		"res://assets/audio/sfx/Gravel_dig1.ogg",
		"res://assets/audio/sfx/Gravel_dig2.ogg",
		"res://assets/audio/sfx/Gravel_dig3.ogg",
		"res://assets/audio/sfx/Gravel_dig4.ogg",
	],
	# Vanilla reuses the cloth step files for wool/sponge dig+place too —
	# no separate Cloth_dig*.ogg shipped. Without this entry, placing or
	# breaking wool crashes _play_random with a missing-key Dictionary
	# error (see _material_for returning "cloth" for is_wool / sponge).
	"cloth":
	[
		"res://assets/audio/sfx/step/cloth1.ogg",
		"res://assets/audio/sfx/step/cloth2.ogg",
		"res://assets/audio/sfx/step/cloth3.ogg",
		"res://assets/audio/sfx/step/cloth4.ogg",
	],
	# Modern MC slime block uses Block.soundSlimeFootstep — the slime's
	# own squish clips repurposed for dig/place/step. We reuse the small1-5
	# mob sounds (sourced via minecraft.wiki) — same clips the slime mob
	# plays on each hop.
	"slime":
	[
		"res://assets/audio/sfx/mob/slime/small1.ogg",
		"res://assets/audio/sfx/mob/slime/small2.ogg",
		"res://assets/audio/sfx/mob/slime/small3.ogg",
		"res://assets/audio/sfx/mob/slime/small4.ogg",
		"res://assets/audio/sfx/mob/slime/small5.ogg",
	],
}

const _PICKUP_SOUND: String = "res://assets/audio/sfx/Pop.ogg"
const _TOOL_BREAK_SOUND: String = "res://assets/audio/sfx/tool_break.ogg"
# Alpha 1.2.6 `sound3/random/click.ogg` — UI click for menu buttons.
const _CLICK_SOUND: String = "res://assets/audio/sfx/click.ogg"
# Alpha 1.2.6 `sound3/random/fuse.ogg` — TNT/creeper fuse hiss. Played once
# at ignition (vanilla v.java line 45 `cy.a(kr2, "random.fuse", 1.0f, 1.0f)`),
# NOT looped during the 4-second fuse — the audio is a one-shot crackle.
const _FUSE_SOUND: String = "res://assets/audio/sfx/random/fuse.ogg"
# Alpha 1.2.6 `sound/random/bow.ogg` — bow-string release whoosh.
# Vanilla bj.java::a (ItemFishingRod) plays this at cast:
#   cy.a(player, "random.bow", 0.5f, 0.4f / (rand() * 0.4 + 0.8))
# Volume 0.5, pitch ~0.44..0.56. Sourced via InventivetalentDev
# minecraft-assets branch 1.0 (Beta 1.0 = same asset as Alpha 1.2.6,
# the bow sound wasn't changed across the Alpha→Beta cut).
const _BOW_SOUND: String = "res://assets/audio/sfx/random/bow.ogg"
# Arrow impact pool — vanilla EntityArrow.h() picks one of these
# uniformly per hit (`world.makeSound(..., "random.bowhit", ...)`
# → sounds/random/bowhit{1..4}.ogg via the legacy asset index).
const _BOWHIT_SOUNDS: Array = [
	"res://assets/audio/sfx/random/bowhit1.ogg",
	"res://assets/audio/sfx/random/bowhit2.ogg",
	"res://assets/audio/sfx/random/bowhit3.ogg",
	"res://assets/audio/sfx/random/bowhit4.ogg",
]
# Alpha 1.2.6 `sound3/random/explode{1..4}.ogg` — vanilla picks one
# uniformly per detonation. ks.java::b() pitch jitter envelope is
# `(1 + (rand-rand) × 0.2) × 0.7` ≈ 0.7 ± 0.14, giving the explosion a
# bassy thump rather than the raw clip's mid-range.
const _EXPLODE_SOUNDS: Array = [
	"res://assets/audio/sfx/random/explode1.ogg",
	"res://assets/audio/sfx/random/explode2.ogg",
	"res://assets/audio/sfx/random/explode3.ogg",
	"res://assets/audio/sfx/random/explode4.ogg",
]
# Alpha 1.2.6 `sound3/random/glass{1,2,3}.ogg` — sharp shatter that BlockGlass
# emits on break (StepSoundC.soundOnDestroyed override). The step / place
# sound stays "stone" via _material_for since vanilla glass uses Material.glass
# whose stepSoundName is "step.stone".
const _GLASS_BREAK_SOUNDS: Array = [
	"res://assets/audio/sfx/random/glass1.ogg",
	"res://assets/audio/sfx/random/glass2.ogg",
	"res://assets/audio/sfx/random/glass3.ogg",
]
# Alpha 1.2.6 `sound3/random/chestopen.ogg` + `chestclosed.ogg` — the
# wooden creak vanilla TileEntityChest plays on lid open / close.
# Sourced from the local PrismLauncher Alpha install (mcasset.cloud
# /a1.2.6 has the same files if anyone needs to re-extract). Pitch-jitter
# matches vanilla GuiContainerChest.click which seeds Random per frame.
const _CHEST_OPEN_SOUND: String = "res://assets/audio/sfx/random/chestopen.ogg"
const _CHEST_CLOSE_SOUND: String = "res://assets/audio/sfx/random/chestclosed.ogg"
# Alpha 1.2.6 `newsound/random/door_{open,close}.ogg` — gv.java:98-102
# randomly picks one of the two on every toggle. Pitch jitter 0.9..1.0.
const _DOOR_OPEN_SOUND: String = "res://assets/audio/sfx/random/door_open.ogg"
const _DOOR_CLOSE_SOUND: String = "res://assets/audio/sfx/random/door_close.ogg"
# Alpha 1.2.6 `sound3/random/fizz.ogg` — extracted from
# InventivetalentDev/minecraft-assets @ a1.2.6 (vendor client.jar
# doesn't ship audio; the launcher downloads it on first run). Used
# for lava→obsidian/cobble conversion and lava-contact burn cues.
const _FIZZ_SOUND: String = "res://assets/audio/sfx/fluid/fizz.ogg"
# Alpha 1.2.6 `sound3/fire/fire.ogg` — low crackling loop-able clip.
# Vanilla `qh.java::b(cy,x,y,z,Random)` (BlockFire.randomDisplayTick)
# plays this 1-in-24 per random tick on a FIRE cell at pitch
# `(rand * 0.7 + 0.3)`, volume `1.0 + rand`. We scale similarly below.
const _FIRE_CRACKLE_SOUND: String = "res://assets/audio/sfx/fire/fire.ogg"
# Player damage sounds — vanilla EntityHuman.getHurtSound /
# getFallSound. hit{1,2,3} rotate randomly per hit; fallbig fires when
# the fall damage is > 4, else fallsmall.
const _PLAYER_HIT_SOUNDS: Array = [
	"res://assets/audio/sfx/damage/hit1.ogg",
	"res://assets/audio/sfx/damage/hit2.ogg",
	"res://assets/audio/sfx/damage/hit3.ogg",
]
const _PLAYER_FALL_BIG: String = "res://assets/audio/sfx/damage/fallbig.ogg"
const _PLAYER_FALL_SMALL: String = "res://assets/audio/sfx/damage/fallsmall.ogg"
# Pig audio — vanilla Alpha 1.2.6 sound3/mob/pig/. op.java::d() and
# op.java::f_() both return "mob.pig" so idle + hurt use the same
# say1/2/3 pool. op.java::f() returns "mob.pigdeath" → death.ogg.
# step1-5 are the footsteps (vanilla `lw.java::a(int, int, int, int)`
# play_step_sound dispatches by Block.stepSound, but for mobs the
# audio system reads the mob-specific override from `mob/<species>/`).
const _PIG_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/pig/say1.ogg",
	"res://assets/audio/sfx/mob/pig/say2.ogg",
	"res://assets/audio/sfx/mob/pig/say3.ogg",
]
const _PIG_DEATH_SOUND: String = "res://assets/audio/sfx/mob/pig/death.ogg"
const _PIG_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/pig/step1.ogg",
	"res://assets/audio/sfx/mob/pig/step2.ogg",
	"res://assets/audio/sfx/mob/pig/step3.ogg",
	"res://assets/audio/sfx/mob/pig/step4.ogg",
	"res://assets/audio/sfx/mob/pig/step5.ogg",
]
# Cow audio — vanilla Alpha 1.2.6 sound3/mob/cow/. `as.java::d()` returns
# "mob.cow" (idle = say1-4). `as.java::f_()` AND `as.java::f()` both
# return "mob.cowhurt" (hurt + death share the same hurt1-3 pool — cow
# doesn't have a distinct death clip in Alpha). Pitch override 0.4
# (vanilla `as.h() = 0.4f`) makes the cow sound LOW-pitched — a deep
# moo vs the pig's higher squeal.
const _COW_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/cow/say1.ogg",
	"res://assets/audio/sfx/mob/cow/say2.ogg",
	"res://assets/audio/sfx/mob/cow/say3.ogg",
	"res://assets/audio/sfx/mob/cow/say4.ogg",
]
const _COW_HURT_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/cow/hurt1.ogg",
	"res://assets/audio/sfx/mob/cow/hurt2.ogg",
	"res://assets/audio/sfx/mob/cow/hurt3.ogg",
]
const _COW_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/cow/step1.ogg",
	"res://assets/audio/sfx/mob/cow/step2.ogg",
	"res://assets/audio/sfx/mob/cow/step3.ogg",
	"res://assets/audio/sfx/mob/cow/step4.ogg",
]
# Vanilla `as.h()` returns 0.4 — that's the VOLUME scalar (third arg
# to `cy.a(entity, name, volume, pitch)` per hf.java:319), NOT pitch.
# 0.4 linear → ~-8 dB. Pitch stays at the entity default 1.0 with the
# standard ±0.2 vanilla jitter (we use ±0.1 here since the 0.2 vanilla
# envelope sometimes produces uncomfortable pitch swings).
const _COW_SOUND_VOLUME_DB: float = -8.0
# Chicken audio — vanilla Alpha 1.2.6 sound3/mob/chicken/. `ou.java::d()`
# returns "mob.chicken" (say1-3). `ou.java::f_()` AND `f()` both return
# "mob.chickenhurt" (hurt + death share hurt1-2). `ou.java::k()` line 42
# plays "mob.chickenplop" on egg-lay (every 6000-12000 ticks per the
# nextInt(6000) + 6000 timer at line 19/44). Chicken doesn't override
# `h()` so volume stays at the default 1.0 = ~0 dB (vanilla `hf.h() = 1.0`).
const _CHICKEN_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/chicken/say1.ogg",
	"res://assets/audio/sfx/mob/chicken/say2.ogg",
	"res://assets/audio/sfx/mob/chicken/say3.ogg",
]
const _CHICKEN_HURT_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/chicken/hurt1.ogg",
	"res://assets/audio/sfx/mob/chicken/hurt2.ogg",
]
const _CHICKEN_PLOP_SOUND: String = "res://assets/audio/sfx/mob/chicken/plop.ogg"
# Sheep audio — vanilla Alpha 1.2.6 `bx.java::d()`, `f_()`, and `f()` ALL
# return "mob.sheep", so idle, hurt, AND death share the same say1-3
# pool. Sheep has only this one clip family in Alpha.
const _SHEEP_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/sheep/say1.ogg",
	"res://assets/audio/sfx/mob/sheep/say2.ogg",
	"res://assets/audio/sfx/mob/sheep/say3.ogg",
]
# Zombie audio — Alpha 1.2.6 sound3/mob/zombie/. lk.java::d() returns
# "mob.zombie" (idle = say1-3), lk.java::f_() returns "mob.zombiehurt"
# (hurt1-2), lk.java::f() returns "mob.zombiedeath" (death.ogg). Step
# pool sourced separately (sound3/mob/zombie/step{1..5}.ogg).
const _ZOMBIE_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/zombie/say1.ogg",
	"res://assets/audio/sfx/mob/zombie/say2.ogg",
	"res://assets/audio/sfx/mob/zombie/say3.ogg",
]
const _ZOMBIE_HURT_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/zombie/hurt1.ogg",
	"res://assets/audio/sfx/mob/zombie/hurt2.ogg",
]
const _ZOMBIE_DEATH_SOUND: String = "res://assets/audio/sfx/mob/zombie/death.ogg"
const _ZOMBIE_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/zombie/step1.ogg",
	"res://assets/audio/sfx/mob/zombie/step2.ogg",
	"res://assets/audio/sfx/mob/zombie/step3.ogg",
	"res://assets/audio/sfx/mob/zombie/step4.ogg",
	"res://assets/audio/sfx/mob/zombie/step5.ogg",
]
# Skeleton audio — Alpha 1.2.6 sound3/mob/skeleton/. nq.java::d()
# returns "mob.skeleton" (idle/say), f_() returns "mob.skeletonhurt",
# f() returns "mob.skeletondeath". Files fetched from minecraft.wiki
# (Category:Skeleton_sounds) — same sound pool used since Alpha. Note
# the wiki names idle1-3 / hurt1-4 / step1-4 vs zombie's say/hurt/step
# pool sizes; preserved as-is rather than collapsing to match zombie.
const _SKELETON_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/skeleton/say1.ogg",
	"res://assets/audio/sfx/mob/skeleton/say2.ogg",
	"res://assets/audio/sfx/mob/skeleton/say3.ogg",
]
const _SKELETON_HURT_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/skeleton/hurt1.ogg",
	"res://assets/audio/sfx/mob/skeleton/hurt2.ogg",
	"res://assets/audio/sfx/mob/skeleton/hurt3.ogg",
	"res://assets/audio/sfx/mob/skeleton/hurt4.ogg",
]
const _SKELETON_DEATH_SOUND: String = "res://assets/audio/sfx/mob/skeleton/death.ogg"
const _SKELETON_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/skeleton/step1.ogg",
	"res://assets/audio/sfx/mob/skeleton/step2.ogg",
	"res://assets/audio/sfx/mob/skeleton/step3.ogg",
	"res://assets/audio/sfx/mob/skeleton/step4.ogg",
]
# Spider audio — Alpha 1.2.6 `be.java::d()` and `f_()` BOTH return
# "mob.spider" (idle AND hurt share the same hiss pool — vanilla
# deliberately reuses the say sound for hurt). `f()` returns
# "mob.spiderdeath". Step pool exists in 1.7+ assets (step1-4) but
# Alpha used generic block-step sounds — we wire the step files for
# future use; play_spider_step is opt-in. Files sourced from the
# 1.7.10 vanilla asset archive (Mojang has not modified spider
# audio since release).
const _SPIDER_SAY_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/spider/say1.ogg",
	"res://assets/audio/sfx/mob/spider/say2.ogg",
	"res://assets/audio/sfx/mob/spider/say3.ogg",
	"res://assets/audio/sfx/mob/spider/say4.ogg",
]
const _SPIDER_DEATH_SOUND: String = "res://assets/audio/sfx/mob/spider/death.ogg"
const _SPIDER_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/spider/step1.ogg",
	"res://assets/audio/sfx/mob/spider/step2.ogg",
	"res://assets/audio/sfx/mob/spider/step3.ogg",
	"res://assets/audio/sfx/mob/spider/step4.ogg",
]
# Slime audio — Alpha 1.2.6 sound3/mob/slime/. `ns.java::d()` returns
# "mob.slime", `ns.java::e()` returns "mob.slimeattack". Each mob picks
# from small1-5 or big1-4 based on size (≤1 → small pool, >1 → big
# pool). Attack pool fires when a size > 1 slime touches the player.
const _SLIME_SMALL_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/slime/small1.ogg",
	"res://assets/audio/sfx/mob/slime/small2.ogg",
	"res://assets/audio/sfx/mob/slime/small3.ogg",
	"res://assets/audio/sfx/mob/slime/small4.ogg",
	"res://assets/audio/sfx/mob/slime/small5.ogg",
]
const _SLIME_BIG_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/slime/big1.ogg",
	"res://assets/audio/sfx/mob/slime/big2.ogg",
	"res://assets/audio/sfx/mob/slime/big3.ogg",
	"res://assets/audio/sfx/mob/slime/big4.ogg",
]
const _SLIME_ATTACK_SOUNDS: Array = [
	"res://assets/audio/sfx/mob/slime/attack1.ogg",
	"res://assets/audio/sfx/mob/slime/attack2.ogg",
]
# Water audio — Alpha a1.2.6 assets (sound3/liquid/). `splash.ogg` fires on
# water entry (`Entity.N()` in Bukkit/mc-dev: plays sound with volume scaled
# by impact speed when `!inWater && justEnteredWater`). `swim1-4.ogg` cycle
# during horizontal motion while submerged — vanilla `Entity.h()` emits
# `game.neutral.swim` on a stride interval tied to travel distance.
const _WATER_SPLASH_SOUND: String = "res://assets/audio/sfx/water/splash.ogg"
const _WATER_SWIM_SOUNDS: Array = [
	"res://assets/audio/sfx/water/swim1.ogg",
	"res://assets/audio/sfx/water/swim2.ogg",
	"res://assets/audio/sfx/water/swim3.ogg",
	"res://assets/audio/sfx/water/swim4.ogg",
]

# Vanilla MC plays step.gravel for hoe tilling, soil step events, etc.
const _GRAVEL_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/step/gravel1.ogg",
	"res://assets/audio/sfx/step/gravel2.ogg",
	"res://assets/audio/sfx/step/gravel3.ogg",
	"res://assets/audio/sfx/step/gravel4.ogg",
]

# Step sounds — sourced from a1.2.6 newsound/step/. Played as the player
# walks, picked from the variants by material. Quieter than dig sounds.
const _STEP_VOLUME_DB: float = -8.0  # ~vanilla volume relative to dig
const _STEP_SOUNDS: Dictionary = {
	"grass":
	[
		"res://assets/audio/sfx/step/grass1.ogg",
		"res://assets/audio/sfx/step/grass2.ogg",
		"res://assets/audio/sfx/step/grass3.ogg",
		"res://assets/audio/sfx/step/grass4.ogg",
	],
	"stone":
	[
		"res://assets/audio/sfx/step/stone1.ogg",
		"res://assets/audio/sfx/step/stone2.ogg",
		"res://assets/audio/sfx/step/stone3.ogg",
		"res://assets/audio/sfx/step/stone4.ogg",
	],
	"wood":
	[
		"res://assets/audio/sfx/step/wood1.ogg",
		"res://assets/audio/sfx/step/wood2.ogg",
		"res://assets/audio/sfx/step/wood3.ogg",
		"res://assets/audio/sfx/step/wood4.ogg",
	],
	"sand":
	[
		"res://assets/audio/sfx/step/sand1.ogg",
		"res://assets/audio/sfx/step/sand2.ogg",
		"res://assets/audio/sfx/step/sand3.ogg",
		"res://assets/audio/sfx/step/sand4.ogg",
	],
	"cloth":
	[
		"res://assets/audio/sfx/step/cloth1.ogg",
		"res://assets/audio/sfx/step/cloth2.ogg",
		"res://assets/audio/sfx/step/cloth3.ogg",
		"res://assets/audio/sfx/step/cloth4.ogg",
	],
	"gravel":
	[
		"res://assets/audio/sfx/step/gravel1.ogg",
		"res://assets/audio/sfx/step/gravel2.ogg",
		"res://assets/audio/sfx/step/gravel3.ogg",
		"res://assets/audio/sfx/step/gravel4.ogg",
	],
	# Modern MC slime block step uses the same small-slime squish pool
	# as dig/place — Block.soundSlimeFootstep registers one set of
	# clips and reuses them for all three events. Without this entry,
	# stepping on a placed slime block crashes the dict lookup.
	"slime":
	[
		"res://assets/audio/sfx/mob/slime/small1.ogg",
		"res://assets/audio/sfx/mob/slime/small2.ogg",
		"res://assets/audio/sfx/mob/slime/small3.ogg",
		"res://assets/audio/sfx/mob/slime/small4.ogg",
		"res://assets/audio/sfx/mob/slime/small5.ogg",
	],
}

# Separate 3D-positional pool for mob sounds. Vanilla MC mob audio
# attenuates with distance — pigs are audible to ~16 blocks, then
# silent. AudioStreamPlayer3D handles falloff; the non-positional
# pool above is only for player-frame sounds (UI clicks, player hurt,
# block break at cursor, etc.) that should always be full volume.
const POOL_SIZE_3D: int = 4
const MOB_SOUND_MAX_DISTANCE: float = 16.0  # vanilla mob audio range
const MOB_SOUND_UNIT_SIZE: float = 4.0  # closer = louder; tuned for clarity

var _players: Array = []
var _next_player: int = 0
var _stream_cache: Dictionary = {}
var _players_3d: Array = []
var _next_player_3d: int = 0


func _ready() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	for i in range(POOL_SIZE_3D):
		var p3 := AudioStreamPlayer3D.new()
		p3.max_distance = MOB_SOUND_MAX_DISTANCE
		p3.unit_size = MOB_SOUND_UNIT_SIZE
		# Default falloff is logarithmic; matches MC's perceptual rolloff.
		add_child(p3)
		_players_3d.append(p3)


# Stop every active SFX player. Called by pause_menu when quitting to
# title so long-running clips (the fire crackle especially — sampled
# from a multi-second loop-ish source) don't leak across the scene
# change. SFX is an autoload so its AudioStreamPlayers survive scene
# swaps; without an explicit stop they keep playing under the main
# menu's dirt bg until the clip naturally finishes.
func stop_all_sfx() -> void:
	for p: AudioStreamPlayer in _players:
		if p != null and p.playing:
			p.stop()
	for p3: AudioStreamPlayer3D in _players_3d:
		if p3 != null and p3.playing:
			p3.stop()


func play_break(block_id: int) -> void:
	# Glass has a dedicated shatter set, not the stone dig variants — vanilla
	# BlockGlass overrides StepSound.soundOnDestroyed to "random.glass*".
	# Ice uses the same glass shatter set in vanilla (BlockIce.stepSound =
	# soundGlassFootstep, which is the glass break/footstep set).
	if block_id == Blocks.GLASS or block_id == Blocks.ICE:
		var path: String = _GLASS_BREAK_SOUNDS[randi() % _GLASS_BREAK_SOUNDS.size()]
		_play_one(path, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))
		return
	var mat := _material_for(block_id)
	if mat == "":
		return
	_play_random(mat, 1.0)


# Place sound is the same dig sound at slightly lower pitch — vanilla MC trick.
func play_place(block_id: int) -> void:
	var mat := _material_for(block_id)
	if mat == "":
		return
	_play_random(mat, 0.85)


# Vanilla TileEntityChest plays `random.chestopen` on RMB-interact and
# `random.chestclose` when the GUI closes (BlockChest.j → playSoundEffect
# in c.java). Pitch jitter matches the same `rand * 0.1 + 0.9` envelope
# every other random.* sound uses.
func play_chest_open() -> void:
	_play_one(_CHEST_OPEN_SOUND, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


func play_chest_close() -> void:
	_play_one(_CHEST_CLOSE_SOUND, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


# Vanilla gv.java:98-102 — randomly picks door_open or door_close on every
# toggle, with pitch `rand * 0.1 + 0.9`. Not keyed to actual open/close
# state — just a random 50/50 pick per interaction, same as vanilla.
func play_door_toggle() -> void:
	var path: String = _DOOR_OPEN_SOUND if randf() < 0.5 else _DOOR_CLOSE_SOUND
	_play_one(path, 0.0, randf_range(0.9, 1.0))


# 3D-positional block-step sound for mobs walking. Vanilla
# `lw.java::a_(x, y, z, blockId)` plays `step.<material>` for the
# block under the entity — NOT a mob-specific step. So pigs/cows on
# grass play `step.grass.*`, same as the player. The mob/<species>/step
# files in client.jar are used elsewhere (impact thuds, not walking)
# — using them for walking sounded like "punching" per user feedback.
func play_block_step_3d(block_id: int, pos: Vector3) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var mat := _step_material_for(block_id)
	if mat == "":
		return
	var paths: Array = _STEP_SOUNDS[mat]
	_play_mob_sound_3d(paths, pos, _STEP_VOLUME_DB)


# Footstep — picks a random variant for the block's material.
func play_step(block_id: int) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var mat := _step_material_for(block_id)
	if mat == "":
		return
	var paths: Array = _STEP_SOUNDS[mat]
	var path: String = paths[randi() % paths.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = _STEP_VOLUME_DB
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# Hoe-till "thump" — vanilla MC plays step.gravel here. Pitch + volume
# match BlockSoil.stepSound (volume×0.8, pitch averaged at 1.0).
func play_hoe_till() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var path: String = _GRAVEL_STEP_SOUNDS[randi() % _GRAVEL_STEP_SOUNDS.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = -2.0
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# Player "ouch" sound — vanilla EntityHuman.getHurtSound rotates three
# variants and adds pitch jitter. Called whenever the player takes damage
# (not specifically fall damage — that has its own louder sound below).
func play_player_hit() -> void:
	var path: String = _PLAYER_HIT_SOUNDS[randi() % _PLAYER_HIT_SOUNDS.size()]
	_play_one(path, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


# Heavy-fall impact — vanilla branches on > 4 damage: fallbig for big
# falls, fallsmall otherwise. Called INSTEAD of play_player_hit for fall
# damage specifically.
func play_player_fall(damage: int) -> void:
	var path: String = _PLAYER_FALL_BIG if damage > 4 else _PLAYER_FALL_SMALL
	_play_one(path, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


func _play_one(path: String, volume_db: float, pitch: float) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()


# Water entry splash — vanilla Entity.N() plays `random.splash` when the
# entity transitions from !inWater to inWater (lw.java:160-184). Volume is
# `clamp(sqrt(vx²·0.2 + vy² + vz²·0.2) · 0.2, 0, 1)` — vertical impact
# weighted 5× horizontal so cannonball jumps are loud and gentle wades are
# Vanilla bj.java::a fishing-rod cast. Volume 0.5, pitch
# 0.4 / (rand * 0.4 + 0.8) → range ~0.36..0.50, centered ~0.43. The
# pitch envelope is intentionally low so the bow sound reads as a
# "rod whip" rather than a high-pitched arrow shot.
func play_bow_cast() -> void:
	var pitch: float = 0.4 / (randf_range(0.0, 0.4) + 0.8)
	_play_one(_BOW_SOUND, linear_to_db(0.5), pitch)


# Vanilla ItemBow.a() — `world.makeSound(player, "random.bow", 1.0,
# 1.0 / (rand*0.4 + 1.2) + f*0.5)`. Pitch range ~0.71..0.91 + charge*0.5
# so a fully-drawn shot ("twang") is noticeably higher-pitched than a
# half-charge release. Same sound file as the fishing-rod cast — vanilla
# shares random.bow.ogg between the two interactions.
func play_bow_shoot(charge: float) -> void:
	var pitch: float = 1.0 / (randf_range(0.0, 0.4) + 1.2) + charge * 0.5
	_play_one(_BOW_SOUND, 0.0, pitch)


# Arrow impact — vanilla EntityArrow.h() plays `random.bowhit{1..4}`
# (picked uniformly per hit). Pitch jitter from the same line:
# `1.2 / (rand*0.2 + 0.9)` → range ~1.09..1.33. The canonical samples
# are vendored from Mojang's content-hash CDN; legacy 1.6.4 asset index
# `sounds/random/bowhit{1..4}.ogg`.
func play_arrow_hit() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var path: String = _BOWHIT_SOUNDS[randi() % _BOWHIT_SOUNDS.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 1.2 / (randf_range(0.0, 0.2) + 0.9)
	player.play()


# soft but audible. Pitch jitter is `1.0 + (rand - rand) * 0.4`.
func play_splash(velocity: Vector3) -> void:
	var weighted: float = (
		velocity.x * velocity.x * 0.2 + velocity.y * velocity.y + velocity.z * velocity.z * 0.2
	)
	var f: float = clampf(sqrt(weighted) * 0.2, 0.0, 1.0)
	if f <= 0.0:
		return
	var volume_db: float = linear_to_db(f)
	var pitch: float = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER) * 0.4
	_play_one(_WATER_SPLASH_SOUND, volume_db, pitch)


# Ongoing swim cadence — one random swim sample per stride while the
# player is moving horizontally through water. Vanilla's `Entity.h()`
# cycles `game.neutral.swim` on the same block-travel tracker the footstep
# system uses, so player.gd drives the interval.
func play_swim() -> void:
	var path: String = _WATER_SWIM_SOUNDS[randi() % _WATER_SWIM_SOUNDS.size()]
	_play_one(path, _STEP_VOLUME_DB, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


# Tool snap — vanilla MC's random/break.ogg, played when a tool's
# durability hits zero and the stack is consumed.
func play_tool_break() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_TOOL_BREAK_SOUND)
	if stream == null:
		stream = load(_TOOL_BREAK_SOUND) as AudioStream
		_stream_cache[_TOOL_BREAK_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# Lava fizzle — fires when a lava cell converts to obsidian/cobble after
# touching water, and also as a one-shot on player-lava contact.
# Mirrors ld.java:257 `random.fizz`. Vanilla's pitch jitter is `2.6 +
# (rand - rand) * 0.8` — treat that as a mean near 2.6× with a ±0.8
# range, same shape we can do with pitch_scale.
func play_fizz(loud: bool = false) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_FIZZ_SOUND)
	if stream == null:
		stream = load(_FIZZ_SOUND) as AudioStream
		_stream_cache[_FIZZ_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Conversion: loud bubbly hiss. Lava-touch: quieter, shorter-feeling
	# via pitch shift so the two audio cues feel distinct.
	player.volume_db = 0.0 if loud else -6.0
	var base_pitch: float = 2.6 if loud else 1.8
	player.pitch_scale = base_pitch + randf_range(-0.4, 0.4)
	player.play()


# Fire crackle — mirrors vanilla qh.java:186-188 BlockFire.randomDisplayTick:
# 1-in-24 per random tick roll plays this sound at pitch ~0.65 (rand * 0.7
# + 0.3 midpoint). Caller rolls the probability and invokes with the world
# position of the fire cell so distance-attenuation works via AudioStreamPlayer
# position (today we use the non-positional pool for simplicity).
func play_fire_crackle() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_FIRE_CRACKLE_SOUND)
	if stream == null:
		stream = load(_FIRE_CRACKLE_SOUND) as AudioStream
		_stream_cache[_FIRE_CRACKLE_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Vanilla pitch: rand(0..1) * 0.7 + 0.3 → [0.3, 1.0], volume 1.0 + rand.
	# Map to our dB range: ~-4 dB midpoint, ± 2 dB jitter.
	player.volume_db = -4.0 + randf_range(-2.0, 2.0)
	player.pitch_scale = randf_range(0.3, 1.0)
	player.play()


# Lava surface pop — vanilla ld.java's randomDisplayTick calls `random.pop`
# alongside the lava spark particle. Reuses the existing pop.ogg stream
# with a muted volume + lower pitch so it reads as a bubble rather than a
# sharp item-pickup cue.
func play_lava_pop() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_PICKUP_SOUND)
	if stream == null:
		stream = load(_PICKUP_SOUND) as AudioStream
		_stream_cache[_PICKUP_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = -8.0
	player.pitch_scale = 0.5 + randf_range(-0.1, 0.1)
	player.play()


# Flint-and-steel ignite — vanilla Alpha 1.2.6 (nv.java) was actually
# SILENT on ignite (the only audio cue was the resulting fire's ambient
# crackle). Modern MC plays `item.flintandsteel.use`, a short metallic
# strike. We use the existing `random.click` asset at slight downward
# pitch (0.9) so the strike reads as a tactile "snap" without sounding
# like a UI button. Swap to a real fire.ignite OGG when a flint-and-
# steel SFX bundle drops in.
func play_flint_and_steel() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_CLICK_SOUND)
	if stream == null:
		stream = load(_CLICK_SOUND) as AudioStream
		_stream_cache[_CLICK_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 0.9
	player.play()


# Menu/button click — vanilla MC plays `random.click` at pitch 1.0 for any
# menu button activation. Pitch is fixed (no jitter) in vanilla so repeated
# clicks read as a single consistent UI cue.
func play_click() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_CLICK_SOUND)
	if stream == null:
		stream = load(_CLICK_SOUND) as AudioStream
		_stream_cache[_CLICK_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 1.0
	player.play()


# Item pickup "pop" — vanilla MC's random/pop.ogg
# TNT fuse hiss — vanilla one-shot at ignition. Pitch jitter ±10% to match
# the random.* family envelope; `loud` controls volume (chained primed-TNT
# in close succession would drown the player's ears at full volume each).
func play_fuse(loud: bool = true) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_FUSE_SOUND)
	if stream == null:
		stream = load(_FUSE_SOUND) as AudioStream
		_stream_cache[_FUSE_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0 if loud else -8.0
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# TNT/creeper detonation — vanilla picks 1 of 4 explode variants. Pitch
# envelope `(1 + (rand-rand) × 0.2) × 0.7` per ks.java::b() drops the
# clip an octave-ish so the bassy boom reads correctly. `pos` is the
# detonation world coord (unused today; positional 3D audio lands when
# the SFX system sprouts an AudioStreamPlayer3D pool).
func play_explode(_pos: Vector3 = Vector3.ZERO) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var path: String = _EXPLODE_SOUNDS[randi() % _EXPLODE_SOUNDS.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Vanilla volume 4.0 — louder than every other random.* sound (which
	# is exactly the drama you want from TNT). Cap at +6 dB so the player's
	# speakers don't clip on a chain detonation.
	player.volume_db = 6.0
	# `(1 + (rand-rand) × 0.2) × 0.7` averages ~0.7 with ±0.14 jitter.
	player.pitch_scale = (1.0 + (randf() - randf()) * 0.2) * 0.7
	player.play()


func play_pickup() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_PICKUP_SOUND)
	if stream == null:
		stream = load(_PICKUP_SOUND) as AudioStream
		_stream_cache[_PICKUP_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	# Pitch jitter for variety
	player.pitch_scale = 1.0 + randf_range(-0.15, 0.15)
	player.play()


# Pig say (idle + hurt — vanilla op.java::d and f_ both return "mob.pig").
# Picks a random say1/2/3 clip with ±0.1 pitch jitter, matching the
# vanilla pitch envelope in `lw.java::P` (per-entity sound pitch).
# Position-aware: caller passes the pig's world position so audio
# attenuates with distance (vanilla pig sounds fall off past ~16 m).
func play_pig_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_PIG_SAY_SOUNDS, pos)


# Pig death — vanilla op.java::f returns "mob.pigdeath".
func play_pig_death(pos: Vector3) -> void:
	_play_mob_sound_3d([_PIG_DEATH_SOUND], pos)


# Pig footstep — vanilla rotates step1-5 randomly per stride.
func play_pig_step(pos: Vector3) -> void:
	_play_mob_sound_3d(_PIG_STEP_SOUNDS, pos, -4.0)


# Cow ambient moo — vanilla `as.java::d() = "mob.cow"`. Quieter than
# pig per `as.h() = 0.4` (volume scalar, ~-8 dB).
func play_cow_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_COW_SAY_SOUNDS, pos, _COW_SOUND_VOLUME_DB)


# Cow hurt — vanilla `as.java::f_() = "mob.cowhurt"`. Same pool used
# for death since vanilla `f()` also returns "mob.cowhurt" (Alpha cows
# lack a distinct death clip).
func play_cow_hurt(pos: Vector3) -> void:
	_play_mob_sound_3d(_COW_HURT_SOUNDS, pos, _COW_SOUND_VOLUME_DB)


# Cow death — reuses the hurt pool, matching vanilla.
func play_cow_death(pos: Vector3) -> void:
	_play_mob_sound_3d(_COW_HURT_SOUNDS, pos, _COW_SOUND_VOLUME_DB)


# Cow step — extra -4 dB on top of the species volume (mob steps are
# always quieter than vocalizations).
func play_cow_step(pos: Vector3) -> void:
	_play_mob_sound_3d(_COW_STEP_SOUNDS, pos, _COW_SOUND_VOLUME_DB - 4.0)


# Chicken ambient cluck — vanilla `ou.java::d() = "mob.chicken"`.
func play_chicken_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_CHICKEN_SAY_SOUNDS, pos)


# Chicken hurt — vanilla `ou.java::f_() = "mob.chickenhurt"`. Reused
# for death since vanilla `f()` returns the same.
func play_chicken_hurt(pos: Vector3) -> void:
	_play_mob_sound_3d(_CHICKEN_HURT_SOUNDS, pos)


func play_chicken_death(pos: Vector3) -> void:
	_play_mob_sound_3d(_CHICKEN_HURT_SOUNDS, pos)


# Egg-lay "plop" — vanilla `ou.k()` line 42 plays "mob.chickenplop"
# at full volume with the standard ±0.2 vanilla pitch jitter.
func play_chicken_plop(pos: Vector3) -> void:
	_play_mob_sound_3d([_CHICKEN_PLOP_SOUND], pos)


# Sheep say — vanilla `bx.java` returns "mob.sheep" for idle, hurt, AND
# death (one clip pool for everything). The single-method wrapper keeps
# callers cleaner; mob_base routes hurt/death through this too.
func play_sheep_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_SHEEP_SAY_SOUNDS, pos)


# Zombie say / hurt / death / step. Vanilla EntityZombie overrides
# the four sound methods to "mob.zombie", "mob.zombiehurt",
# "mob.zombiedeath", and step uses the zombie-specific step pool
# rather than the block step samples. Step volume is slightly louder
# than passive mobs (vanilla 0.15 vs 0.1) to convey the "heavier"
# zombie shuffle — we mirror via the +2 dB delta below.
func play_zombie_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_ZOMBIE_SAY_SOUNDS, pos)


func play_zombie_hurt(pos: Vector3) -> void:
	_play_mob_sound_3d(_ZOMBIE_HURT_SOUNDS, pos)


func play_zombie_death(pos: Vector3) -> void:
	_play_mob_sound_3d([_ZOMBIE_DEATH_SOUND], pos)


func play_zombie_step(pos: Vector3) -> void:
	_play_mob_sound_3d(_ZOMBIE_STEP_SOUNDS, pos, -2.0)


func play_skeleton_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_SKELETON_SAY_SOUNDS, pos)


func play_skeleton_hurt(pos: Vector3) -> void:
	_play_mob_sound_3d(_SKELETON_HURT_SOUNDS, pos)


func play_skeleton_death(pos: Vector3) -> void:
	_play_mob_sound_3d([_SKELETON_DEATH_SOUND], pos)


func play_skeleton_step(pos: Vector3) -> void:
	_play_mob_sound_3d(_SKELETON_STEP_SOUNDS, pos, -2.0)


# Vanilla `be.java::d()` and `f_()` both return "mob.spider" so the
# idle (`say`) pool also serves as the hurt pool. play_spider_hurt is
# wired to the same SAY array intentionally.
func play_spider_say(pos: Vector3) -> void:
	_play_mob_sound_3d(_SPIDER_SAY_SOUNDS, pos)


func play_spider_hurt(pos: Vector3) -> void:
	_play_mob_sound_3d(_SPIDER_SAY_SOUNDS, pos)


func play_spider_death(pos: Vector3) -> void:
	_play_mob_sound_3d([_SPIDER_DEATH_SOUND], pos)


func play_spider_step(pos: Vector3) -> void:
	_play_mob_sound_3d(_SPIDER_STEP_SOUNDS, pos, -2.0)


# Slime sounds. Vanilla picks small/big pool by `c > 1`. We accept the
# size int directly so the caller doesn't need to know the threshold.
# Hurt + death share the same pool (vanilla `ns.java` f_() + f() both
# return "mob.slime{small,big}"). `play_slime_hop` is the bounce SFX
# fired from slime.gd's _do_hop.
func play_slime_hop(pos: Vector3, size: int) -> void:
	var pool: Array = _SLIME_SMALL_SOUNDS if size <= 1 else _SLIME_BIG_SOUNDS
	# Slightly quieter than say sounds — vanilla volume 0.4-0.6 vs the
	# 0.6-1.0 of the say pool. Match by dropping a few dB.
	_play_mob_sound_3d(pool, pos, -4.0)


func play_slime_hurt(pos: Vector3, size: int) -> void:
	var pool: Array = _SLIME_SMALL_SOUNDS if size <= 1 else _SLIME_BIG_SOUNDS
	_play_mob_sound_3d(pool, pos)


func play_slime_attack(pos: Vector3) -> void:
	_play_mob_sound_3d(_SLIME_ATTACK_SOUNDS, pos)


# 3D-positional mob-sound helper. Routes through the AudioStreamPlayer3D
# pool so falloff with distance kicks in automatically (max_distance =
# 16 m, unit_size = 4 m for the perceptual sweet-spot). Pool round-
# robins like the 2D pool — POOL_SIZE_3D = 4 entries is plenty for the
# 6-mob cap since most mobs are silent most ticks.
# `base_pitch` is the species-level pitch scalar (vanilla `lw.java::h`).
# Combined with the ±0.1 random jitter so a base of 0.4 (cow) gives
# clips in [0.3, 0.5] — distinctly low-pitched vs the pig's [0.9, 1.1].
func _play_mob_sound_3d(
	paths: Array, pos: Vector3, volume_db: float = -1.0, base_pitch: float = 1.0
) -> void:
	if not Game.sfx_enabled or Game.is_loading or paths.is_empty():
		return
	var path: String = paths[randi() % paths.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer3D = _players_3d[_next_player_3d]
	_next_player_3d = (_next_player_3d + 1) % POOL_SIZE_3D
	player.global_position = pos
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = base_pitch + randf_range(-0.1, 0.1)
	player.play()


func _play_random(material: String, base_pitch: float) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var paths: Array = _DIG_SOUNDS[material]
	var path: String = paths[randi() % paths.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Reset volume in case the player was last used by play_step (which uses
	# a quieter volume_db). Pool reuse means we have to set it every time.
	player.volume_db = 0.0
	player.pitch_scale = base_pitch + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# gdlint: disable=max-returns
func _material_for(block_id: int) -> String:
	match block_id:
		Blocks.STONE, Blocks.COBBLESTONE, Blocks.MOSSY_COBBLESTONE:
			return "stone"
		Blocks.COBBLESTONE_STAIRS, Blocks.BEDROCK, Blocks.BRICK:
			return "stone"
		Blocks.OBSIDIAN, Blocks.COAL_ORE, Blocks.IRON_ORE, Blocks.GOLD_ORE:
			return "stone"
		Blocks.DIAMOND_ORE, Blocks.FURNACE, Blocks.LIT_FURNACE, Blocks.GLASS:
			return "stone"
		Blocks.DIRT, Blocks.GRASS, Blocks.LEAVES, Blocks.SAPLING:
			return "grass"
		Blocks.FLOWER_RED, Blocks.FLOWER_YELLOW, Blocks.MUSHROOM_BROWN, Blocks.MUSHROOM_RED:
			return "grass"
		Blocks.SUGAR_CANE:
			return "grass"
		Blocks.SAND:
			return "sand"
		Blocks.LOG, Blocks.PLANKS, Blocks.CRAFTING_TABLE, Blocks.TORCH:
			return "wood"
		Blocks.CHEST, Blocks.FENCE, Blocks.WOOD_STAIRS, Blocks.WOODEN_DOOR, Blocks.LADDER:
			return "wood"
		Blocks.FENCE_GATE:
			return "wood"
		Blocks.IRON_DOOR:
			return "stone"
		Blocks.GRAVEL, Blocks.FARMLAND:
			return "gravel"
		Blocks.ICE:
			return "stone"  # vanilla: glass-like shatter; closest in our set
		Blocks.SNOW_BLOCK, Blocks.SNOW_LAYER:
			return "sand"  # vanilla snow uses 'cloth' but sand is closest crunch
		Blocks.CACTUS:
			return "grass"  # vanilla: cloth/grass-like
		Blocks.PUMPKIN, Blocks.JACK_O_LANTERN:
			# Vanilla Alpha nq.java:109,114 — both pumpkin variants set
			# stepSound = hb.e (wood material), same as planks / log /
			# chest / ladder. cx(86, 102, false).a(e) and the lit form.
			return "wood"
		Blocks.BOOKSHELF:
			# Vanilla Beta 1.3 BlockBookshelf inherits Material.wood
			# (same as planks). Wood SFX for dig / step / place.
			return "wood"
		Blocks.CROPS:
			# BlockCrops inherits BlockBush which uses Material.plant →
			# "grass" SFX (soft rustle, vanilla).
			return "grass"
		Blocks.SPONGE:
			# Vanilla nq.L (BlockSponge) uses Material.cloth (hb.k) →
			# "cloth" SFX. Soft thump.
			return "cloth"
		Blocks.IRON_BLOCK, Blocks.GOLD_BLOCK, Blocks.DIAMOND_BLOCK:
			# Vanilla metal blocks use Material.metal (hb.i) which has
			# its own step sound in modern MC, but Alpha mapped metal
			# to the stone step pool — keep that for fidelity.
			return "stone"
		Blocks.MOB_SPAWNER:
			# Vanilla eb.java (BlockMobSpawner) uses Material.rock (hb.d),
			# same as cobblestone — mossy cage cracks like stone.
			return "stone"
		Blocks.CLAY:
			# Vanilla nq.aW `.a(f)` = gravel sound material. Squishy
			# crunchy break — same as gravel.
			return "gravel"
		Blocks.HALF_SLAB, Blocks.DOUBLE_SLAB:
			# Vanilla qj.java uses hb.d (Material.stone) but with no
			# step-sound override — defaults to stone SFX pool.
			return "stone"
		Blocks.WOOD_HALF_SLAB, Blocks.WOOD_DOUBLE_SLAB:
			# Beta wood-slab variant — Material.wood → wood SFX pool.
			return "wood"
		Blocks.COBBLESTONE_HALF_SLAB, Blocks.COBBLESTONE_DOUBLE_SLAB:
			# Cobblestone variant — Material.stone same as the stone slab.
			return "stone"
		Blocks.SIGN_STANDING, Blocks.SIGN_WALL:
			# Vanilla ni.java uses hb.e (Material.wood) → wood SFX.
			return "wood"
		Blocks.RAIL:
			# Vanilla qe.java BlockMinecartTrack uses Material.metal (hb.i).
			# Alpha mapped metal to the stone step pool — same compromise
			# we use for IRON_BLOCK etc. Clinky metallic thump on place /
			# break.
			return "stone"
		Blocks.BED_FOOT, Blocks.BED_HEAD:
			# Vanilla bd.java BlockBed uses Material.cloth (hb.B) — same
			# pool as wool blocks. Soft thump on place + break.
			return "cloth"
		Blocks.JUKEBOX:
			# Vanilla BlockJukebox inherits Material.wood (hb.e) — same
			# wood-knock SFX as planks / log / fence_gate.
			return "wood"
		Blocks.SLIME_BLOCK:
			# Modern MC BlockSlime uses Block.soundSlimeFootstep — a
			# dedicated slime-squish material distinct from cloth/wood.
			# Without this case, _material_for returns "" and play_break
			# silently early-returns, so the block snapped instantly with
			# no SFX — matches the user's report.
			return "slime"
	# Wool family (16 colors at contiguous IDs) — cloth material.
	if Blocks.is_wool(block_id):
		return "cloth"
	return ""


# Step-sound material — diverges from dig: leaves use the soft "cloth"
# variant, not grass-rustle (vanilla MC behavior).
func _step_material_for(block_id: int) -> String:
	if block_id == Blocks.LEAVES:
		return "cloth"
	return _material_for(block_id)
