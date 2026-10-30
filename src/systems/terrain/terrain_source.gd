class_name TerrainSource
extends RefCounted
## Where the answers to ground questions come from: Terrain's static queries
## (height_at, surface_at, normal_at, ground_at) route to the source in use.
## HeightmapSource answers from the generated world's height map
## (WorldData); a second world, a streamed one or a test's flat or sloping
## ground is another source. Override everything.

## Ground height (m) at a world point, smooth (bilinear between samples).
func height_at(_x: float, _z: float) -> float:
	return 0.0


## Ground height (m) exactly as the ground is drawn (the triangles the
## renderer and the collider use), for things that must lie on what you see.
func surface_at(x: float, z: float) -> float:
	return height_at(x, z)


## The ground's normal at a world point.
func normal_at(x: float, z: float) -> Vector3:
	var e := 1.0
	var hx := height_at(x + e, z) - height_at(x - e, z)
	var hz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


## What the ground is at a point: rock, sand, forest density, ambient
## occlusion (0..1 in r, g, b, a).
func ground_at(_x: float, _z: float) -> Color:
	return Color(0.0, 0.0, 0.0, 1.0)


## The square of ground it covers: Rect2(min x, min z, size, size) in m.
func extent() -> Rect2:
	return Rect2(-1e6, -1e6, 2e6, 2e6)


## m between the ground's own samples (the finest detail it has).
func spacing() -> float:
	return 1.0


## Heights for a collider: n x n samples `spacing()` apart, row by row (z),
## the first at sample (ix, iz) of the source's grid, whose sample (0, 0) is
## at extent().position.
func height_grid(ix: int, iz: int, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n * n)
	var s := spacing()
	var o := extent().position
	for z in n:
		for x in n:
			out[z * n + x] = height_at(o.x + (ix + x) * s, o.y + (iz + z) * s)
	return out
