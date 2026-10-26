@tool
class_name BoatSpec
extends Resource
## How a kind of boat handles and what it carries. Boat reads this, so a new
## boat is a new spec plus a hull scene, not new code. The stations it has
## (helm, perch, research bench) are BoatStation markers in its scene.

@export var id := &""
@export var display_name := ""
@export var mass := 3000.0                ## kg
@export var length := 7.0                 ## m (also sets yaw inertia)
@export var beam := 2.6                   ## m

@export_group("Engine")
@export var thrust_forward := 7000.0      ## N at full throttle.
@export var thrust_reverse := 3000.0
@export var steer_rate := 0.12            ## Yaw acceleration per m/s of forward speed.
@export var yaw_damping := 1.5

@export_group("Hull")
@export var drag_forward_quadratic := 70.0
@export var drag_forward_linear := 100.0
@export var drag_side_quadratic := 1500.0  ## The keel: sideways drag.
@export var drag_side_linear := 800.0
@export var bow_lift := 6000.0            ## Pitch-up torque per m/s.
@export var turn_lean := 2000.0           ## Roll into turns.

@export_group("Cargo")
@export var cargo_slots := 6              ## Hold capacity (ItemStacks).
@export var max_cargo_kg := 400.0         ## For a future load/handling model.
