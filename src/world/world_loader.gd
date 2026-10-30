class_name WorldLoader
extends Node3D
## Builds the generated world in one place, in a fixed order: loads its
## files (WorldData), puts its ground in use for every ground question
## (Terrain.use, a HeightmapSource) before any child is ready, lets its
## Terrain child build the land, then adds the rivers (RiverWater) and a
## ChunkStreamer with the spawners of everything placed in chunks (trees for
## now). A level holds one; find it with current().

static var _current: WorldLoader

var world: WorldData
var rivers: RiverWater
var streamer: ChunkStreamer


static func current() -> WorldLoader:
	return _current


func _enter_tree() -> void:
	_current = self
	world = WorldData.get_world()
	if world:
		Terrain.use(HeightmapSource.new(world))


func _exit_tree() -> void:
	if _current == self:
		_current = null


func _ready() -> void:
	if world == null:
		return
	var terrain := get_node_or_null(^"Terrain") as Terrain
	rivers = RiverWater.new()
	rivers.name = "Rivers"
	add_child(rivers)
	rivers.setup(world, terrain.ground_texture() if terrain else null)
	streamer = ChunkStreamer.new()
	streamer.name = "Streamer"
	streamer.world_size = world.size
	add_child(streamer)
	streamer.add_spawner(TreeSpawner.new(world))



## Get a place ready for someone to be put there: the ground's collider and
## the streamed content round it.
func prepare_at(at: Vector3) -> void:
	var terrain := get_node_or_null(^"Terrain") as Terrain
	if terrain:
		terrain.prepare_at(at)
	if streamer:
		streamer.prepare_at(at)
