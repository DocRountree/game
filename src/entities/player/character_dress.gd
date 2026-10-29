class_name CharacterDress
extends RefCounted
## The part of the character that changes shape with its traits, as one mesh in
## the head's frame (the colours are the palette's, not the mesh's): hair,
## facial hair, hat and accessories. CharacterTraits.apply_to() rebuilds it
## when the traits are applied.


static func build(t: CharacterTraits) -> ArrayMesh:
	var mb := MeshBuilder.new()
	HairBuilder.add_hair(mb, t)
	HairBuilder.add_facial_hair(mb, t)
	add_hat(mb, t)
	add_accessories(mb, t)
	return mb.commit()


static func _xf(pos: Vector3, scale_ := Vector3.ONE, rot := Vector3.ZERO) -> Transform3D:
	return Transform3D(Basis.from_euler(rot).scaled(scale_), pos)


static func _cyl(top: float, bottom: float, h: float, seg := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


static func _sphere(r: float, segs := 16, rings := 8, half := false) -> SphereMesh:
	var s := SphereMesh.new()
	s.is_hemisphere = half
	if half:
		s.height = r
	s.radius = r
	if not half:
		s.height = 2.0 * r
	s.radial_segments = segs
	s.rings = rings
	return s


static func _torus(inner: float, outer: float) -> TorusMesh:
	var m := TorusMesh.new()
	m.inner_radius = inner
	m.outer_radius = outer
	m.rings = 16
	m.ring_segments = 6
	return m


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## The crown's outer radius at its foot: clear of the hair under it.
static func crown_radius(t: CharacterTraits) -> float:
	return 0.123 + minf(HairBuilder.thickness(t), 0.016) + 0.004


static func add_hat(mb: MeshBuilder, t: CharacterTraits) -> void:
	var cr := crown_radius(t)
	var slot := CharacterTraits.P_HAT
	match t.hat:
		"wide_brim":
			mb.add_mesh(_cyl(0.2, 0.2, 0.014), _xf(Vector3(0, 0.08, 0), Vector3(1.0, 1.0, 1.05)), slot)
			mb.add_mesh(_cyl(cr - 0.025, cr, 0.1), _xf(Vector3(0, 0.135, 0), Vector3(0.95, 1.0, 1.05)), slot)
			mb.add_mesh(_cyl(cr + 0.001, cr + 0.001, 0.022), _xf(Vector3(0, 0.096, 0), Vector3(0.95, 1.0, 1.05)), CharacterTraits.P_LEATHER)
		"cap":
			mb.add_mesh(_sphere(cr + 0.002, 16, 6, true), _xf(Vector3(0, 0.035, 0), Vector3(0.95, 0.85, 1.0)), slot)
			mb.add_mesh(_box(Vector3(0.17, 0.01, 0.1)), _xf(Vector3(0, 0.045, -0.15), Vector3.ONE, Vector3(0.12, 0, 0)), slot)
		"beanie":
			mb.add_mesh(_sphere(cr + 0.006, 16, 6, true), _xf(Vector3(0, 0.045, 0), Vector3(0.95, 1.05, 1.0)), slot)
			mb.add_mesh(_cyl(cr + 0.009, cr + 0.009, 0.035), _xf(Vector3(0, 0.055, 0), Vector3(0.95, 1.0, 1.0)), slot)
		"bandana":
			mb.add_mesh(_sphere(cr, 16, 6, true), _xf(Vector3(0, 0.04, 0), Vector3(0.95, 0.8, 1.0)), slot)
			mb.add_mesh(_sphere(0.032), _xf(Vector3(0, 0.03, 0.13), Vector3(1.0, 0.8, 0.8)), slot)


static func add_accessories(mb: MeshBuilder, t: CharacterTraits) -> void:
	var hv := HairBuilder.thickness(t)
	if t.has_accessory("glasses"):
		var slot := CharacterTraits.P_GLASSES
		for x: float in [-1.0, 1.0]:
			mb.add_mesh(_torus(0.026, 0.031), _xf(Vector3(0.043 * x, 0.012, -0.114), Vector3.ONE, Vector3(PI * 0.5, 0, 0)), slot)
			mb.add_mesh(_box(Vector3(0.004, 0.004, 0.1)), _xf(Vector3(0.087 * x, 0.014, -0.065)), slot)
		mb.add_mesh(_box(Vector3(0.026, 0.004, 0.004)), _xf(Vector3(0, 0.02, -0.117)), slot)
	if t.has_accessory("earrings"):
		for x: float in [-1.0, 1.0]:
			mb.add_mesh(_sphere(0.009, 8, 4), _xf(Vector3(0.124 * x, -0.032, 0.0)), CharacterTraits.P_EARRINGS)
			mb.add_mesh(_sphere(0.006, 8, 4), _xf(Vector3(0.124 * x, -0.048, 0.0)), CharacterTraits.P_EARRINGS)
	if t.has_accessory("necklace"):
		mb.add_mesh(_torus(0.056, 0.062), _xf(Vector3(0, -0.15, -0.005), Vector3(1, 1, 1.05)), CharacterTraits.P_NECKLACE)
		mb.add_mesh(_sphere(0.014, 8, 4), _xf(Vector3(0, -0.2, -0.062), Vector3(1, 1.3, 0.6)), CharacterTraits.P_NECKLACE)
	if t.has_accessory("scarf"):
		mb.add_mesh(_torus(0.04, 0.078), _xf(Vector3(0, -0.13, 0.0), Vector3(1.0, 0.8, 1.0)), CharacterTraits.P_SCARF)
		mb.add_mesh(_box(Vector3(0.055, 0.17, 0.018)), _xf(Vector3(0.05, -0.23, -0.1), Vector3.ONE, Vector3(0.12, 0, -0.1)), CharacterTraits.P_SCARF)
	if t.has_accessory("headband"):
		mb.add_mesh(_torus(0.112 + hv, 0.124 + hv), _xf(Vector3(0, 0.04, 0.0), Vector3(0.95, 0.9, 1.0)), CharacterTraits.P_HEADBAND)
	if t.hair_length > 0.15:
		if t.has_accessory("ponytail"):
			mb.add_mesh(_torus(0.014, 0.024), _xf(Vector3(0, -0.005, 0.135), Vector3.ONE, Vector3(PI * 0.5, 0, 0)), CharacterTraits.P_TIE)
		elif t.has_accessory("bun"):
			mb.add_mesh(_torus(0.04, 0.05), _xf(Vector3(0, 0.05, 0.125), Vector3.ONE, Vector3(PI * 0.3, 0, 0)), CharacterTraits.P_TIE)
