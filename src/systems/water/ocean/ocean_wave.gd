@tool
class_name OceanWave
extends Resource
## One Gerstner wave component of the ocean swell.

@export var direction_degrees := 0.0  ## Travel direction in the XZ plane, 0 = +X.
@export var wavelength := 10.0        ## Crest-to-crest distance (m).
@export var amplitude := 0.1          ## Half the crest-to-trough height (m).
@export var phase := 0.0
