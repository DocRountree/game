@tool
class_name QualitySettings
extends Resource
## Performance knobs, in one place. Systems read them through
## QualitySettings.current() when they build; the Settings autoload owns the
## live copy (and will later load/save it and expose presets).
##
## Planned: distance-based detail (LOD ranges for terrain chunks and props),
## custom culling distances for instanced fields, and dynamic resolution.

@export_group("Rendering")
@export_range(0.25, 1.0) var render_scale := 1.0      ## 3D resolution scale (1 = native).
@export var shadow_distance := 60.0                   ## Directional shadow range (m).

@export_group("Water")
@export var ocean_rings := 200                        ## Radial rings of the ocean mesh.
@export var ocean_segments := 256                     ## Vertices around each ring.

@export_group("Sky")
@export var cloud_count := 1600
@export var puffs_per_cloud := 40

@export_group("Distances")
@export var detail_distance := 150.0   ## Full-detail range for future props/creatures.
@export var far_distance := 1500.0     ## Beyond this, only impostors or nothing.

static var _default: QualitySettings


static func current() -> QualitySettings:
	if not Engine.is_editor_hint():
		var tree := Engine.get_main_loop() as SceneTree
		var settings := tree.root.get_node_or_null(^"Settings") if tree else null
		if settings and settings.quality:
			return settings.quality
	if _default == null:
		_default = QualitySettings.new()
	return _default
