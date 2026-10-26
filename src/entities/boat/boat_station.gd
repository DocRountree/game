@tool
class_name BoatStation
extends Marker3D
## A place on a boat where the player stands or sits to do something: steer
## (helm), fish (perch), reach the hold (cargo) or work (research bench). Its
## transform is where the player goes. Systems find stations with
## Boat.station(kind) instead of hard-coded node paths.

enum Kind { HELM, PERCH, CARGO, RESEARCH }

@export var kind := Kind.HELM
@export var display_name := ""
## Optional storage tied to this station (a research bench's sample rack).
@export var inventory: Inventory

var occupant: Node3D
