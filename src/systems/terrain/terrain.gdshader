shader_type spatial;
render_mode cull_disabled;

// Terrain patches (CDLOD): every patch is the same 16 x 16 grid, placed and
// scaled per instance by Terrain's quadtree. Heights come from the clipmap
// levels (terrain_levels.glsl): a patch of LOD k reads level k. Near the far
// edge of its range each vertex slides onto the next coarser grid and blends
// to level k + 1, so neighbouring patches of different LODs meet without
// cracks (Strugar, "Continuous Distance-Dependent Level of Detail").
//
// Looks: sandy seafloor and islands, rocky volcanoes, dirt continents; rock
// on steep slopes, damp ground at the water's edge, gravel in dry riverbeds.

uniform sampler2DArray levels : filter_linear, repeat_disable;
uniform vec4 level_rects[12];      // origin x, origin z, spacing, unused
uniform int top_level = 10;
uniform float grid_dim = 16.0;
uniform float level_size = 256.0;
uniform sampler2D ground : filter_linear, repeat_disable;   // sand, dirt, rock, lakebed weights
uniform float world_size = 61440.0;
uniform vec2 world_center = vec2(0.0);
// The main camera, also during the shadow pass (CAMERA_POSITION_WORLD is the
// light's camera there): patches must morph the same way in both, or shadows
// shift as you look around.
uniform vec3 view_pos;
uniform float planet_radius = 6400000.0;

uniform vec3 sand_color : source_color = vec3(0.78, 0.7, 0.52);
uniform vec3 dirt_color : source_color = vec3(0.4, 0.3, 0.21);
uniform vec3 rock_color : source_color = vec3(0.33, 0.31, 0.3);
uniform vec3 lakebed_color : source_color = vec3(0.5, 0.45, 0.37);
uniform vec3 gravel_color : source_color = vec3(0.38, 0.34, 0.29);

varying vec3 world_pos;
varying flat int lod;
varying float morph;

vec4 level_sample(int k, vec2 p) {
	vec4 r = level_rects[k];
	vec2 uv = ((p - r.xy) / r.z + 0.5) / level_size;
	return textureLod(levels, vec3(uv, float(k)), 0.0);
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
	vec4 s = level_sample(lod, wp);
	if (morph > 0.0)
		s = mix(s, level_sample(lod + 1, wp), morph);
	// the planet curves away: far land sinks toward the true horizon
	float drop = dot(wp - view_pos.xz, wp - view_pos.xz) / (2.0 * planet_radius);
	VERTEX = vec3(gp.x * cd.w, s.r - origin.y - drop, gp.y * cd.w);
	NORMAL = normalize(vec3(-s.g, 1.0, -s.b));
	world_pos = vec3(wp.x, s.r, wp.y);
}

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

void fragment() {
	vec2 wp = world_pos.xz;
	vec4 s = level_sample(lod, wp);
	if (morph > 0.0)
		s = mix(s, level_sample(lod + 1, wp), morph);
	vec3 n_world = normalize(vec3(-s.g, 1.0, -s.b));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	vec4 gw = texture(ground, (wp - world_center + world_size * 0.5) / world_size);
	gw /= max(gw.r + gw.g + gw.b + gw.a, 0.001);
	vec3 col = sand_color * gw.r + dirt_color * gw.g + rock_color * gw.b + lakebed_color * gw.a;
	// bare rock on steep slopes
	float steep = 1.0 - n_world.y;
	col = mix(col, rock_color, smoothstep(0.28, 0.45, steep) * (1.0 - gw.r * 0.5));
	// a little mottling so flat ground isn't flat colour
	float mottle = vnoise(wp * 0.37) * 0.6 + vnoise(wp * 2.3) * 0.4;
	col *= 0.86 + 0.28 * mottle;

	float rough = 0.92;
	float wetness = s.a;
	if (wetness < 0.0) {
		// dry riverbed: pale gravel
		col = mix(col, gravel_color * (0.85 + 0.3 * vnoise(wp * 4.0)), clamp(-wetness, 0.0, 1.0));
	} else {
		// damp band at the water's edge (sea, lakes, rivers)
		col *= mix(1.0, 0.62, wetness);
		rough = mix(rough, 0.35, wetness);
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = 0.3;
}
