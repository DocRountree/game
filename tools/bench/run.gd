extends SceneTree
## Renders one benchmark view of the debug world and reports it.
##   godot --path . -s tools/bench/run.gd -- (env) VIEW=<name> OUT=<png> [HOUR=15] [MASK=1] [FRAMES=120]
## Prints one line "BENCH {json}": GPU and CPU ms per frame (averaged over FRAMES
## frames after warm-up), draw calls, triangles. MASK=1 draws the rivers' water
## as flat magenta (for the water masks the image metrics use). tools/bench/run.sh
## runs every view. Views are named for what they show; river views take the
## fall that drops most (FALL=n for the nth) as their subject.

var world: Node
var t := 0
var cam_set := false
var gpu_ms := 0.0
var cpu_ms := 0.0
var samples := 0
const WARM := 40


func _initialize() -> void:
	world = load("res://src/world/open_ocean/open_ocean.tscn").instantiate()
	root.add_child(world)


func _falls(W: WorldData) -> Array:
	var out := []
	for pair: Array in W.river_network.falls_by_height():
		var f: FallData = pair[1]
		out.append({"river": pair[0], "top": f.top, "foot": f.foot, "drop": f.drop, "hw": f.half_width})
	return out


func _view(W: WorldData, name: String) -> Array:
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var fi := int(OS.get_environment("FALL")) if OS.get_environment("FALL") != "" else 0
	var fs := _falls(W)
	var f: Dictionary = fs[mini(fi, fs.size() - 1)]
	var dir: Vector3 = f.foot - f.top
	dir.y = 0.0
	dir = dir.normalized()
	var side := Vector3(-dir.z, 0, dir.x)
	var mid: Vector3 = (f.top + f.foot) * 0.5
	var span: float = maxf(f.drop, 8.0)
	match name:
		"falls_front":
			from = f.foot + dir * span * 2.2 + side * span * 0.5 + Vector3(0, span * 0.5 + 3.0, 0)
			to = mid
		"falls_pool":
			from = f.foot + dir * (f.hw * 2.5 + 8.0) + side * f.hw * 0.6 + Vector3(0, 2.0, 0)
			to = mid
		"falls_lip":
			from = f.top - dir * 5.0 + side * 2.0 + Vector3(0, 6.0, 0)
			to = f.foot + dir * 10.0
		"falls_above":
			from = mid + Vector3(0, span * 2.2, 0) + dir * 2.0
			to = mid
		"falls_low":
			from = f.foot + dir * (f.hw * 1.5 + 4.0) + Vector3(0, 0.6, 0)
			to = f.top
		"upstream":
			from = f.top - dir * 30.0 + side * f.hw * 0.4
			from.y = Terrain.height_at(from.x, from.z) + 2.6
			to = f.foot + dir * 25.0
		"headwater", "rapids", "lowland", "island", "mouth":
			var r: RiverData = W.rivers[0] if name in ["lowland", "island", "mouth"] else f.river
			var pts: PackedVector3Array = r.points
			var k := pts.size() - 40
			match name:
				"headwater":
					k = 30
				"rapids":
					k = int(pts.size() * 0.3)
				"lowland":
					k = int(pts.size() * 0.75)
				"island":
					var i: Dictionary = W.islands[0]
					var c := Vector3(i.x, i.top, i.z)
					var d3 := Vector3(i.dx, 0, i.dz)
					from = c - d3 * i.length * 0.6 + Vector3(-d3.z, 0, d3.x) * i.length * 0.25 + Vector3(0, 45, 0)
					to = c + d3 * i.length * 0.1
					return [from, to]
			k = clampi(k, 12, pts.size() - 12)
			var q: Vector3 = pts[k]
			var d3: Vector3 = pts[k + 10] - pts[k - 10]
			d3.y = 0.0
			d3 = d3.normalized()
			from = q - d3 * 30.0 + Vector3(-d3.z, 0, d3.x) * 12.0
			from.y = maxf(Terrain.height_at(from.x, from.z), q.y) + 8.0
			to = q + d3 * 25.0
		"ocean":
			var c: Array = W.landmasses[0].center
			from = Vector3(W.spawn.x - 40.0, 6.0, W.spawn.y + 40.0)
			to = Vector3(W.spawn.x - 400.0, 0.0, W.spawn.y + 300.0)
	return [from, to]


func _process(_d: float) -> bool:
	t += 1
	if t == 2:
		root.get_viewport().msaa_3d = Viewport.MSAA_DISABLED
		var h := OS.get_environment("HOUR")
		world.get_node("Clock").time_of_day = float(h) if h != "" else 15.0
		world.get_node("HUD").visible = false
		RenderingServer.viewport_set_measure_render_time(root.get_viewport().get_viewport_rid(), true)
	if t >= 3:
		var cam: Camera3D = world.get_node("Camera")
		cam.process_mode = Node.PROCESS_MODE_DISABLED
		var p: Player = world.get_node("Player")
		p.flying = true
		p.velocity = Vector3.ZERO
		var v := _view(WorldData.get_world(), OS.get_environment("VIEW"))
		p.global_position = v[0] + Vector3(0, 50, 0)
		cam.global_position = v[0]
		cam.look_at(v[1])
	if t == 4 and OS.get_environment("MASK") != "":
		var water: MeshInstance3D = world.find_child("Water", true, false)
		var sh := Shader.new()
		sh.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment(){ ALBEDO = vec3(1.0, 0.0, 1.0); }"
		var m := ShaderMaterial.new()
		m.shader = sh
		water.material_override = m
	var frames := int(OS.get_environment("FRAMES")) if OS.get_environment("FRAMES") != "" else 120
	if t > WARM:
		var vp := root.get_viewport().get_viewport_rid()
		gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
		samples += 1
	if t == WARM + 1 and OS.get_environment("OUT") != "":
		root.get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT"))
	if t >= WARM + frames:
		var info := {
			"view": OS.get_environment("VIEW"),
			"gpu_ms": snappedf(gpu_ms / maxi(samples, 1), 0.001),
			"cpu_ms": snappedf(cpu_ms / maxi(samples, 1), 0.001),
			"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			"triangles": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			"adapter": RenderingServer.get_video_adapter_name(),
		}
		print("BENCH ", JSON.stringify(info))
		quit()
	return false
