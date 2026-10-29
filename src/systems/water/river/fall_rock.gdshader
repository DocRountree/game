shader_type spatial;
render_mode cull_disabled;

// The rock of the waterfalls' faces (RiverRibbons builds it under the water,
// FallFace shapes its ledges): coloured exactly as the terrain colours the
// ground there (the same masks, colours and mottling), so out at its sides,
// where it lies on the ground and slips under it, it can't be told from the
// walls; smoothly shaded; dark and glossy where water runs over it (COLOR.r),
// with a little moss on the dry ledges. It sinks with the planet's curve as
// the terrain does, so it stays under its water far off.

uniform sampler2D ground : filter_linear, repeat_disable;   // the terrain's masks: rock, sand, forest density, ambient occlusion
uniform float world_size = 20480.0;
uniform vec3 grass_color : source_color = vec3(0.30, 0.37, 0.16);
uniform vec3 dry_grass_color : source_color = vec3(0.52, 0.49, 0.28);
uniform vec3 forest_floor_color : source_color = vec3(0.17, 0.22, 0.11);
uniform vec3 rock_color : source_color = vec3(0.42, 0.40, 0.37);
uniform vec3 dark_rock_color : source_color = vec3(0.26, 0.25, 0.24);
uniform vec3 moss_color : source_color = vec3(0.22, 0.32, 0.12);
uniform float planet_radius = 6400000.0;

varying vec3 wpos;
varying float wet;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wpos = world;
	world.y -= dot(world.xz - CAMERA_POSITION_WORLD.xz, world.xz - CAMERA_POSITION_WORLD.xz) / (2.0 * planet_radius);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	wet = COLOR.r;
}

void fragment() {
	vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec2 wp = wpos.xz;
	// as terrain.gdshader colours the ground (grass, forest floor, rock on steep ground)
	vec4 gw = texture(ground, (wp + world_size * 0.5) / world_size);
	float patches = vnoise(wp / 180.0) * 0.6 + vnoise(wp / 45.0) * 0.4;
	float dry = clamp(patches * 0.9 - 0.15 + smoothstep(150.0, 600.0, wpos.y) * 0.6, 0.0, 1.0);
	vec3 col = mix(grass_color, dry_grass_color, dry);
	col = mix(col, forest_floor_color, smoothstep(0.15, 0.7, gw.b));
	float rock = max(gw.r, smoothstep(0.62, 0.48, abs(nw.y)));
	vec3 stone = mix(dark_rock_color, rock_color, vnoise(wp / 9.0) * 0.6 + vnoise(wp / 60.0) * 0.4);
	col = mix(col, stone, rock);
	col *= 0.88 + 0.24 * (vnoise(wp * 0.7) * 0.5 + vnoise(wp * 3.1) * 0.5);
	float far = 1.0 - exp(-length(wpos - CAMERA_POSITION_WORLD) / 4500.0);
	col = mix(col, vec3(dot(col, vec3(0.3, 0.59, 0.11))) * vec3(0.6, 0.8, 1.25), far * 0.75);
	// on the face: wet rock, and moss on the dry ledges
	float moss = smoothstep(0.55, 0.85, nw.y) * (1.0 - wet) * smoothstep(0.45, 0.7, vnoise(wp * 1.3)) * rock;
	col = mix(col, moss_color, moss * 0.7);
	ALBEDO = col * mix(0.55, 1.0, gw.a) * mix(1.0, 0.5, wet);
	AO = gw.a;
	AO_LIGHT_AFFECT = 0.3;
	ROUGHNESS = mix(mix(0.95, 0.8, rock), 0.3, wet);
	SPECULAR = mix(0.25, 0.5, wet);
}
