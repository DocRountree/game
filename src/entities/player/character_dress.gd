class_name CharacterDress
extends RefCounted
## The part of the character that changes shape with its traits, as one mesh in
## the head's frame (the colours are the palette's, not the mesh's): hair and
## facial hair (HairBuilder), the hat and accessories (each an AccessoryDef,
## found by ContentRegistry: their parts, fitted over the hair).
## CharacterTraits.apply_to() rebuilds it when the traits are applied.


static func build(t: CharacterTraits) -> ArrayMesh:
	var mb := MeshBuilder.new()
	HairBuilder.add_hair(mb, t)
	HairBuilder.add_facial_hair(mb, t)
	add_accessories(mb, t)
	return mb.commit()


## How far the hair stands off the scalp, as fitted parts see it (a hat
## presses it flat).
static func fit_scale(t: CharacterTraits) -> float:
	return crown_radius(t) / AccessoryDef.FIT_RADIUS


## The crown's outer radius at its foot: clear of the hair under it.
static func crown_radius(t: CharacterTraits) -> float:
	return 0.123 + minf(HairBuilder.thickness(t), 0.016) + 0.004


## The hat (traits.hat, an AccessoryDef of kind HAT) and the accessories and
## hair style's tie (traits.accessories), from their definitions' parts.
static func add_accessories(mb: MeshBuilder, t: CharacterTraits) -> void:
	var ids: Array[String] = []
	if t.hat != "none":
		ids.append(t.hat)
	ids.append_array(t.accessories)
	var fit := fit_scale(t)
	for id in ids:
		var d := ContentRegistry.by_id(&"AccessoryDef", StringName(id)) as AccessoryDef
		if d == null or t.hair_length < d.min_hair:
			continue
		if d.kind == AccessoryDef.Kind.STYLE and t.hair_style() != id:
			continue   # (only one style at a time)
		for p in d.parts:
			var xf := p.transform
			if p.fit_hair:
				xf = Transform3D(Basis.from_scale(Vector3(fit, 1.0, fit)), Vector3.ZERO) * xf
			mb.add_mesh(p.mesh, xf, p.slot if p.slot >= 0 else d.slot)
