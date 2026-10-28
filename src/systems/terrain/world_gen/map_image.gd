class_name MapImage
extends RefCounted
## One of the world's hand-painted maps, read straight from its PNG.
## 16-bit grayscale is decoded here at full precision (Godot's own loader cuts
## it to 8 bits, which would terrace the heights); anything else goes through
## Image. sample() reads values 0..1 bilinearly, color() the nearest pixel.

var width := 0
var height := 0
var _gray := PackedFloat32Array()   # 0..1 per pixel (grayscale or the red channel)
var _img: Image                     # for colour maps


static func open(path: String) -> MapImage:
	var mi := MapImage.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("World map missing: " + path)
		mi.width = 1
		mi.height = 1
		mi._gray = PackedFloat32Array([0.0])
		return mi
	if not mi._decode_png16(bytes):
		var img := Image.new()
		img.load_png_from_buffer(bytes)
		img.convert(Image.FORMAT_RGB8)
		mi._img = img
		mi.width = img.get_width()
		mi.height = img.get_height()
		var data := img.get_data()
		mi._gray.resize(mi.width * mi.height)
		for i in mi._gray.size():
			mi._gray[i] = data[i * 3] / 255.0
	return mi


## Bilinear value at (u, v) in 0..1 across the map.
func sample(u: float, v: float) -> float:
	var x := clampf(u * width - 0.5, 0.0, width - 1.001)
	var y := clampf(v * height - 0.5, 0.0, height - 1.001)
	var ix := int(x)
	var iy := int(y)
	var fx := x - ix
	var fy := y - iy
	var i := iy * width + ix
	var i2 := i + (width if iy + 1 < height else 0)
	var dx := 1 if ix + 1 < width else 0
	return lerpf(lerpf(_gray[i], _gray[i + dx], fx), lerpf(_gray[i2], _gray[i2 + dx], fx), fy)


## Nearest pixel's colour at (u, v) (grayscale maps give gray).
func color(u: float, v: float) -> Color:
	var x := clampi(int(u * width), 0, width - 1)
	var y := clampi(int(v * height), 0, height - 1)
	if _img:
		return _img.get_pixel(x, y)
	var g := _gray[y * width + x]
	return Color(g, g, g)


# 16-bit grayscale PNG (colour type 0, depth 16, not interlaced): inflate the
# image data and undo the per-row filters. Returns false for anything else.
func _decode_png16(b: PackedByteArray) -> bool:
	if b.size() < 33 or b[12] != 0x49 or b[13] != 0x48:   # IHDR first
		return false
	width = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19]
	height = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]
	var depth := b[24]
	var ctype := b[25]
	var interlace := b[28]
	if depth != 16 or ctype != 0 or interlace != 0:
		return false
	var z := PackedByteArray()
	var p := 8
	while p + 8 <= b.size():
		var len := (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]
		var tag := b.slice(p + 4, p + 8).get_string_from_ascii()
		if tag == "IDAT":
			z.append_array(b.slice(p + 8, p + 8 + len))
		elif tag == "IEND":
			break
		p += 12 + len
	var stride := width * 2
	var raw := z.decompress(height * (stride + 1), FileAccess.COMPRESSION_DEFLATE)
	if raw.size() < height * (stride + 1):
		return false
	_gray.resize(width * height)
	var prev := PackedByteArray()
	prev.resize(stride)
	var row := PackedByteArray()
	row.resize(stride)
	for y in height:
		var o := y * (stride + 1)
		var f := raw[o]
		for x in stride:
			var c := raw[o + 1 + x]
			var a := row[x - 2] if x >= 2 else 0
			var up := prev[x]
			match f:
				1: c = (c + a) & 0xff
				2: c = (c + up) & 0xff
				3: c = (c + ((a + up) >> 1)) & 0xff
				4:
					var ul := prev[x - 2] if x >= 2 else 0
					var pp := a + up - ul
					var pa := absi(pp - a)
					var pb := absi(pp - up)
					var pc := absi(pp - ul)
					c = (c + (a if pa <= pb and pa <= pc else (up if pb <= pc else ul))) & 0xff
			row[x] = c
		for x in width:
			_gray[y * width + x] = ((row[x * 2] << 8) | row[x * 2 + 1]) / 65535.0
		prev = row.duplicate()
	return true
