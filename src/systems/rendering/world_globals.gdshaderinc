// What every world shader shares, set once a frame for all of them by
// ShaderGlobals (project-wide global uniforms, declared in project.godot):
// the game's clock, the main camera's position (also during shadow passes,
// when CAMERA_POSITION_WORLD is the light's), the sun, and the planet's radius.

global uniform float world_time;      // s since the world started
global uniform vec3 world_view_pos;   // the main camera
global uniform vec3 sun_direction;    // toward the sun (unit)
global uniform vec3 sun_color;        // its light (colour times energy)
global uniform float planet_radius;   // m

// How far the planet's curve drops a point at xz below the flat ground at
// the viewer (d^2 / 2R), so far land and water sink toward the true horizon.
float planet_drop(vec2 xz) {
	vec2 d = xz - world_view_pos.xz;
	return dot(d, d) / (2.0 * planet_radius);
}
