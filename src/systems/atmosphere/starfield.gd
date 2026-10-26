@tool
class_name Starfield
extends MultiMeshInstance3D
## The fixed sky as one instanced draw: stars (white points) and Messier
## objects (grey smudges at their true angular size and orientation). The
## planets wander, so they live on their own layer (PlanetLayer).
##
## Everything sits on a big sphere around the camera in equatorial coordinates;
## Atmosphere rotates the node into the local sky for the date and time.
## Per instance: COLOR.rgb = colour; CUSTOM = (brightness, kind, size px, 0)
## with kind 0 star, 2 deep-sky object (ellipse in the instance basis).

const RADIUS := 2500.0          ## Inside the camera's far plane.
const STAR_SIZE_PX := 2.2       ## Stars are points: every star the same size.

@export var catalog: StarCatalog
## Uniform boost over real brightness: a magnitude-1 star draws at this level
## (1 = screen white). Brighter stars bloom; magnitude 6 is a faint dot.
@export var brightness := 1.5


func _ready() -> void:
	_build()


func _build() -> void:
	if catalog == null:
		return
	var stars := catalog.star_count()
	var dsos := catalog.deep_sky_count()
	var n := stars + dsos
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = n
	var buf := PackedFloat32Array()
	buf.resize(n * 20)   # 12 transform + 4 colour + 4 custom
	var s := catalog.stars
	for i in stars:
		_write(buf, i, Basis(), _unit(s[i * 3], s[i * 3 + 1]), Color.WHITE,
				brightness * _flux(s[i * 3 + 2]), 0.0, STAR_SIZE_PX)
	var d := catalog.deep_sky
	for j in dsos:
		var o := j * 6
		var ra := d[o]
		var dec := d[o + 1]
		var pa := deg_to_rad(d[o + 5])
		# sky-plane axes at the object: north (toward the pole) and east
		var north := Vector3(-sin(dec) * cos(ra), -sin(dec) * sin(ra), cos(dec))
		var east := Vector3(-sin(ra), cos(ra), 0.0)
		var major := north * cos(pa) + east * sin(pa)
		var minor := east * cos(pa) - north * sin(pa)
		# the quad spans twice the object's diameter so its soft edge can fade out
		var arcmin := deg_to_rad(1.0 / 60.0) * RADIUS * 2.0
		var basis := Basis(major * d[o + 3] * arcmin, minor * d[o + 4] * arcmin, _unit(ra, dec))
		_write(buf, stars + j, basis, _unit(ra, dec), Color.WHITE,
				brightness * _deep_sky_glow(d[o + 2], d[o + 3], d[o + 4]), 2.0, 0.0)
	mm.buffer = buf
	mm.custom_aabb = AABB(Vector3.ONE * -RADIUS, Vector3.ONE * RADIUS * 2.0)
	multimesh = mm
	custom_aabb = mm.custom_aabb


## Place the sky: basis maps equatorial coordinates into the world; visibility 0..1.
func update_sky(equatorial_to_world: Basis, visibility: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		global_transform = Transform3D(equatorial_to_world, cam.global_position)
		var mat := material_override as ShaderMaterial
		mat.set_shader_parameter("visibility", visibility)
		mat.set_shader_parameter("pixel_angle", deg_to_rad(cam.fov) / maxf(get_viewport().get_visible_rect().size.y, 1.0))
	visible = visibility > 0.0


func _write(buf: PackedFloat32Array, i: int, basis: Basis, dir: Vector3, colour: Color,
		bright: float, kind: float, size_px: float) -> void:
	var p := dir * RADIUS
	var o := i * 20
	buf[o] = basis.x.x      # rows of the 3x4 transform
	buf[o + 1] = basis.y.x
	buf[o + 2] = basis.z.x
	buf[o + 3] = p.x
	buf[o + 4] = basis.x.y
	buf[o + 5] = basis.y.y
	buf[o + 6] = basis.z.y
	buf[o + 7] = p.y
	buf[o + 8] = basis.x.z
	buf[o + 9] = basis.y.z
	buf[o + 10] = basis.z.z
	buf[o + 11] = p.z
	buf[o + 12] = colour.r
	buf[o + 13] = colour.g
	buf[o + 14] = colour.b
	buf[o + 15] = 1.0
	buf[o + 16] = bright
	buf[o + 17] = kind
	buf[o + 18] = size_px
	buf[o + 19] = 0.0


static func _unit(ra: float, dec: float) -> Vector3:
	return Vector3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))


# True relative brightness from magnitude (2.512x per magnitude), 1 at magnitude 1.
# The only boost is the uniform `brightness` multiplier on every object.
static func _flux(magnitude: float) -> float:
	return pow(10.0, -0.4 * (magnitude - 1.0))


# Peak glow of a deep-sky object: its light spread over its area, boosted so
# the big naked-eye ones (M31, M42, M45) read as faint smudges, as they do outdoors.
static func _deep_sky_glow(magnitude: float, major: float, minor: float) -> float:
	var surface := pow(10.0, -0.4 * (magnitude - 4.0)) / sqrt(major * minor / 100.0 + 1.0)
	return clampf(0.012 * sqrt(surface), 0.0, 0.035)
