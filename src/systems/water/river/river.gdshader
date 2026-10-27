shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

// River water, after P_Malin's "Where the River Goes" (Shadertoy XdG3zd):
// - ripple normals from four octaves of value noise with analytic derivatives,
//   each octave drifting with the current at a different rate and direction
//   (flow *= -0.75 per octave) and warped by its own gradient, so the surface
//   churns instead of sliding like a texture;
// - two-phase flow mapping: two copies offset half a cycle apart, crossfaded,
//   each cycle re-randomised so the reset never shows;
// - foam where fast water runs shallow, broken up by a second flowing noise;
// - clear, slightly brown water: the bed shows through, absorbed with depth.
// The constants are rescaled from the original's toy units to metres.
//
// Drawn on the terrain's own CDLOD patches (see terrain.gdshader): the water
// surface and current come from the river levels the terrain compute shader
// writes alongside the heights, from the same river data that carves the
// channels, so the water always sits exactly in its bed, at every distance.

uniform float time;
uniform vec3 sun_direction = vec3(0.0, 0.5, 0.8);
uniform vec3 sun_color = vec3(1.0);
uniform float ripple_scale = 1.6;     // ripples per metre (roughly)
uniform float cycle = 1.4;            // seconds per flow-map cycle
uniform vec3 extinction = vec3(1.1, 0.9, 1.3);    // per metre: greens and browns survive longest
uniform vec3 body_color = vec3(0.06, 0.1, 0.07);
uniform float tint = 0.3;                          // how much the water's own colour shows even when shallow
uniform float sky_reflect = 0.25;                  // extra sky sheen on top of the Fresnel reflection
uniform float refraction = 0.04;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

uniform sampler2DArray levels : filter_linear, repeat_disable;
uniform sampler2DArray water_levels : filter_linear, repeat_disable;
uniform vec4 level_rects[12];
uniform int top_level = 10;
uniform float grid_dim = 16.0;
uniform float level_size = 256.0;
uniform vec3 view_pos;
uniform float planet_radius = 6400000.0;

varying vec2 flow;        // m/s
varying float valid;      // 1 on water
varying float centre_depth;
varying vec3 wpos;

float hash1(float p) {
	vec2 p2 = fract(vec2(p) * vec2(4.438975, 3.972973));
	p2 += dot(p2.yx, p2.xy + 19.19);
	return fract(p2.x * p2.y);
}

vec2 hash2(float p) {
	vec3 p3 = fract(vec3(p) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 19.19);
	return fract((p3.xx + p3.yz) * p3.zy);
}

// value noise and its derivatives: (d/dx, d/dy, value)
vec3 noise_dxy(vec2 o) {
	vec2 p = floor(o);
	vec2 f = fract(o);
	float n = p.x + p.y * 57.0;
	float a = hash1(n);
	float b = hash1(n + 1.0);
	float c = hash1(n + 57.0);
	float d = hash1(n + 58.0);
	vec2 f2 = f * f;
	vec2 t = 3.0 * f2 - 2.0 * f2 * f;
	vec2 dt = 6.0 * f - 6.0 * f2;
	float res = a + (b - a) * t.x + (c - a) * t.y + (a - b + d - c) * t.x * t.y;
	float dx = (b - a) * dt.x + (a - b + d - c) * dt.x * t.y;
	float dy = (c - a) * dt.y + (a - b + d - c) * t.x * dt.y;
	return vec3(dx, dy, res);
}

vec3 fbm_dxy(vec2 p, vec2 fl, float ps, float df) {
	vec3 f = vec3(0.0);
	float tot = 0.0;
	float a = 1.0;
	for (int i = 0; i < 4; i++) {
		p += fl;
		fl *= -0.75;   // every octave drifts differently: churn, not slide
		vec3 v = noise_dxy(p);
		f += v * a;
		p += v.xy * df;
		p *= 2.0;
		tot += a;
		a *= ps;
	}
	return f / tot;
}

vec4 water_normal(vec2 uv, vec2 offset, float mag, float foam, float filter_w) {
	float fade = 1.0 / (1.0 + filter_w * filter_w * 2000.0);
	vec3 dxy = fbm_dxy(uv, offset, 0.75 + foam * 0.25, 0.25 - foam * 1.5);
	fade *= max(0.25, 1.0 - foam * 5.0);   // foam flattens the surface
	vec3 n = mix(vec3(0.0, 1.0, 0.0), normalize(vec3(dxy.x, mag, dxy.y)), fade);
	return vec4(normalize(n), dxy.z * fade);
}

float foam_tex(vec2 uv, vec2 offset) {
	float f = fbm_dxy(uv * 1.5, offset * 2.5, 0.8, -0.5).z;
	f = max(0.0, (f - 0.2) / 0.2);
	return pow(0.5, f);
}

float view_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

vec2 level_uv(int k, vec2 p) {
	vec4 r = level_rects[k];
	return ((p - r.xy) / r.z + 0.5) / level_size;
}

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;   // lod, morph start, morph end, patch size
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 gp = VERTEX.xz;
	vec2 wp = origin.xz + gp * cd.w;
	int lod = int(cd.x + 0.5);
	float d = distance(wp, view_pos.xz);
	float morph = lod < top_level ? clamp((d - cd.y) / (cd.z - cd.y), 0.0, 1.0) : 0.0;
	gp -= fract(gp * grid_dim * 0.5) * 2.0 / grid_dim * morph;
	wp = origin.xz + gp * cd.w;
	vec4 w = textureLod(water_levels, vec3(level_uv(lod, wp), float(lod)), 0.0);
	float ground = textureLod(levels, vec3(level_uv(lod, wp), float(lod)), 0.0).r;
	if (morph > 0.0) {
		w = mix(w, textureLod(water_levels, vec3(level_uv(lod + 1, wp), float(lod + 1)), 0.0), morph);
		ground = mix(ground, textureLod(levels, vec3(level_uv(lod + 1, wp), float(lod + 1)), 0.0).r, morph);
	}
	valid = w.a;
	flow = w.yz;
	centre_depth = max(w.x - ground, 0.3);
	float y = w.a > 0.5 ? w.x : ground - 3.0;   // no water here: tuck the sheet under the ground
	float drop = dot(wp - view_pos.xz, wp - view_pos.xz) / (2.0 * planet_radius);   // the planet curves away
	VERTEX = vec3(gp.x * cd.w, y - origin.y - drop, gp.y * cd.w);
	NORMAL = vec3(0.0, 1.0, 0.0);
	wpos = vec3(wp.x, y, wp.y);
}

void fragment() {
	if (valid < 0.5)
		discard;
	vec2 fl = flow;
	vec2 rate = fl * 0.35;   // the original's units per second, for foam and ripple strength

	// how deep the water is here, from the depth buffer
	float surface_depth = -VERTEX.z;
	float thickness = max(view_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_depth, 0.0);
	float shallow = clamp(thickness / max(centre_depth * 1.5, 0.3), 0.02, 1.0);

	float foam = length(rate) * 0.5;
	foam += clamp(foam - 0.4, 0.0, 1.0);
	foam = 1.0 - pow(shallow, foam * 0.35);
	foam = clamp((foam - 0.2) * 1.5, 0.0, 1.0);
	foam = foam * foam * 0.5;

	vec2 uv = wpos.xz * ripple_scale;
	vec2 fw = max(abs(dFdx(uv)), abs(dFdy(uv)));
	float filter_w = max(fw.x, fw.y) * 0.05;
	float mag = 2.5 / (1.0 + dot(rate, rate) * 5.0);
	float tm = time / cycle;
	float t0 = fract(tm);
	float t1 = fract(tm + 0.5);
	vec2 uv0 = uv + hash2(floor(tm));
	vec2 uv1 = uv + hash2(floor(tm + 0.5));
	// the ripples drift at the real current
	vec2 off0 = -fl * (t0 - 0.5) * cycle * ripple_scale;
	vec2 off1 = -fl * (t1 - 0.5) * cycle * ripple_scale;
	vec4 s0 = water_normal(uv0, off0, mag, foam, filter_w);
	vec4 s1 = water_normal(uv1, off1, mag, foam, filter_w);
	float w = abs(t0 - 0.5) * 2.0;
	vec4 nh = mix(s0, s1, w);
	vec3 n_world = normalize(nh.xyz);
	float ft = mix(foam_tex(uv0, off0 * 0.25), foam_tex(uv1, off1 * 0.25), w);

	// no foam right at the edge, where the water is only a film
	foam *= smoothstep(0.03, 0.15, thickness);
	float foam_blend = 1.0 - pow(ft, foam * 5.0);

	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// light through the water: the bed, refracted and absorbed
	vec2 offset = n_world.xz * refraction * clamp(thickness, 0.0, 1.0);
	float behind = view_depth(SCREEN_UV + offset, INV_PROJECTION_MATRIX);
	if (behind < surface_depth)
		offset = vec2(0.0);
	else
		thickness = behind - surface_depth;
	vec3 bed = texture(screen_tex, SCREEN_UV + offset).rgb;
	vec3 transmit = exp2(-thickness * extinction * 1.4);
	float diffuse = max(dot(n_world, sun_direction), 0.0);
	vec3 lit = body_color * (0.3 + 0.9 * diffuse) * (0.15 + 0.85 * sun_color);
	vec3 below = bed * transmit + lit * (1.0 - transmit);
	below = mix(below, lit, tint);

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	fresnel = mix(fresnel, 1.0, sky_reflect);   // rivers read mostly by the sky they mirror
	float white = clamp(foam_blend, 0.0, 1.0);
	ALBEDO = vec3(0.85) * white;
	ROUGHNESS = mix(0.04, 0.8, white);
	SPECULAR = 0.5;
	EMISSION = below * (1.0 - fresnel) * (1.0 - white);
}
