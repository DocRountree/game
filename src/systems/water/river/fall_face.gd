class_name FallFace
extends RefCounted
## One waterfall's face: the rock is stepped in rough ledges (rows of cells,
## each row's cells offset from the last like rough brickwork, each cell's top
## a little higher or lower than its neighbours'), and the water comes down it
## in a few separate streams, rock between them. Each stream leaves the lip at
## its own place and width and runs down the face, falling nearly sheer from
## each ledge to the next; where it drops off a ledge it may step aside a
## little, swell or narrow, now and then split in two (the two drifting
## apart) or, if it is a thin one, give out.
##
## Positions are in the face's own terms: u across it (m, + to the left of
## the flow, 0 mid-channel) and d down it (m below the lip). The ribbon lays
## its water and the rock under it by rock_out() and water_out() (how far out
## from the cliff, m); the river shader reads the same cells from texture()
## and streams (see river.gdshader) to draw the streams and leave the rock
## between them bare.

const ROW_H := Vector2(2.2, 3.4)    ## Range of the rows' height (m).
const COL_W := Vector2(3.0, 5.5)    ## Range of the cells' width (m).
const LEDGE := Vector2(0.3, 0.75)   ## How far each ledge stands out (m).
const TOP_CLEAR := 0.35             ## The lip's top and the foot are smooth (m).
const FOOT_CLEAR := 0.6
const STREAM_STEP := 0.25           ## The streams are kept every this much down the face (m).
const MAX_STREAMS := 8
const PRE := 2.5                    ## The face's rock begins this far above its lip (m upstream).
const LIP_STEP := 1.2               ## The rock at the lip varies every this much across (m).
const LIP_ROCK := Vector2(0.15, 0.5)  ## How far it stands above the water there (m).

var height := 0.0       ## The drop (m).
var half_width := 0.0   ## Of the water at the face (m).
var row_h := 0.0
var col_w := 0.0
var u0 := 0.0           ## u where each row's first cell starts (before its offset).
var rows := 0
var cols := 0
var row_off := PackedFloat32Array()   ## Per row: its cells' offset (m).
var jitter := PackedFloat32Array()    ## Per cell: how far its top is moved (m).
var ledge := PackedFloat32Array()     ## Per cell: how far its ledge stands out (m).
var streams := 0
var s_rows := 0                        ## Samples down the face, STREAM_STEP apart.
var s_centre := PackedFloat32Array()   ## Per sample and stream (s_rows * streams): its middle (u, m).
var s_half := PackedFloat32Array()     ## And its half width (m; 0 where it isn't).
var u_lo := 0.0                        ## The streams' furthest reach either way across the face (m).
var u_hi := 0.0
var lip_h := PackedFloat32Array()      ## The rock at the lip between the streams: its height above the water, every LIP_STEP across (m).


static func make(drop: float, hw: float, seed_: int) -> FallFace:
	var f := FallFace.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	f.height = drop
	f.half_width = hw
	f.rows = maxi(1, roundi(drop / rng.randf_range(ROW_H.x, ROW_H.y)))
	f.row_h = drop / f.rows
	f.col_w = rng.randf_range(COL_W.x, COL_W.y)
	f.cols = ceili(2.0 * hw / f.col_w) + 3
	f.u0 = -0.5 * f.cols * f.col_w - 0.5 * f.col_w
	f.row_off.resize(f.rows)
	f.jitter.resize(f.rows * f.cols)
	f.ledge.resize(f.rows * f.cols)
	for r in f.rows:
		f.row_off[r] = rng.randf() * f.col_w
		for c in f.cols:
			var i := r * f.cols + c
			f.jitter[i] = 0.0 if r == 0 else rng.randf_range(-0.3, 0.3) * f.row_h
			f.ledge[i] = rng.randf_range(LEDGE.x, LEDGE.y)
	f._make_streams(rng)
	f.lip_h.resize(ceili((f.u_hi - f.u_lo + 4.0 * f.col_w) / LIP_STEP) + 2)
	for i in f.lip_h.size():
		f.lip_h[i] = rng.randf_range(LIP_ROCK.x, LIP_ROCK.y)
	return f


# The streams: each a list of (depth, middle, half width) keys, one at the
# lip and one at each ledge it drops off, sampled every STREAM_STEP down the
# face (easing over to each new key just below its ledge).
func _make_streams(rng: RandomNumberGenerator) -> void:
	var room := maxf(half_width * 0.85, 0.6)
	var n0 := clampi(roundi(2.0 * room / rng.randf_range(3.0, 4.5)), 1, 6)
	var keys: Array = []   # per stream: Array of Vector3(d, centre, half)
	var slot := 2.0 * room / n0
	for i in n0:
		var half := rng.randf_range(0.6, 1.5) if rng.randf() < 0.7 else rng.randf_range(1.8, 3.0)
		half = minf(half, 0.42 * slot)
		keys.append([Vector3(0.0, -room + (i + 0.5 + rng.randf_range(-0.3, 0.3)) * slot, half)])
	for r in range(1, rows):
		var d := r * row_h
		for si in keys.size():
			var ks: Array = keys[si]
			var last: Vector3 = ks[ks.size() - 1]
			if last.z <= 0.0:
				continue
			var c := last.y + rng.randf_range(-0.6, 0.6) * col_w * 0.6
			var h := clampf(last.z * rng.randf_range(0.85, 1.2), 0.3, 3.0)
			if keys.size() < MAX_STREAMS and h > 0.45 and rng.randf() < 0.18:
				# it splits: the new one born where it is, the two drifting apart
				var born: Array = [Vector3(d - 0.01, last.y, 0.0), Vector3(d, last.y + 0.5 * col_w, h * 0.65)]
				keys.append(born)
				c -= 0.5 * col_w
				h *= 0.65
			elif keys.size() > 1 and h < 0.4 and rng.randf() < 0.15:
				h = 0.0   # (a thin one gives out)
			c = clampf(c, -room + h, room - h)
			ks.append(Vector3(d, c, h))
	streams = keys.size()
	s_rows = int(ceil(height / STREAM_STEP)) + 1
	s_centre.resize(s_rows * streams)
	s_half.resize(s_rows * streams)
	for j in s_rows:
		var d := j * STREAM_STEP
		for si in streams:
			var ks: Array = keys[si]
			var a: Vector3 = ks[0]
			var v := Vector2(a.y, 0.0 if d < a.x else a.z)
			for q in range(1, ks.size()):
				var b: Vector3 = ks[q]
				if d < b.x:
					break
				var t := smoothstep(b.x, b.x + 0.4, d)
				var prev: Vector3 = ks[q - 1]
				v = Vector2(lerpf(prev.y, b.y, t), lerpf(prev.z if d >= prev.x else 0.0, b.z, t))
			s_centre[j * streams + si] = v.x
			s_half[j * streams + si] = v.y
			if v.y > 0.0:
				u_lo = minf(u_lo, v.x - v.y)
				u_hi = maxf(u_hi, v.x + v.y)


## How far inside the nearest stream (u, d) is (m; negative outside them all).
func inside(u: float, d: float) -> float:
	var fy := clampf(d / STREAM_STEP, 0.0, s_rows - 1.001)
	var j := int(fy)
	var a := fy - j
	var best := -1e3
	for si in streams:
		var c := lerpf(s_centre[j * streams + si], s_centre[(j + 1) * streams + si], a)
		var h := lerpf(s_half[j * streams + si], s_half[(j + 1) * streams + si], a)
		if h > 0.05:
			best = maxf(best, h - absf(u - c))
	return best


## Where the streams land on the ledges: Vector3(u, d, half width).
func landings() -> PackedVector3Array:
	var out := PackedVector3Array()
	for r in range(1, rows):
		var j := clampi(roundi(r * row_h / STREAM_STEP), 0, s_rows - 1)
		for si in streams:
			var h := s_half[j * streams + si]
			if h > 0.2:
				out.append(Vector3(s_centre[j * streams + si], r * row_h, h))
	return out


## Where the streams land at the foot: Vector2(u, half width) each.
func feet() -> PackedVector2Array:
	var out := PackedVector2Array()
	var j := s_rows - 1
	for si in streams:
		var h := s_half[j * streams + si]
		if h > 0.05:
			out.append(Vector2(s_centre[j * streams + si], h))
	return out


## The rock at the lip at (u, d): Vector2(how far it stands above the water
## there in m, how much it's there 0..1). Between the streams it rises out of
## the bed over the last PRE m before the lip (d negative) and rounds over
## it, in rough humps the streams run between, the water parting round them.
func lip_rock(u: float, d: float) -> Vector2:
	var gap := -inside(u, 0.0)
	var f := clampf((u - u_lo + 2.0 * col_w) / LIP_STEP, 0.0, lip_h.size() - 1.001)
	var i := int(f)
	var a := smoothstep(0.0, 1.0, f - i)
	var h := lerpf(lip_h[i], lip_h[i + 1], a)
	var across := smoothstep(0.1, 1.6, gap)   # (the stream's own banks, sloping)
	var along := smoothstep(-PRE, -0.6, d) * (1.0 - smoothstep(0.1, 0.9, d))
	return Vector2(h, across * along)


func cell_centre(r: int, c: int) -> float:
	return u0 + row_off[r] + (c + 0.5) * col_w


## The column of row r at u.
func col_at(r: int, u: float) -> int:
	return clampi(floori((u - u0 - row_off[r]) / col_w), 0, cols - 1)


## The top of cell (r, c) (m below the lip).
func top_of(r: int, c: int) -> float:
	return r * row_h + jitter[r * cols + c]


## The cell at (u, d): Vector3(row, column, how far down it, 0..1).
func cell_at(u: float, d: float) -> Vector3:
	var r := clampi(floori(d / row_h), 0, rows - 1)
	var c := col_at(r, u)
	if r > 0 and d < top_of(r, c):
		r -= 1
		c = col_at(r, u)
	elif r < rows - 1:
		var c2 := col_at(r + 1, u)
		if d >= top_of(r + 1, c2):
			r += 1
			c = c2
	var t0 := top_of(r, c)
	var t1 := height if r == rows - 1 else top_of(r + 1, col_at(r + 1, u))
	return Vector3(r, c, clampf((d - t0) / maxf(t1 - t0, 0.01), 0.0, 1.0))


## How much the face's ledges stand out at (u, d): 0 over the lip, at the
## foot and out beside the streams (where the rock sinks back into the
## walls), 1 in the face proper, where the water comes down it.
func relief(u: float, d: float) -> float:
	var out := maxf(u_lo - u, u - u_hi)
	return smoothstep(0.0, TOP_CLEAR, d) * (1.0 - smoothstep(height - FOOT_CLEAR, height, d)) \
			* (1.0 - smoothstep(0.6, 2.4, out))


## How far out from the cliff the rock stands at (u, d) (m): each ledge
## stands out at the top of its cell and the rock falls back under it.
func rock_out(u: float, d: float) -> float:
	var c := cell_at(u, d)
	return ledge[int(c.x) * cols + int(c.y)] * (1.0 - c.z) * relief(u, d)


## How far out the water is at (u, d): over a wet cell it leaves the ledge
## and falls nearly sheer to the one below; elsewhere it lies on the rock
## (and isn't drawn).
func water_out(u: float, d: float) -> float:
	var c := cell_at(u, d)
	var i := int(c.x) * cols + int(c.y)
	var rock := ledge[i] * (1.0 - c.z) * relief(u, d)
	if inside(u, d) < -0.2:
		return rock + 0.03
	return maxf(ledge[i] * (1.0 - 0.25 * c.z * c.z) * relief(u, d), rock) + 0.1


## The faces' cells as one texture for the shader: face f's rows start at
## params[f].x; texel (0, row) holds the row's offset, texel (1 + c, row)
## cell c's top jitter (g) and ledge (b). params: (first row, rows, row
## height, cell width) per face; u0s: each face's u0.
static func texture(faces: Array[FallFace], params: PackedVector4Array, u0s: PackedFloat32Array) -> ImageTexture:
	var w := 2
	var h := 0
	for f in faces:
		w = maxi(w, f.cols + 1)
		h += f.rows
	var img := Image.create(w, maxi(h, 1), false, Image.FORMAT_RGBAF)
	var row0 := 0
	for f in faces:
		params.append(Vector4(row0, f.rows, f.row_h, f.col_w))
		u0s.append(f.u0)
		for r in f.rows:
			img.set_pixel(0, row0 + r, Color(f.row_off[r], 0.0, 0.0, 0.0))
			for c in f.cols:
				var i := r * f.cols + c
				img.set_pixel(1 + c, row0 + r, Color(0.0, f.jitter[i], f.ledge[i], 0.0))
		row0 += f.rows
	return ImageTexture.create_from_image(img)


## The faces' streams as one texture: face f's samples start at row
## sparams[f].x; texel (s, row) holds stream s's middle (r) and half width (g).
## sparams: (first row, samples, STREAM_STEP, streams) per face.
static func stream_texture(faces: Array[FallFace], sparams: PackedVector4Array) -> ImageTexture:
	var h := 0
	for f in faces:
		h += f.s_rows
	var img := Image.create(MAX_STREAMS, maxi(h, 1), false, Image.FORMAT_RGF)
	var row0 := 0
	for f in faces:
		sparams.append(Vector4(row0, f.s_rows, STREAM_STEP, f.streams))
		for j in f.s_rows:
			for si in f.streams:
				img.set_pixel(si, row0 + j, Color(f.s_centre[j * f.streams + si], f.s_half[j * f.streams + si], 0.0))
		row0 += f.s_rows
	return ImageTexture.create_from_image(img)
