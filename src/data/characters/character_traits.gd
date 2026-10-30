@tool
class_name CharacterTraits
extends Resource
## How a person looks (and later, how they are): the player styles theirs in
## the character picker (C in the debug world), NPCs get theirs from
## generate(). apply_to() dresses a model (the player's CharacterRig) in them:
## scale, the colours (one palette uniform, no meshes rebuilt) and the hair,
## beard, hat and accessories (CharacterDress, rebuilt when their shape changes).

enum FacialHair { NONE, STUBBLE, MOUSTACHE, GOATEE, BEARD }

## Colour slots of the character's palette (character.gdshader).
const P_SKIN := 0
const P_SHIRT := 1
const P_SHORTS := 2
const P_HAIR := 3
const P_LEATHER := 4
const P_CANVAS := 5
const P_DARK := 6
const P_ROLL := 7
const P_STUBBLE := 8       ## Skin toward hair: a shaved head, stubble.
const P_HAT := 9
const P_GLASSES := 10
const P_EARRINGS := 11
const P_NECKLACE := 12
const P_SCARF := 13
const P_HEADBAND := 14
const P_TIE := 15
const P_MOUTH := 16
const PALETTE_SIZE := 20


@export var display_name := ""
@export_range(1.4, 2.1) var height := 1.75      ## m
@export_range(0.7, 1.4) var build := 1.0        ## Width scale.
@export var skin_color := Color(0.85, 0.6, 0.45)
@export var hair_color := Color(0.2, 0.13, 0.08)
@export var shirt_color := Color(0.75, 0.12, 0.08)
@export var shorts_color := Color(0.08, 0.15, 0.35)
@export_range(0.0, 1.0) var hair_length := 0.12  ## 0 shaved .. 1 to the waist.
@export_range(0.0, 1.0) var hair_curl := 0.2     ## 0 straight .. 1 coily.
@export var facial_hair := FacialHair.NONE
@export_range(0.0, 1.0) var facial_hair_length := 0.4
@export var hat := "wide_brim"            ## An AccessoryDef id of kind HAT, or "none".
@export var hat_color := Color(0.62, 0.53, 0.36)
@export var accessories: Array[String] = []   ## AccessoryDef ids (kinds ACCESSORY and STYLE).
@export var accessory_colors := {}   ## id -> Color (else the accessory's own)
## Free-form features for the generator to grow into.
@export var features := {}

## The top row of the picker: 12 skin tones, light to deep (warm, neutral and
## cool undertones mixed through them).
const SKIN_TONES: Array[Color] = [
	Color(0.98, 0.87, 0.78), Color(0.96, 0.80, 0.69), Color(0.93, 0.75, 0.60), Color(0.87, 0.67, 0.50),
	Color(0.80, 0.58, 0.42), Color(0.72, 0.50, 0.35), Color(0.62, 0.42, 0.29), Color(0.52, 0.34, 0.23),
	Color(0.43, 0.28, 0.19), Color(0.35, 0.23, 0.16), Color(0.27, 0.18, 0.13), Color(0.20, 0.13, 0.10)]
## The bottom row: simple colours, red to violet (hue rising).
const BRIGHT_COLORS: Array[Color] = [
	Color(0.900, 0.180, 0.180), Color(0.950, 0.546, 0.143), Color(0.950, 0.887, 0.190), Color(0.225, 0.750, 0.225), Color(0.212, 0.797, 0.850), Color(0.170, 0.340, 0.850), Color(0.613, 0.240, 0.800)]
const HAIR_COLORS: Array[Color] = [
	Color(0.05, 0.04, 0.04), Color(0.2, 0.13, 0.08), Color(0.35, 0.22, 0.12), Color(0.45, 0.3, 0.15),
	Color(0.8, 0.65, 0.4), Color(0.55, 0.2, 0.08), Color(0.7, 0.7, 0.7), Color(0.92, 0.92, 0.9)]
const ACCESSORY_COLORS: Array[Color] = [
	Color(0.08, 0.08, 0.08), Color(0.92, 0.92, 0.9), Color(0.9, 0.75, 0.3), Color(0.55, 0.55, 0.6),
	Color(0.7, 0.15, 0.12), Color(0.15, 0.3, 0.6), Color(0.2, 0.5, 0.25), Color(0.5, 0.25, 0.6)]


## Random but reproducible traits for an NPC.
static func generate(rng: RandomNumberGenerator) -> CharacterTraits:
	var t := CharacterTraits.new()
	t.height = clampf(rng.randfn(1.72, 0.09), 1.45, 2.05)
	t.build = clampf(rng.randfn(1.0, 0.1), 0.75, 1.3)
	t.skin_color = SKIN_TONES[rng.randi() % SKIN_TONES.size()]
	t.hair_color = HAIR_COLORS[rng.randi() % HAIR_COLORS.size()]
	t.shirt_color = Color.from_hsv(rng.randf(), rng.randf_range(0.3, 0.8), rng.randf_range(0.3, 0.9))
	t.shorts_color = Color.from_hsv(rng.randf(), rng.randf_range(0.2, 0.6), rng.randf_range(0.15, 0.5))
	t.hair_length = rng.randf() ** 1.5
	t.hair_curl = rng.randf()
	t.facial_hair = (rng.randi() % 5) as FacialHair
	t.facial_hair_length = rng.randf()
	var hats := defs(AccessoryDef.Kind.HAT)
	t.hat = "none" if rng.randf() < 1.0 / (hats.size() + 1) else String(hats[rng.randi() % hats.size()].id)
	t.hat_color = ACCESSORY_COLORS[rng.randi() % ACCESSORY_COLORS.size()]
	for d: AccessoryDef in defs(AccessoryDef.Kind.ACCESSORY):
		if rng.randf() < 0.2:
			t.accessories.append(String(d.id))
	var styles := defs(AccessoryDef.Kind.STYLE)
	if not styles.is_empty() and rng.randf() < 0.3:
		t.accessories.append(String(styles[rng.randi() % styles.size()].id))
	return t


## The accessory definitions of a kind (ContentRegistry: every AccessoryDef
## under src/data/), sorted by id.
static func defs(kind: AccessoryDef.Kind) -> Array:
	return ContentRegistry.all(&"AccessoryDef").filter(func(d: AccessoryDef) -> bool: return d.kind == kind)


## The hair style worn (a STYLE accessory's id: "ponytail", "bun"), or "".
func hair_style() -> String:
	for id in accessories:
		var d := ContentRegistry.by_id(&"AccessoryDef", StringName(id)) as AccessoryDef
		if d and d.kind == AccessoryDef.Kind.STYLE:
			return id
	return ""


func has_accessory(id: String) -> bool:
	return accessories.has(id)


func accessory_color(id: String) -> Color:
	var d := ContentRegistry.by_id(&"AccessoryDef", StringName(id)) as AccessoryDef
	return accessory_colors.get(id, d.default_color if d else Color.GRAY)


## The palette (linear colours by slot) the character shader reads.
func palette() -> Array[Vector3]:
	var cols: Array[Color] = []
	cols.resize(PALETTE_SIZE)
	cols.fill(Color.MAGENTA)
	cols[P_SKIN] = skin_color
	cols[P_SHIRT] = shirt_color
	cols[P_SHORTS] = shorts_color
	cols[P_HAIR] = hair_color
	cols[P_LEATHER] = Color(0.32, 0.2, 0.11)
	cols[P_CANVAS] = Color(0.62, 0.53, 0.36)
	cols[P_DARK] = Color(0.07, 0.06, 0.05)
	cols[P_ROLL] = Color(0.33, 0.38, 0.3)
	cols[P_STUBBLE] = skin_color.lerp(hair_color, 0.6)
	cols[P_HAT] = hat_color
	for d: AccessoryDef in ContentRegistry.all(&"AccessoryDef"):
		if d.kind != AccessoryDef.Kind.HAT:
			cols[d.slot] = accessory_color(String(d.id))
	cols[P_MOUTH] = skin_color.darkened(0.3).lerp(Color(0.6, 0.25, 0.22), 0.35)
	var out: Array[Vector3] = []
	for c in cols:
		var l := c.srgb_to_linear()
		out.append(Vector3(l.r, l.g, l.b))
	return out


## Scale a model, set its palette and dress its hair, beard, hat and
## accessories (when the model has them: CharacterRig leaves its material and
## its dress node as meta).
func apply_to(model: Node3D, reference_height := 1.7) -> void:
	var s := height / reference_height
	model.scale = Vector3(s * build, s, s * build)
	var mat := model.get_meta(&"character_material", null) as ShaderMaterial
	if mat:
		mat.set_shader_parameter("palette", palette())
	var dress := model.get_meta(&"dress", null) as MeshInstance3D
	if dress:
		dress.mesh = CharacterDress.build(self)
