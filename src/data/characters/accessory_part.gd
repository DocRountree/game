@tool
class_name AccessoryPart
extends Resource
## One piece of an accessory (AccessoryDef): a mesh placed in the head's frame
## (metres, the head's centre the origin, -Z the face), coloured by the
## accessory's palette slot (or `slot` if set). `fit_hair` widens it to sit
## over the hair (a hat's crown, a headband): its x and z scale by how far
## the hair stands off the scalp.

@export var mesh: Mesh
@export var transform := Transform3D.IDENTITY
@export var slot := -1                  ## Palette slot (-1: the accessory's own).
@export var fit_hair := false
