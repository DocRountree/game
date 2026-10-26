extends Node
## Signal bus for things that happen in the world and that systems with no
## reference to each other care about (the map, quests, audio, achievements).
## Emitters own the facts; listeners must not assume anyone else is listening.
## Only add a signal here when something real emits it.

## The clock rolled over midnight.
signal day_changed(day: int)
## The player's head went under (true) or came back up (false).
signal player_submerged_changed(submerged: bool)
## The player entered a body of water, or left all water (body is null).
signal player_water_changed(body: WaterBody)
## The player took (true) or gave up (false) a boat's helm.
signal boat_boarded(boat: Boat, boarded: bool)
## Newly explored map cells (WorldGrid coordinates).
signal area_explored(cells: Array[Vector2i])
## First- or third-person view.
signal view_mode_changed(first_person: bool)
## The player ran out of breath.
signal player_drowned
