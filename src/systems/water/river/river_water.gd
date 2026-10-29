class_name RiverWater
extends Node3D
## The world's rivers: their water drawn as ribbon meshes along each channel
## (RiverRibbons, river.gdshader), the splash and mist where their waterfalls
## land (RiverSpray) and their water body (RiverBody). The ground's banks cut
## the water's edge.

var material: ShaderMaterial
var body: RiverBody


func setup(world: WorldData) -> void:
	material = ShaderMaterial.new()
	material.shader = preload("res://src/systems/water/river/river.gdshader")
	material.render_priority = 1   # (over the sea where the two overlap, at a mouth)
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = RiverRibbons.build(world.rivers, world)
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)
	add_child(RiverSpray.build(world))
	# the islands, for the water flowing round them
	var isl: Array[Vector4] = []
	var sizes: Array[Vector3] = []
	for i: Dictionary in world.islands.slice(0, 8):
		isl.append(Vector4(i.x, i.z, i.dx, i.dz))
		sizes.append(Vector3(i.length * 0.5, i.width, i.top))
	isl.resize(8)
	sizes.resize(8)
	material.set_shader_parameter("island_count", mini(world.islands.size(), 8))
	material.set_shader_parameter("islands", isl)
	material.set_shader_parameter("island_sizes", sizes)
	body = RiverBody.new()
	body.material = material
	body.setup(world)
	add_child(body)


func set_view(pos: Vector3) -> void:
	material.set_shader_parameter("view_pos", pos)
