class_name RibbonSections
extends RefCounted
## Stage 3 of a river's ribbon: its cross-sections. resolution() picks how
## many vertices each has (ACROSS along the plain river; about a metre apart
## round a fall; FALL_SPACING apart down a fall's face and just above its
## lip); build() lays each one out (and, where the next has a different
## number, a copy with that many, so the two meet edge to edge), and with a
## fall's face the rock under its water (FallFace's ledges); settle() lifts
## the water clear of the rock wherever the rock between two neighbouring
## vertices would come through it.

const ACROSS := 9          ## Vertices across the ribbon.
const ACROSS_FINE := 25    ## At most this many across it near a fall (about a metre apart).
const FALL_SPACING := 0.4  ## Across a fall's face, vertices this far apart (m).
const ACROSS_FALL := 181   ## At most this many.
const REACH := 1.5         ## The ribbon reaches this many half widths from the centre.
const FILM := 0.45         ## The water's thickness down a riser (m), over the rock under each vertex.
const FILM_MIN := 0.2      ## And at least this, over the rock between vertices.

var rows: Array[PackedVector3Array] = []
var row_x: Array[PackedFloat32Array] = []    ## Each vertex's distance from the centre, in half widths.
var row_lo: Array[PackedFloat32Array] = []   ## Its height's bounds (empty: none), held to after settle().
var row_hi: Array[PackedFloat32Array] = []
var row_k := PackedInt32Array()               ## Which centreline sample each row is.
var row_rock: Array[PackedVector3Array] = []  ## Down a fall: the rock under the water (empty otherwise, and for copies).


## How many vertices across each cross-section.
static func resolution(c: RibbonCentreline, f: RibbonFallSpans, geo: FallGeometry) -> PackedInt32Array:
	var fine := PackedInt32Array()
	fine.resize(c.count)
	var k2 := 0
	while k2 < c.count:
		if minf(f.below[k2], f.to_fall[k2]) >= RibbonFallSpans.FINE_MARGIN:
			fine[k2] = 0
			k2 += 1
			continue
		var k3 := k2
		var widest := 0.0
		while k3 < c.count and minf(f.below[k3], f.to_fall[k3]) < RibbonFallSpans.FINE_MARGIN:
			widest = maxf(widest, c.hw[k3])
			k3 += 1
		var nf := clampi(2 * ceili(1.05 * widest) + 1, ACROSS, ACROSS_FINE)
		for k in range(k2, k3):
			fine[k] = nf
		k2 = k3
	# (down a fall's face, much finer: the ledges and little falls on it)
	for k in c.count:
		var fk := f.face_at(k)
		if fk >= 0:
			fine[k] = clampi(2 * ceili(2.0 * geo.faces[fk].half_width / FALL_SPACING) + 1, ACROSS, ACROSS_FALL)
	return fine


static func build(c: RibbonCentreline, f: RibbonFallSpans, geo: FallGeometry, fine: PackedInt32Array,
		ground: TerrainSource) -> RibbonSections:
	var s := RibbonSections.new()
	for k in c.count:
		var n_here := fine[k] if fine[k] > 0 else ACROSS
		for kk in ([k - 1, k] if k > 0 and s.rows[s.rows.size() - 1].size() != n_here else [k]):
			var xs := PackedFloat32Array()
			var lo := PackedFloat32Array()
			var hi := PackedFloat32Array()
			var rk := PackedVector3Array()
			var fk := f.face_at(kk)
			var face: FallFace = geo.faces[fk] if fk >= 0 else null
			s.rows.append(section(kk, n_here, c, f, face, ground, xs, lo, hi, rk))
			s.row_x.append(xs)
			s.row_lo.append(lo)
			s.row_hi.append(hi)
			s.row_k.append(kk)
			s.row_rock.append(rk if kk == k else PackedVector3Array())   # (not for the copies)
	return s


## Where the water lies on the rock: wherever the rock between two
## neighbouring vertices (across, down, and along each triangle's diagonal)
## would come through the water, both are lifted clear of it; then each is
## held to its bounds again (its lip, its pool, the banks).
func settle(ground: TerrainSource) -> void:
	if ground == null:
		return
	for it in 2:
		for ri in rows.size():
			if row_lo[ri].is_empty():
				continue
			var a := rows[ri]
			var n := a.size()
			var nxt := ri + 1 < rows.size() and not row_lo[ri + 1].is_empty() and rows[ri + 1].size() == n and row_k[ri + 1] != row_k[ri]
			var b := rows[ri + 1] if nxt else PackedVector3Array()
			for q in n:
				var inner_q := absf(row_x[ri][q]) < 0.85
				if q + 1 < n and inner_q and absf(row_x[ri][q + 1]) < 0.85:
					var m := (a[q] + a[q + 1]) * 0.5
					var lift := ground.surface_at(m.x, m.z) + FILM_MIN - m.y
					if lift > 0.0:
						a[q].y += lift
						a[q + 1].y += lift
				if nxt and inner_q:
					var m := (a[q] + b[q]) * 0.5
					var lift := ground.surface_at(m.x, m.z) + FILM_MIN - m.y
					if lift > 0.0:
						a[q].y += lift
						b[q].y += lift
					if q + 1 < n and absf(row_x[ri][q + 1]) < 0.85:
						m = (b[q] + a[q + 1]) * 0.5
						lift = ground.surface_at(m.x, m.z) + FILM_MIN - m.y
						if lift > 0.0:
							b[q].y += lift
							a[q + 1].y += lift
			rows[ri] = a
			if nxt:
				rows[ri + 1] = b
	for ri in rows.size():
		if row_lo[ri].is_empty():
			continue
		var a := rows[ri]
		for q in a.size():
			a[q].y = clampf(a[q].y, row_lo[ri][q], row_hi[ri][q])
		rows[ri] = a


## One cross-section's vertices (n of them, left bank to right): level across
## the channel, dipping a little past the banks; down a riser, lying on the
## rock; and just below one, over any of the rock at its foot that stands
## above the pool (the 2.5 m grid can't make the foot of a tall riser sharp:
## the water pours on over it). xs gets each vertex's distance from the
## centre in half widths; lo and hi its bounds; rock the rock under it.
static func section(k: int, n: int, c: RibbonCentreline, f: RibbonFallSpans, face: FallFace, ground: TerrainSource,
		xs: PackedFloat32Array, lo: PackedFloat32Array, hi: PackedFloat32Array, rock: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var pts := c.pts
	var tan := c.tans[k]
	var nrm := Vector2(-tan.y, tan.x)
	var w := c.width(k)
	var sheet := f.sheet[k]
	var top := f.top[k]
	# near a fall's lip and down it the ribbon keeps to the channel, not
	# reaching out past the gorge's walls
	var reach := lerpf(1.05, REACH + 0.7 * c.spread[k], smoothstep(0.5 * c.hw[k], 2.0 * c.hw[k] + 4.0, f.to_fall[k]))
	if sheet >= 0.0 or face:
		# (down a fall's face and just above its lip, out over the walls
		# beside it: its rock sinks back into them)
		reach = 2.0 if face else 1.05
	var inner := 0.8 / maxf(absf(c.bend[k]), 1e-6)
	for q in n:
		var u := lerpf(-1.0, 1.0, float(q) / (n - 1))
		var side := u * w * reach   # m across, + to the left
		if side * c.bend[k] > 0.0:
			side = signf(side) * minf(absf(side), inner)
		var off := nrm * side
		var x := side / maxf(w, 0.01)   # (half widths)
		# the surface is level across; past the bank it dips a little, so
		# the ground always covers the ribbon's edge
		var dip := maxf(0.0, absf(x) - 1.25) * 0.6
		var v := Vector3(pts[k].x + off.x, pts[k].y - dip, pts[k].z + off.y)
		if face and sheet < 0.0 and ground:
			# just above its lip: the rock rises out of the bed between the
			# streams and stands above the water there (elsewhere it's
			# under the ground); the water stays level
			var g := ground.surface_at(v.x, v.z)
			var lr := face.lip_rock(side, f.near_d[k])
			rock.append(Vector3(v.x, lerpf(g - 0.35, pts[k].y + lr.x, lr.y), v.z))
		elif face and sheet >= 0.0 and ground:
			# down a fall's face: the rock stands out from the ground (the
			# highest of it round the vertex, so the terrain can't show
			# through) where the water comes down it, sinking back under
			# the ground out beside the streams; the water lies out over
			# it, leaving each ledge where a stream runs
			var g := ground.surface_at(v.x, v.z)
			var gb := g
			for d: Vector2 in [tan * 0.3, -tan * 0.3, nrm * 0.3, -nrm * 0.3]:
				gb = maxf(gb, ground.surface_at(v.x + d.x, v.z + d.y))
			var fh := top - f.floor_[k]
			var ends := 1.0 - smoothstep(0.0, 0.5, sheet) * (1.0 - smoothstep(fh - 0.5, fh, sheet))   # (1 at its lip and foot)
			var ax := absf(x)
			var b := Vector3(v.x, gb + 0.1 * (1.0 - smoothstep(1.4, 1.9, ax)) - 0.3 * smoothstep(1.7, 2.0, ax)
					- 0.3 * smoothstep(1.0, 1.3, ax) * ends, v.z)
			var outv := Vector3(tan.x, 0.0, tan.y)
			var rel := smoothstep(0.0, 0.3, face.relief(side, sheet))
			var br := Vector3(v.x, lerpf(g - 0.35, b.y, rel), v.z) + outv * face.rock_out(side, sheet)
			var lr := face.lip_rock(side, sheet)   # (at the lip, the humps between the streams round over it)
			br.y = maxf(br.y, lerpf(br.y, top + lr.x, lr.y))
			rock.append(br)
			v = b + outv * face.water_out(side, sheet)
			# (never far below the face's own line: over the lip it pours
			# clear of the rock, rather than dropping down onto it)
			v.y = clampf(v.y, pts[k].y - 0.3 - 0.4 * smoothstep(0.7, 1.0, ax), top + 0.05)
		elif (sheet >= 0.0 or f.spill[k] > -INF) and ground:
			# (lo and hi: its bounds, held to again once the water has been
			# lifted clear of the rock between vertices)
			var g := ground.surface_at(v.x, v.z)
			var ax := absf(x)
			if sheet >= 0.0:
				# down a riser: a film on the rock, tucked under the ground at
				# its edges; never above its lip, nor below the pool it falls
				# into, and toward its edges never above the water's level there
				var film := FILM * (1.0 - smoothstep(0.7, 0.98, ax)) - 0.35 * smoothstep(0.9, 1.05, ax)
				var cap := 2.0 * (1.0 - smoothstep(0.6, 0.95, ax))
				lo.append(f.floor_[k])
				hi.append(minf(pts[k].y + cap, top))
				v.y = clampf(g + film, lo[q], hi[q])
			else:
				# at its foot: level, but lifted over rock standing above it
				lo.append(v.y)
				hi.append(v.y + (f.spill[k] - v.y) * (1.0 - smoothstep(0.85, 1.0, ax)))   # (all across the fall, but not up the walls beside it)
				v.y = clampf(g + FILM, lo[q], hi[q])
		out.append(v)
		xs.append(x)
	return out


## The point u (0..1, left to right) of the way across a cross-section.
static func point_across(row: PackedVector3Array, u: float) -> Vector3:
	var fl := u * (row.size() - 1)
	var i := mini(int(fl), row.size() - 2)
	return row[i].lerp(row[i + 1], fl - i)
