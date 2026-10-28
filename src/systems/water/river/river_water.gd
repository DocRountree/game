class_name RiverWater
extends Node3D
## The world's rivers: their water drawn as ribbon meshes along each channel
## (RiverRibbons, river.gdshader) and their water body (RiverBody). The
## ground's banks cut the water's edge.

var material: ShaderMaterial
var body: RiverBody


func setup(world: WorldData) -> void:
	material = ShaderMaterial.new()
	material.shader = preload("res://src/systems/water/river/river.gdshader")
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = RiverRibbons.build(world.rivers)
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)
	body = RiverBody.new()
	body.material = material
	body.setup(world)
	add_child(body)


func set_view(pos: Vector3) -> void:
	material.set_shader_parameter("view_pos", pos)
