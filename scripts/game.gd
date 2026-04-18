extends Node


func _ready() -> void:
	InputActions.register_defaults()
	BlockAtlas.build()
	print("[Game] autoload ready — Minecraft Alpha Clone")
