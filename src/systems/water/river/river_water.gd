class_name RiverWater
extends Node3D
## The world's rivers: their water drawn as ribbon meshes along each channel
## (RiverRibbons, river.gdshader) and their water body (RiverBody). Terrain
## makes one and hands it the height map, so the water fades out exactly
## where the drawn ground rises through it.

var material: ShaderMaterial
var body: RiverBody


func setup(world: WorldData, height_hi: Texture2D, height_lo: Texture2D) -> void:
	material = ShaderMaterial.new()
	material.shader = preload("res://src/systems/water/river/river.gdshader")
	material.set_shader_parameter("height_hi", height_hi)
	material.set_shader_parameter("height_lo", height_lo)
	material.set_shader_parameter("world_size", world.size)
	material.set_shader_parameter("texels", world.texels)
	material.set_shader_parameter("h_min", world.h_min)
	material.set_shader_parameter("h_scale", world.h_scale)
	material.set_shader_parameter("top_lod", Terrain.LODS - 1)
	material.set_shader_parameter("lod_range0", 4.0 * Terrain.GRID * world.spacing)
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
