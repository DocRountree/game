shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

// River water, drawn on ribbon meshes that follow each channel (RiverRibbons):
// UV.x runs across the river in half widths (0 mid-channel), UV.y downstream
// in metres. Vertex colour: current (r * 8 m/s), depth (g * 8 m), how much the
// water has thinned in (b) and the half width (a * 64 m). The mesh's
// normals carry the downstream direction.
//
// The look is after the rivers of the big open-world westerns, without foam:
// clear water that shows the bed in the shallows and deepens to a dark
// green, a surface of fine ripples streaming downstream (drawn out into
// streaks along the flow, livelier where the water runs fast), the sky and
// sun reflected off it, and soft edges where it meets the bank. Every ripple
// moves only along the river's own direction, so the water follows every bend
// and always runs downhill. The current is the same at every depth.

uniform float time;
uniform vec3 sun_direction = vec3(0.0, 0.4, 0.9);
uniform vec3 sun_color = vec3(1.0);
uniform vec3 view_pos;
uniform float planet_radius = 6400000.0;

uniform vec3 deep_color = vec3(0.012, 0.045, 0.035);
uniform vec3 scatter_color = vec3(0.03, 0.11, 0.07);
uniform vec3 absorption = vec3(0.3, 0.075, 0.13);   // per metre: red first, then blue; the water greens with depth
uniform float refraction = 0.025;
uniform float ripple_strength = 0.5;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

// The terrain's height levels (Terrain), to fade the water's edge by its true
// depth, read at the same level of detail the terrain is drawn with there.
uniform sampler2DArray levels : filter_linear, repeat_disable;
uniform vec4 level_rects[12];
uniform int top_level = 10;
uniform float level_size = 256.0;
uniform float lod_range0 = 32.0;   // how far LOD 0 patches reach (doubling per LOD)
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec2 rp;        // across (m), downstream (m)
varying float speed;
varying float fill;
varying float hw;
varying vec2 down;      // world xz, downstream
varying vec3 wpos;      // the water surface, world (before the planet's curve)

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// the planet curves away, as the terrain does
	float drop = dot(world.xz - view_pos.xz, world.xz - view_pos.xz) / (2.0 * planet_radius);
	// at the mouth the river water slips just under the sea's surface
	float level = world.y;
	world.y -= 0.8 * (1.0 - smoothstep(0.3, 1.6, level));
	wpos = world;
	world.y -= drop;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	speed = COLOR.r * 8.0;
	fill = COLOR.b;
	hw = COLOR.a * 64.0;
	rp = vec2(UV.x * hw, UV.y);
	down = normalize(NORMAL.xz + 1e-6);   // the mesh's normals carry the downstream direction
	NORMAL = vec3(0.0, 1.0, 0.0);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

// gradient noise slope (d/dx, d/dy)
vec2 noise_slope(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = hash22(i), gb = hash22(i + vec2(1, 0)), gc = hash22(i + vec2(0, 1)), gd = hash22(i + vec2(1, 1));
	float va = dot(ga, f), vb = dot(gb, f - vec2(1, 0)), vc = dot(gc, f - vec2(0, 1)), vd = dot(gd, f - vec2(1, 1));
	return ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
			+ du * (u.yx * (va - vb - vc + vd) + vec2(vb, vc) - va);
}

// The surface's slope in river space (across, downstream). Each octave is
// carried downstream at about the current's speed (the small ones a little
// faster, as the surface runs ahead), and stretched along the flow into
// streaks, more the faster the water runs.
vec2 ripples(vec2 p, float v) {
	float stretch = 1.0 + 1.2 * clamp(v / 2.5, 0.0, 1.0);
	vec2 s = vec2(0.0);
	float amp = 1.0;
	float freq = 0.45;
	for (int o = 0; o < 5; o++) {
		vec2 q = vec2(p.x, (p.y - time * v * (0.9 + 0.08 * float(o))) / stretch) * freq + float(o) * 17.3;
		vec2 g = noise_slope(q);
		s += vec2(g.x, g.y / stretch) * freq * amp;
		amp *= 0.55;
		freq *= 2.1;
	}
	return s * 0.12;
}

float level_ground(int k, vec2 p) {
	vec4 r = level_rects[k];
	vec2 uv = ((p - r.xy) / r.z + 0.5) / level_size;
	return textureLod(levels, vec3(uv, float(k)), 0.0).r;
}

// The terrain's height here, as drawn: the LOD its patches use at this
// distance, blended toward the next as they morph (as in terrain.gdshader).
float ground_at(vec2 p) {
	float d = distance(p, view_pos.xz);
	int k = clamp(int(ceil(log2(max(d, 1.0) / lod_range0))), 0, top_level);
	float r = lod_range0 * exp2(float(k));
	float morph = k < top_level ? clamp((d - 0.87 * r) / (0.11 * r), 0.0, 1.0) : 0.0;
	float g = level_ground(k, p);
	return morph > 0.0 ? mix(g, level_ground(k + 1, p), morph) : g;
}

float view_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

void fragment() {
	// ripples in river space, turned into world space along the ribbon
	vec2 sl = ripples(rp, speed) * ripple_strength * (0.6 + 0.5 * clamp(speed / 2.0, 0.0, 1.5));
	// river space to world: UV.x grows toward the left of downstream
	vec2 dn = normalize(down);
	vec2 ax = vec2(-dn.y, dn.x);
	vec2 slope = ax * sl.x + dn * sl.y;
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
	vec3 body = (deep_color * (0.5 + 0.8 * diffuse) + scatter_color * 0.45 * (0.5 + 0.5 * diffuse)) * (0.12 + 0.88 * sun_color);
	vec3 refracted = background * transmit + body * (1.0 - transmit);

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.05;
	SPECULAR = 0.5;
	EMISSION = refracted * (1.0 - fresnel);
	// soft where it meets the ground, by its true depth over the terrain's
	// smooth heights (not where it happens to cut the terrain's triangles,
	// which steps from above), and thinning in at a river's head
	float depth_here = wpos.y - ground_at(wpos.xz);
	ALPHA = smoothstep(0.05, 0.9, depth_here) * smoothstep(0.0, 0.25, fill);
}
