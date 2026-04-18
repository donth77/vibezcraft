extends Node


func _ready() -> void:
	InputActions.register_defaults()
	BlockAtlas.build()
	# Warm the worldgen noise on the main thread before any worker can hit it,
	# so workers never race on the lazy-init.
	Worldgen.surface_height(0, 0)
	print("[Game] autoload ready — Minecraft Alpha Clone")
