class_name ChunkSpawner
extends RefCounted
## Fills square chunks of the world with one kind of content for a
## ChunkStreamer: trees now (TreeSpawner), plants, rocks, animals, items and
## structures later. build() makes a chunk's node (or null if there's nothing
## there); the streamer adds it while the chunk is within `view` m of the
## camera and frees it beyond. Seed any randomness from the chunk, so a chunk
## comes back the same.

var view := 3000.0           ## Chunks within this many m of the camera are built.


## The content of chunk (cx, cz), whose square is `rect` (world x, z), as a
## node placed at the chunk's centre (`centre`), or null.
func build(_cx: int, _cz: int, _rect: Rect2, _centre: Vector3) -> Node3D:
	return null
