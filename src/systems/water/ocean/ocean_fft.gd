class_name OceanFFT
extends Node
## The ocean's small waves as an FFT spectrum on the GPU (ocean_fft.glsl): a
## wind-wave spectrum evolved in time and inverse-FFT'd into surface slopes
## every frame, in three cascades of different tile sizes, each owning its own
## band of wavelengths. Natural chop: no sliding, no visible tiling, waves of
## each size at their true speed. The slopes go straight to the water shader as
## mipmapped textures (antialiased with distance); physics doesn't use them
## (the swell does the floating).
##
## Needs a RenderingDevice. Without one the textures stay flat.

const N := 256
const CASCADES := 3
const MIPS := 9                      ## 256 down to 1.

## Tile size (m) of each cascade; odd ratios so the repeats never line up.
@export var sizes := Vector3(97.0, 13.7, 2.31)
## Wavelength band edges (m): cascade 0 takes waves from longest_wave down to
## band_edges.x, cascade 1 down to band_edges.y, cascade 2 the rest.
@export var longest_wave := 20.0     ## Longer waves are the Gerstner swell's job.
@export var band_edges := Vector2(3.0, 0.3)
@export var wind_speed := 7.0        ## m/s; sets the spectrum's peak.
@export var wind_angle := 0.45       ## radians, same frame as OceanWave directions.
@export var amplitude := 0.0022      ## Phillips constant: overall roughness.
@export var spread := 2.0            ## Directional spreading (higher = more aligned with the wind).
@export var short_cutoff := 0.015    ## m: waves shorter than this fade out.
@export var spectrum_seed := 11

var enabled := false
var textures: Array[Texture2D] = []  ## Per cascade: x slope in r, z slope in g.

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _h0: RID
var _field: RID
var _tex: Array[RID] = []
var _views: Array = []               # [cascade][mip] storage views
var _sets: Array[RID] = []           # per mip level: dst = level, src = level - 1
var _built := false


func _ready() -> void:
	var flat := ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGH))
	for c in CASCADES:
		textures.append(flat)
	if Engine.is_editor_hint():
		return
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_warning("OceanFFT: no RenderingDevice (Compatibility renderer?); small waves disabled.")
		return
	RenderingServer.call_on_render_thread(_create)


## Advance the spectrum to time t (seconds) and rebuild the slope textures.
func update(t: float) -> void:
	if enabled:
		RenderingServer.call_on_render_thread(_dispatch.bind(t))


## Rebuild the random spectrum after changing its settings.
func rebuild() -> void:
	_built = false


# --- render thread -----------------------------------------------------------

func _create() -> void:
	var shader_file: RDShaderFile = load("res://src/systems/water/ocean/ocean_fft.glsl")
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("OceanFFT: " + spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_h0 = _rd.storage_buffer_create(CASCADES * N * N * 16)
	_field = _rd.storage_buffer_create(CASCADES * N * N * 8)

	var fmt := RDTextureFormat.new()
	fmt.width = N
	fmt.height = N
	fmt.mipmaps = MIPS
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	for c in CASCADES:
		var tex := _rd.texture_create(fmt, RDTextureView.new())
		_tex.append(tex)
		var views: Array[RID] = []
		for m in MIPS:
			views.append(_rd.texture_create_shared_from_slice(RDTextureView.new(), tex, 0, m, 1,
					RenderingDevice.TEXTURE_SLICE_2D))
		_views.append(views)
	for m in MIPS:
		var src := m - 1 if m > 0 else 1   # level 0 never reads; bind another level
		var uniforms := [_buffer_uniform(0, _h0), _buffer_uniform(1, _field)]
		for c in CASCADES:
			uniforms.append(_image_uniform(2 + c, _views[c][m]))
		for c in CASCADES:
			uniforms.append(_image_uniform(5 + c, _views[c][src]))
		_sets.append(_rd.uniform_set_create(uniforms, _shader, 0))

	textures.clear()
	for c in CASCADES:
		var t := Texture2DRD.new()
		t.texture_rd_rid = _tex[c]
		textures.append(t)
	enabled = true


func _dispatch(t: float) -> void:
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	if not _built:
		_built = true
		_pass(cl, 0, 0, t, N)
	_pass(cl, 1, 0, t, N)
	_pass(cl, 2, 0, t, N)
	_pass(cl, 3, 0, t, N)
	_pass(cl, 4, 0, t, N)
	for m in range(1, MIPS):
		_pass(cl, 5, m, t, N >> m)
	_rd.compute_list_end()


func _pass(cl: int, mode: int, level: int, t: float, rows: int) -> void:
	_rd.compute_list_bind_uniform_set(cl, _sets[level], 0)
	var pc := PackedByteArray()
	pc.resize(96)
	pc.encode_s32(0, mode)
	pc.encode_s32(4, level)
	pc.encode_s32(8, spectrum_seed)
	pc.encode_float(16, t)
	pc.encode_float(20, amplitude)
	pc.encode_float(24, cos(wind_angle))
	pc.encode_float(28, sin(wind_angle))
	pc.encode_float(32, wind_speed)
	pc.encode_float(36, spread)
	pc.encode_float(40, short_cutoff)
	var k_edges := [TAU / longest_wave, TAU / band_edges.x, TAU / band_edges.y, 1e9]
	for c in CASCADES:
		pc.encode_float(48 + c * 4, sizes[c])
		pc.encode_float(64 + c * 4, k_edges[c])
		pc.encode_float(80 + c * 4, k_edges[c + 1])
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, 1, rows, CASCADES)
	_rd.compute_list_add_barrier(cl)


func _image_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd and enabled:
		for t in textures:
			(t as Texture2DRD).texture_rd_rid = RID()   # detach from materials before freeing
		var rids: Array[RID] = []
		rids.append_array(_sets)   # uniform sets first: they depend on the rest
		for views: Array in _views:
			for v: RID in views:
				rids.append(v)
		rids.append_array(_tex)
		rids.append_array([_h0, _field, _pipeline, _shader])
		var rd := _rd
		RenderingServer.call_on_render_thread(func() -> void:
			for rid in rids:
				if rid.is_valid():
					rd.free_rid(rid))
