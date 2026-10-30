@tool
class_name AccessoryDef
extends Resource
## Something worn on the head or neck: a hat (kind HAT, one at a time),
## another accessory (ACCESSORY: glasses, earrings, a scarf ...), or a hair
## style that gathers the hair (STYLE: a ponytail, a bun; HairBuilder reads
## `id`). Its parts are drawn in its palette slot, in the colour the player
## picks (or default_color). Found by ContentRegistry: add a .tres to
## src/data/characters/accessories/ and the picker offers it.

enum Kind { HAT, ACCESSORY, STYLE }

## The radius over the head a fitted part (fit_hair) is made for: a scalp
## with almost no hair (CharacterDress widens it for thicker hair).
const FIT_RADIUS := 0.1282

@export var id := &""
@export var display_name := ""
@export var kind := Kind.ACCESSORY
@export var slot := 10                  ## Palette slot (CharacterTraits.P_*).
@export var default_color := Color(0.5, 0.5, 0.5)
@export var min_hair := 0.0             ## Only drawn with hair at least this long (a ponytail's tie).
@export var parts: Array[AccessoryPart] = []
