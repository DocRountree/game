shader_type spatial;

// Terrain patches (CDLOD): every patch is the same 16 x 16 grid, placed and
// scaled per instance by Terrain's quadtree. A patch of LOD k has vertices
// 2.5 m * 2^k apart and reads mip k of the height map; near the far edge of
// its range each vertex slides onto the next coarser grid and blends to mip
// k + 1, so neighbouring patches meet without cracks (Strugar, "Continuous
// Distance-Dependent Level of Detail").
//
// Heights are 16-bit, in two R8 textures (high and low bytes), fetched texel
// by texel and filtered here. Normals come per pixel from the finest mip the
// pixel can show, so the near ground has every gully even between vertices.
//
// Looks: natural colours, for now without textures: grass, drier and paler
// with height and in patches, darker forest floor under the trees, rock on
// steep ground, sand on beaches and the seafloor; darkened in hollows by the
// baked ambient occlusion.

uniform sampler2D height_hi : filter_nearest, repeat_disable;
uniform sampler2D height_lo : filter_nearest, repeat_disable;
uniform sampler2D ground : filter_linear, repeat_disable;   // rock, sand, forest density, ambient occlusion
uniform sampler2D river_mask : filter_linear, repeat_disable;   // where rivers' water stands above the sea (WorldData.river_mask())
uniform float world_size = 10240.0;
uniform int texels = 4096;
uniform float h_min = -300.0;
uniform float h_scale = 0.0213623;
uniform int top_lod = 8;
uniform float grid_dim = 16.0;
// The main camera, also during the shadow pass (CAMERA_POSITION_WORLD is the
// light's camera there): patches must morph the same way in both.
uniform vec3 view_pos;
uniform float planet_radius = 6400000.0;

uniform vec3 grass_color : source_color = vec3(0.30, 0.37, 0.16);
uniform vec3 dry_grass_color : source_color = vec3(0.52, 0.49, 0.28);
uniform vec3 forest_floor_color : source_color = vec3(0.17, 0.22, 0.11);
uniform vec3 rock_color : source_color = vec3(0.42, 0.40, 0.37);
uniform vec3 dark_rock_color : source_color = vec3(0.26, 0.25, 0.24);
uniform vec3 sand_color : source_color = vec3(0.80, 0.74, 0.58);
uniform vec3 seabed_color : source_color = vec3(0.66, 0.62, 0.48);

varying vec3 world_pos;
varying flat int lod;
varying float morph;

float fetch(ivec2 c, int m) {
	int n = texels >> m;
	c = clamp(c, ivec2(0), ivec2(n - 1));
	float a = texelFetch(height_hi, c, m).r;
	float b = texelFetch(height_lo, c, m).r;
	return (round(a * 255.0) * 256.0 + round(b * 255.0)) * h_scale + h_min;
}

// Height at p from mip m, bilinear. Mip m's texel j is the mean of 2^m base
// samples, centred (2^m - 1) / 2 samples in from sample j * 2^m.
float height_m(vec2 p, int m) {
	float scale = exp2(float(m));
	vec2 g = ((p + world_size * 0.5) / (world_size / float(texels)) - (scale - 1.0) * 0.5) / scale;
	vec2 i = floor(g);
	vec2 f = g - i;
	ivec2 c = ivec2(i);
	float a = fetch(c, m);
	float b = fetch(c + ivec2(1, 0), m);
	float d = fetch(c + ivec2(0, 1), m);
	float e = fetch(c + ivec2(1, 1), m);
	return mix(mix(a, b, f.x), mix(d, e, f.x), f.y);
}

vec3 normal_m(vec2 p, int m) {
	float s = world_size / float(texels) * exp2(float(m));
	float hx = height_m(p + vec2(s, 0.0), m) - height_m(p - vec2(s, 0.0), m);
	float hz = height_m(p + vec2(0.0, s), m) - height_m(p - vec2(0.0, s), m);
	return normalize(vec3(-hx, 2.0 * s, -hz));
}

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;   // lod, morph start, morph end, patch size
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 gp = VERTEX.xz;
	vec2 wp = origin.xz + gp * cd.w;
	lod = int(cd.x + 0.5);
	float d = distance(wp, view_pos.xz);
	morph = lod < top_lod ? clamp((d - cd.y) / (cd.z - cd.y), 0.0, 1.0) : 0.0;
	gp -= fract(gp * grid_dim * 0.5) * 2.0 / grid_dim * morph;
	wp = origin.xz + gp * cd.w;
	float h = height_m(wp, lod);
	if (morph > 0.0)
		h = mix(h, height_m(wp, lod + 1), morph);
	// the planet curves away: far land sinks toward the true horizon
	float drop = dot(wp - view_pos.xz, wp - view_pos.xz) / (2.0 * planet_radius);
	VERTEX = vec3(gp.x * cd.w, h - origin.y - drop, gp.y * cd.w);
	NORMAL = normal_m(wp, lod);
	world_pos = vec3(wp.x, h, wp.y);
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
	// the finest mip this pixel can show
	float footprint = max(length(fwidth(wp)), 0.01);
	int m = clamp(int(floor(log2(footprint / (world_size / float(texels))))), 0, top_lod);
	vec3 n_world = normal_m(wp, m);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	vec4 gw = texture(ground, (wp + world_size * 0.5) / world_size);
	float h = world_pos.y;
	// grass: patches of greener and drier, drier and paler higher up
	float patches = vnoise(wp / 180.0) * 0.6 + vnoise(wp / 45.0) * 0.4;
	float dry = clamp(patches * 0.9 - 0.15 + smoothstep(150.0, 600.0, h) * 0.6, 0.0, 1.0);
	vec3 col = mix(grass_color, dry_grass_color, dry);
	col = mix(col, forest_floor_color, smoothstep(0.15, 0.7, gw.b));
	// rock where the ground is steep (the mask, and the pixel's own slope)
	float rock = max(gw.r, smoothstep(0.62, 0.48, n_world.y));
	vec3 stone = mix(dark_rock_color, rock_color, vnoise(wp / 9.0) * 0.6 + vnoise(wp / 60.0) * 0.4);
	col = mix(col, stone, rock);
	// beaches, and sand under the sea (under a river standing above the sea,
	// its bed's sand, and no sea-level damp line)
	float in_river = smoothstep(0.02, 0.1, texture(river_mask, (wp + world_size * 0.5) / world_size).r);
	col = mix(col, h < 0.0 && in_river < 0.5 ? seabed_color : sand_color, gw.g * (1.0 - rock * 0.7));
	// mottling, so no ground is one flat colour
	col *= 0.88 + 0.24 * (vnoise(wp * 0.7) * 0.5 + vnoise(wp * 3.1) * 0.5);
	// damp just above the waterline
	col *= mix(1.0, 0.72, (1.0 - smoothstep(0.0, 0.6, h)) * step(-0.5, h) * (1.0 - in_river));
	ALBEDO = col * mix(0.55, 1.0, gw.a);
	AO = gw.a;
	AO_LIGHT_AFFECT = 0.3;
	ROUGHNESS = mix(0.95, 0.8, rock);
	SPECULAR = 0.25;
}
