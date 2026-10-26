class_name RippleSim
extends Node
## Runs ripple_sim.glsl on the GPU and hands out the result twice: as a
## texture for the water shader (no CPU round trip) and as an asynchronous
## readback that physics samples about a frame late (no stall).
##
## Needs a RenderingDevice (Forward+ or Mobile renderer). Without one the
## ocean still works, just without ripples.

const N := 256
const CELL := 0.3            ## Grid covers N * CELL ~ 77 m.
const SPEED := 4.0           ## Wave speed (m/s); a faster hull leaves a V-shaped wake.
const DT := 1.0 / 120.0
const MAX_SOURCES := 64
const SOURCE_STRIDE := 32    ## Two vec4s per source.

var origin := Vector2.ZERO   ## World x, z of the grid's corner.
var enabled := false
var texture: Texture2D       ## Height in r, foam in g.

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _state: Array[RID] = []
var _sets: Array[RID] = []
var _disp: RID
var _source_buf: RID
var _cur := 0
var _acc := 0.0
var _pending_shift := Vector2i.ZERO
var _fresh := true
var _readback := PackedByteArray()
var _readback_origin := Vector2.ZERO


func _ready() -> void:
	var placeholder := Image.create(1, 1, false, Image.FORMAT_RGH)
	texture = ImageTexture.create_from_image(placeholder)
	if Engine.is_editor_hint():
		return
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_warning("RippleSim: no RenderingDevice (Compatibility renderer?); ripples disabled.")
		return
	RenderingServer.call_on_render_thread(_create)


func size() -> float:
	return N * CELL


## Scroll the grid in whole cells so it stays centred on pos.
func recenter(pos: Vector3) -> void:
	var cell := Vector2i(floori(pos.x / CELL) - N / 2, floori(pos.z / CELL) - N / 2)
	var old := Vector2i(roundi(origin.x / CELL), roundi(origin.y / CELL))
	var shift := cell - old
	if shift == Vector2i.ZERO:
		return
	if absi(shift.x) >= N or absi(shift.y) >= N:
		_fresh = true                        # teleported: start over
	_pending_shift += shift
	origin = Vector2(cell) * CELL


## Advance by one physics frame. sources: 8 floats per source (see ripple_sim.glsl).
func step(frame_dt: float, sources: PackedFloat32Array) -> void:
	if not enabled:
		return
	_acc += frame_dt
	var steps := 0
	while _acc >= DT and steps < 4:
		_acc -= DT
		steps += 1
	var data := sources.to_byte_array()
	var mode := 2 if _fresh else 0
	RenderingServer.call_on_render_thread(
		_dispatch.bind(data, sources.size() / 8, mode, _pending_shift, origin, steps, frame_dt))
	_pending_shift = Vector2i.ZERO
	_fresh = false


## Ripple height at a world point, from the latest readback. 0 outside the grid.
func sample(x: float, z: float) -> float:
	return _sample_channel(x, z, 0)


func sample_ring(x: float, z: float, radius: float) -> float:
	if radius <= 0.0:
		return sample(x, z)
	return 0.25 * (sample(x + radius, z) + sample(x - radius, z)
			+ sample(x, z + radius) + sample(x, z - radius))


func slope(x: float, z: float) -> Vector2:
	return Vector2(sample(x + CELL, z) - sample(x - CELL, z),
			sample(x, z + CELL) - sample(x, z - CELL)) / (2.0 * CELL)


func _sample_channel(x: float, z: float, channel: int) -> float:
	if _readback.size() != N * N * 8:
		return 0.0
	var fx := (x - _readback_origin.x) / CELL - 0.5
	var fz := (z - _readback_origin.y) / CELL - 0.5
	var i := floori(fx)
	var j := floori(fz)
	if i < 0 or j < 0 or i >= N - 1 or j >= N - 1:
		return 0.0
	var tx := fx - i
	var tz := fz - j
	var o := (j * N + i) * 8 + channel * 2   # RGBA16F: 8 bytes per texel
	var h00 := _readback.decode_half(o)
	var h10 := _readback.decode_half(o + 8)
	var h01 := _readback.decode_half(o + N * 8)
	var h11 := _readback.decode_half(o + N * 8 + 8)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


# --- render thread -----------------------------------------------------------

func _create() -> void:
	var shader_file: RDShaderFile = load("res://src/systems/ocean/ripple_sim.glsl")
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv())
	_pipeline = _rd.compute_pipeline_create(_shader)

	var fmt := RDTextureFormat.new()
	fmt.width = N
	fmt.height = N
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zeros := PackedByteArray()
	zeros.resize(N * N * 16)
	for i in 2:
		_state.append(_rd.texture_create(fmt, RDTextureView.new(), [zeros]))

	var disp_fmt := RDTextureFormat.new()
	disp_fmt.width = N
	disp_fmt.height = N
	disp_fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	disp_fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	var disp_zeros := PackedByteArray()
	disp_zeros.resize(N * N * 8)
	_disp = _rd.texture_create(disp_fmt, RDTextureView.new(), [disp_zeros])

	var buf_zeros := PackedByteArray()
	buf_zeros.resize(MAX_SOURCES * SOURCE_STRIDE)
	_source_buf = _rd.storage_buffer_create(buf_zeros.size(), buf_zeros)

	for i in 2:   # set i reads state i, writes state 1 - i
		_sets.append(_rd.uniform_set_create([
			_image_uniform(0, _state[i]), _image_uniform(1, _state[1 - i]),
			_buffer_uniform(2, _source_buf), _image_uniform(3, _disp)], _shader, 0))

	var tex := Texture2DRD.new()
	tex.texture_rd_rid = _disp
	texture = tex
	enabled = true


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


func _dispatch(data: PackedByteArray, count: int, mode: int, shift: Vector2i, at: Vector2,
		steps: int, frame_dt: float) -> void:
	if data.size() > 0:
		_rd.buffer_update(_source_buf, 0, data.size(), data)
	_pass(mode, count, shift, at, frame_dt)
	for s in steps:
		_pass(1, count, Vector2i.ZERO, at, frame_dt)
	_rd.texture_get_data_async(_disp, 0, _on_readback.bind(at))


func _pass(mode: int, count: int, shift: Vector2i, at: Vector2, frame_dt: float) -> void:
	var pc := PackedByteArray()
	pc.resize(48)
	pc.encode_float(0, at.x)
	pc.encode_float(4, at.y)
	pc.encode_s32(8, shift.x)
	pc.encode_s32(12, shift.y)
	pc.encode_float(16, CELL)
	pc.encode_float(20, DT)
	pc.encode_float(24, pow(SPEED * DT / CELL, 2.0))
	pc.encode_float(28, frame_dt)
	pc.encode_s32(32, mode)
	pc.encode_s32(36, count)
	pc.encode_s32(40, N)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _sets[_cur], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, N / 8, N / 8, 1)
	_rd.compute_list_end()
	_cur = 1 - _cur


func _on_readback(data: PackedByteArray, at: Vector2) -> void:
	_readback = data
	_readback_origin = at


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd and enabled:
		(texture as Texture2DRD).texture_rd_rid = RID()   # detach from materials before freeing
		var rids: Array[RID] = []
		rids.append_array(_sets)   # uniform sets first: they depend on the rest
		rids.append_array(_state)
		rids.append_array([_disp, _source_buf, _pipeline, _shader])
		var rd := _rd
		RenderingServer.call_on_render_thread(func() -> void:
			for rid in rids:
				if rid.is_valid():
					rd.free_rid(rid))
