class_name HeightmapSource
extends TerrainSource
## The ground of the generated world: its 16-bit height map (WorldData's two
## byte planes, sample i at -size/2 + i * spacing) and ground masks. Deep sea
## (h_min) outside it.

var data: WorldData


func _init(world: WorldData) -> void:
	data = world


## The 16-bit height sample (ix, iz) of mip level 0, in metres.
func sample(ix: int, iz: int) -> float:
	ix = clampi(ix, 0, data.texels - 1)
	iz = clampi(iz, 0, data.texels - 1)
	var i := iz * data.texels + ix
	return (data.hi[i] * 256 + data.lo[i]) * data.h_scale + data.h_min


func height_at(x: float, z: float) -> float:
	var gx := (x + data.size * 0.5) / data.spacing
	var gz := (z + data.size * 0.5) / data.spacing
	if gx < 0.0 or gz < 0.0 or gx > data.texels - 1 or gz > data.texels - 1:
		return data.h_min
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	return lerpf(lerpf(sample(ix, iz), sample(ix + 1, iz), fx), lerpf(sample(ix, iz + 1), sample(ix + 1, iz + 1), fx), fz)


## As the finest terrain patches draw it: each quad split into two
## triangles, the diagonal alternating quad by quad (Terrain._patch_mesh).
func surface_at(x: float, z: float) -> float:
	var gx := (x + data.size * 0.5) / data.spacing
	var gz := (z + data.size * 0.5) / data.spacing
	if gx < 0.0 or gz < 0.0 or gx > data.texels - 1 or gz > data.texels - 1:
		return data.h_min
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	var h00 := sample(ix, iz)
	var h10 := sample(ix + 1, iz)
	var h01 := sample(ix, iz + 1)
	var h11 := sample(ix + 1, iz + 1)
	if (ix + iz) % 2 == 0:   # (split from (1, 0) to (0, 1))
		if fx + fz <= 1.0:
			return h00 + (h10 - h00) * fx + (h01 - h00) * fz
		return h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)
	if fx >= fz:             # (split from (0, 0) to (1, 1))
		return h00 + (h10 - h00) * fx + (h11 - h10) * fz
	return h00 + (h01 - h00) * fz + (h11 - h01) * fx


## As the terrain shades its nearest ground (from the heights a sample
## either side).
func normal_at(x: float, z: float) -> Vector3:
	var s := data.spacing
	var hx := height_at(x + s, z) - height_at(x - s, z)
	var hz := height_at(x, z + s) - height_at(x, z - s)
	return Vector3(-hx, 2.0 * s, -hz).normalized()


func ground_at(x: float, z: float) -> Color:
	var w := data.ground.get_width()
	var px := clampi(int((x + data.size * 0.5) / data.size * w), 0, w - 1)
	var pz := clampi(int((z + data.size * 0.5) / data.size * w), 0, w - 1)
	return data.ground.get_pixel(px, pz)


func extent() -> Rect2:
	return Rect2(-data.size * 0.5, -data.size * 0.5, data.size, data.size)


func spacing() -> float:
	return data.spacing


func height_grid(ix: int, iz: int, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n * n)
	for z in n:
		for x in n:
			out[z * n + x] = sample(ix + x, iz + z)
	return out


## The two byte planes as mipmapped R8 textures, for the shaders.
func height_textures() -> Array[ImageTexture]:
	var out: Array[ImageTexture] = []
	for plane in [data.hi, data.lo]:
		var img := Image.create_from_data(data.texels, data.texels, true, Image.FORMAT_R8, plane)
		out.append(ImageTexture.create_from_image(img))
	return out
