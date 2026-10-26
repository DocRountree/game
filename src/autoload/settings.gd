extends Node
## Player-adjustable settings. For now: the quality knobs systems read when
## they build. Loading, saving and an options menu come later.

var quality := QualitySettings.new()


## Apply settings that live on the viewport rather than in a system.
func apply_to_viewport(viewport: Viewport) -> void:
	viewport.scaling_3d_scale = quality.render_scale
