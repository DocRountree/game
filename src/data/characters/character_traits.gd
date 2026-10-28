@tool
class_name CharacterTraits
extends Resource
## How a person looks (and later, how they are): the player styles theirs in a
## character creator, NPCs get theirs from generate(). apply_to() dresses a
## model (the player's CharacterRig) in them.

@export var display_name := ""
@export_range(1.4, 2.1) var height := 1.75      ## m
@export_range(0.7, 1.4) var build := 1.0        ## Width scale.
@export var skin_color := Color(0.85, 0.6, 0.45)
@export var hair_color := Color(0.2, 0.13, 0.08)
@export var shirt_color := Color(0.75, 0.12, 0.08)
@export var shorts_color := Color(0.08, 0.15, 0.35)
## Free-form features for the generator and creator to grow into
## (e.g. {"hair": "short", "beard": false, "personality": "curious"}).
@export var features := {}

const SKIN_TONES: Array[Color] = [Color(0.96, 0.8, 0.69), Color(0.87, 0.65, 0.5), Color(0.76, 0.53, 0.38),
		Color(0.6, 0.4, 0.27), Color(0.42, 0.27, 0.18), Color(0.28, 0.18, 0.12)]
const HAIR_COLORS: Array[Color] = [Color(0.05, 0.04, 0.04), Color(0.2, 0.13, 0.08), Color(0.45, 0.3, 0.15),
		Color(0.8, 0.65, 0.4), Color(0.55, 0.2, 0.08), Color(0.7, 0.7, 0.7)]


## Random but reproducible traits for an NPC.
static func generate(rng: RandomNumberGenerator) -> CharacterTraits:
	var t := CharacterTraits.new()
	t.height = clampf(rng.randfn(1.72, 0.09), 1.45, 2.05)
	t.build = clampf(rng.randfn(1.0, 0.1), 0.75, 1.3)
	t.skin_color = SKIN_TONES[rng.randi() % SKIN_TONES.size()]
	t.hair_color = HAIR_COLORS[rng.randi() % HAIR_COLORS.size()]
	t.shirt_color = Color.from_hsv(rng.randf(), rng.randf_range(0.3, 0.8), rng.randf_range(0.3, 0.9))
	t.shorts_color = Color.from_hsv(rng.randf(), rng.randf_range(0.2, 0.6), rng.randf_range(0.15, 0.5))
	return t


## Scale a model and recolour its parts tagged with a "tint" meta (skin,
## hair, shirt, shorts); other parts (hat, boots, pack) keep their own.
func apply_to(model: Node3D, reference_height := 1.7) -> void:
	var s := height / reference_height
	model.scale = Vector3(s * build, s, s * build)
	var colors := {"skin": skin_color, "hair": hair_color, "shirt": shirt_color, "shorts": shorts_color}
	var mats := {}
	for key: String in colors:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colors[key]
		mat.roughness = 0.85
		mats[key] = mat
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var tint := String(node.get_meta(&"tint", ""))
		if mats.has(tint):
			(node as MeshInstance3D).material_override = mats[tint]
