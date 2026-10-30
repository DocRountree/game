class_name RiverWater
extends Node3D
## The world's rivers: their water drawn as ribbon meshes along each channel
## (RiverRibbons, river.gdshader), with the rock of their waterfalls' faces
## (fall_rock.gdshader, solid, to climb on) and the splash and mist where the
## water lands (RiverSpray), and their water body (RiverBody). The ground's
## banks cut the water's edge.

var material: ShaderMaterial
var body: RiverBody


## Build the rivers of `world` (ground questions go to Terrain; the falls'
## rock is coloured with the ground's masks texture, `ground_masks`).
func setup(world: WorldData, ground_masks: Texture2D = null) -> void:
	material = ShaderMaterial.new()
	material.shader = preload("res://src/systems/water/river/river.gdshader")
	material.render_priority = 1   # (over the sea where the two overlap, at a mouth)
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	var fo := FallGeometry.new()
	mi.mesh = RiverRibbons.build(world.rivers, Terrain.source(), fo)
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)
	var rock := MeshInstance3D.new()
	rock.name = "FallRock"
	rock.mesh = fo.rock_mesh()
	var rock_mat := ShaderMaterial.new()
	rock_mat.shader = preload("res://src/systems/water/river/fall_rock.gdshader")
	if ground_masks:   # (coloured as the ground is, so it fades into the walls)
		rock_mat.set_shader_parameter("ground", ground_masks)
		rock_mat.set_shader_parameter("world_size", world.size)
	rock.material_override = rock_mat
	rock.top_level = true
	add_child(rock)
	# (solid: you climb and stand on the ledges you see, not the ground behind
	# them, and the camera keeps out of them)
	if rock.mesh.get_surface_count() > 0:
		var body := StaticBody3D.new()
		body.name = "FallRockBody"
		body.top_level = true
		var cs := CollisionShape3D.new()
		cs.shape = rock.mesh.create_trimesh_shape()
		body.add_child(cs)
		add_child(body)
	# the falls' ledges and streams, for the water down their faces
	var params := PackedVector4Array()
	var u0s := PackedFloat32Array()
	material.set_shader_parameter("fall_cells", FallFace.texture(fo.faces, params, u0s))
	var extra: Array[Vector2] = []
	for i in fo.faces.size():
		extra.append(Vector2(u0s[i], fo.faces[i].cols))
	var p_arr: Array[Vector4] = []
	p_arr.assign(params)
	p_arr.resize(32)
	extra.resize(32)
	material.set_shader_parameter("fall_params", p_arr)
	var sparams := PackedVector4Array()
	material.set_shader_parameter("fall_streams", FallFace.stream_texture(fo.faces, sparams))
	var s_arr: Array[Vector4] = []
	s_arr.assign(sparams)
	s_arr.resize(32)
	material.set_shader_parameter("fall_sparams", s_arr)
	material.set_shader_parameter("fall_extra", extra)
	add_child(RiverSpray.build(fo.ledges, fo.feet))
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

