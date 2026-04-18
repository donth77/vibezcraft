extends MeshInstance3D

@export var spin_speed_y: float = 0.6
@export var spin_speed_x: float = 0.25


func _process(delta: float) -> void:
	rotate_y(delta * spin_speed_y)
	rotate_x(delta * spin_speed_x)
