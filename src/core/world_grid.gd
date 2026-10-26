class_name WorldGrid
extends RefCounted
## Square cells over the world's XZ plane: the shared spatial index for the
## exploration map, and later for streaming terrain chunks, procedural
## generation and culling. Cell (0, 0) spans [0, size) on both axes.


static func cell_of(position: Vector3, size: float) -> Vector2i:
	return Vector2i(floori(position.x / size), floori(position.z / size))


static func cell_center(cell: Vector2i, size: float) -> Vector3:
	return Vector3((cell.x + 0.5) * size, 0.0, (cell.y + 0.5) * size)


## Cells whose centres lie within radius of position.
static func cells_in_radius(position: Vector3, size: float, radius: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var centre := cell_of(position, size)
	var r := ceili(radius / size)
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := centre + Vector2i(dx, dz)
			var p := cell_center(c, size)
			if Vector2(p.x - position.x, p.z - position.z).length() <= radius:
				out.append(c)
	return out
