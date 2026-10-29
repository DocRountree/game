shader_type spatial;
render_mode cull_disabled;

// The rock of the waterfalls' faces (RiverRibbons builds it under the water,
// FallFace shapes its ledges): the terrain's own stone colours, shaded
// faceted like the low-poly land round it, dark and glossy where water runs
// over it (COLOR.r), with a little moss on the dry ledges. It sinks with the
// planet's curve as the terrain does, so it stays under its water far off.

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
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(n, VIEW) < 0.0)
		n = -n;
	NORMAL = n;
	vec3 nw = (INV_VIEW_MATRIX * vec4(n, 0.0)).xyz;
	vec3 stone = mix(dark_rock_color, rock_color, vnoise(wpos.xz * 0.7 + wpos.y * 0.9) * 0.6 + vnoise(wpos.xy * 2.3) * 0.4);
	float moss = smoothstep(0.55, 0.85, nw.y) * (1.0 - wet) * smoothstep(0.45, 0.7, vnoise(wpos.xz * 1.3));
	vec3 col = mix(stone, moss_color, moss);
	ALBEDO = col * mix(1.0, 0.5, wet);
	ROUGHNESS = mix(0.9, 0.3, wet);
	SPECULAR = mix(0.3, 0.5, wet);
}
