@tool
extends MeshInstance3D
## Low-poly hull built from three outlines (keel, waterline stripe, deck),
## so its proportions follow the exported size. Origin at the keel, bow toward -Z.

@export var length := 7.0:
	set(v):
		length = v
		_rebuild()
@export var beam := 2.6:
	set(v):
		beam = v
		_rebuild()
@export var depth := 1.0:
	set(v):
		depth = v
		_rebuild()

const BOTTOM := Color(0.45, 0.06, 0.05)
const SIDES := Color(0.85, 0.85, 0.82)
const DECK := Color(0.45, 0.30, 0.17)


func _ready() -> void:
	_rebuild()


func _outline(y: float, s: float) -> PackedVector3Array:
	var w := beam / 2.0 * s
	var pts := [Vector2(length / 2.0 - (1.0 - s) * 0.9, 0.0), Vector2(length * 0.15, w),
			Vector2(-length / 2.0, w * 0.92), Vector2(-length / 2.0, -w * 0.92), Vector2(length * 0.15, -w)]
	var out := PackedVector3Array()
	for p: Vector2 in pts:
		out.append(Vector3(p.y, y, -p.x))   # (forward, side) -> Godot: forward is -Z
	return out


func _rebuild() -> void:
	if not is_inside_tree():
		return
	var bot := _outline(0.0, 0.6)
	var mid := _outline(0.4, 0.85)
	var top := _outline(depth, 1.0)
	var centre := Vector3(0, depth / 2.0, 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := top.size()
	for i in n:
		var j := (i + 1) % n
		_quad(st, bot[j], bot[i], mid[i], mid[j], BOTTOM, centre)
		_quad(st, mid[j], mid[i], top[i], top[j], SIDES, centre)
	for i in range(1, n - 1):
		_tri(st, top[0], top[i], top[i + 1], DECK, centre)
		_tri(st, bot[0], bot[i + 1], bot[i], BOTTOM, centre)
	mesh = st.commit()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, centre: Vector3) -> void:
	_tri(st, a, b, c, col, centre)
	_tri(st, a, c, d, col, centre)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color, centre: Vector3) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	if nrm.dot((a + b + c) / 3.0 - centre) < 0.0:   # flat-shaded, always facing outward
		nrm = -nrm
		var t := b
		b = c
		c = t
	for p in [a, c, b]:   # Godot's front faces wind clockwise
		st.set_color(col)
		st.set_normal(nrm)
		st.add_vertex(p)
