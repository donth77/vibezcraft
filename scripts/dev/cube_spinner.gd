extends MeshInstance3D

@export var spin_speed: float = 0.5


func _process(delta: float) -> void:
	rotate_y(delta * spin_speed)
