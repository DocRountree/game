shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

// Inland water (rivers, oxbow lakes and lakes), in the same look as the
// ocean (water.gdshader): the
// ocean's FFT small waves for the surface detail, light from the bed refracted
// and absorbed with depth, the same body colour. What makes
// a river: the small waves are carried downstream by the current (two
// copies, half a cycle apart, crossfaded so the drift never resets visibly),
// they get choppier as the water speeds up. Lakes are the
// same water with no current. At the very edge the water thins to nothing, so
// shorelines are soft.
//
// Drawn on the terrain's own CDLOD patches: the sheet height and current come
// from the river levels the terrain compute pass writes from the same channel
// data that carves the beds. The sheet runs a little past each bank and dives
// under the ground, so the shoreline is wherever the ground meets the water,
// smooth and exact, like the ocean's.

uniform float time;
uniform vec3 sun_direction = vec3(0.0, 0.4, 0.9);
uniform vec3 sun_color = vec3(1.0);
uniform float planet_radius = 6400000.0;

group_uniforms detail;
uniform sampler2D fft_0 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fft_1 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fft_2 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 fft_sizes = vec3(97.0, 13.7, 2.31);
uniform float detail_strength = 0.45;
uniform float cycle = 3.0;            // seconds per flow-map cycle

group_uniforms water;
uniform vec3 deep_color = vec3(0.01, 0.035, 0.04);
uniform vec3 scatter_color = vec3(0.02, 0.12, 0.1);
uniform vec3 absorption = vec3(0.4, 0.16, 0.14);   // per metre: a little greener and siltier than the sea
uniform float refraction = 0.03;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

group_uniforms patches;
uniform sampler2DArray levels : filter_linear, repeat_disable;
uniform sampler2DArray water_levels : filter_linear, repeat_disable;
uniform vec4 level_rects[12];
uniform int top_level = 10;
uniform float grid_dim = 16.0;
uniform float level_size = 256.0;
uniform vec3 view_pos;

varying vec2 flow;        // m/s
varying vec3 wpos;
varying flat int lod;
varying float morph;

vec2 level_uv(int k, vec2 p) {
	vec4 r = level_rects[k];
	return ((p - r.xy) / r.z + 0.5) / level_size;
}

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;   // lod, morph start, morph end, patch size
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 gp = VERTEX.xz;
	vec2 wp = origin.xz + gp * cd.w;
	lod = int(cd.x + 0.5);
	float d = distance(wp, view_pos.xz);
	morph = lod < top_level ? clamp((d - cd.y) / (cd.z - cd.y), 0.0, 1.0) : 0.0;
	gp -= fract(gp * grid_dim * 0.5) * 2.0 / grid_dim * morph;
	wp = origin.xz + gp * cd.w;
	vec4 w = textureLod(water_levels, vec3(level_uv(lod, wp), float(lod)), 0.0);
	if (morph > 0.0)
		w = mix(w, textureLod(water_levels, vec3(level_uv(lod + 1, wp), float(lod + 1)), 0.0), morph);
	flow = w.yz;
	float drop = dot(wp - view_pos.xz, wp - view_pos.xz) / (2.0 * planet_radius);   // the planet curves away
	VERTEX = vec3(gp.x * cd.w, w.x - origin.y - drop, gp.y * cd.w);
	NORMAL = vec3(0.0, 1.0, 0.0);
	wpos = vec3(wp.x, w.x, wp.y);
}

float view_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

vec2 fft_slope(vec2 p) {
	return texture(fft_0, p / fft_sizes.x).rg + texture(fft_1, p / fft_sizes.y).rg + texture(fft_2, p / fft_sizes.z).rg;
}

void fragment() {
	vec2 p = wpos.xz;
	float speed = length(flow);

	// small waves carried by the current: two phases, crossfaded
	float tm = time / cycle;
	float t0 = fract(tm);
	float t1 = fract(tm + 0.5);
	vec2 p0 = p - flow * t0 * cycle + vec2(17.3, 5.1) * floor(tm);
	vec2 p1 = p - flow * t1 * cycle + vec2(-9.7, 13.9) * floor(tm + 0.5);
	float w0 = 1.0 - abs(t0 - 0.5) * 2.0;
	vec2 slope = fft_slope(p0) * w0 + fft_slope(p1) * (1.0 - w0);
	slope *= detail_strength * (0.7 + 0.35 * speed);

	vec3 n_world = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// light coming up through the water: the bed, refracted, absorbed with depth
	float surface_depth = -VERTEX.z;
	float thickness = max(view_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_depth, 0.0);
	vec2 offset = slope * refraction * clamp(thickness * 0.5, 0.0, 1.0);
	float behind = view_depth(SCREEN_UV + offset, INV_PROJECTION_MATRIX);
	if (behind < surface_depth)
		offset = vec2(0.0);
	else
		thickness = behind - surface_depth;
	vec3 background = texture(screen_tex, SCREEN_UV + offset).rgb;
	vec3 transmit = exp(-absorption * thickness);
	float diffuse = max(dot(n_world, sun_direction), 0.0);
	vec3 body = (deep_color * (0.5 + 0.8 * diffuse) + scatter_color * 0.4 * (0.5 + 0.5 * diffuse))
			* (0.12 + 0.88 * sun_color);
	vec3 refracted = background * transmit + body * (1.0 - transmit);

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.04;
	SPECULAR = 0.5;
	EMISSION = refracted * (1.0 - fresnel);
	// The water's edge thins to nothing, by the true depth here: the water
	// level minus the ground height read (smoothly filtered) from the terrain
	// levels for this very pixel. So the visible shoreline is a smooth curve,
	// not the sawtooth where two triangle meshes cross.
	float ground = texture(levels, vec3(level_uv(lod, p), float(lod))).r;
	if (morph > 0.0)
		ground = mix(ground, texture(levels, vec3(level_uv(lod + 1, p), float(lod + 1))).r, morph);
	ALPHA = smoothstep(0.02, 0.3, wpos.y - ground);
}
