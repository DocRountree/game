shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

// River water, drawn on ribbon meshes that follow each channel (RiverRibbons):
// UV.x runs across the river in half widths (0 mid-channel), UV.y downstream
// in metres. Vertex colour: current (r * 8 m/s), depth (g * 8 m), how much
// water there is (b) and the half width (a * 128 m). The mesh's normals carry
// the downstream direction.
//
// The look is after the rivers of the big open-world westerns, without foam:
// substantial green water (its body colour is always there: the bed only
// shows faintly, even in the shallows, and the water never thins away with
// its depth or the angle you see it from), the sky and sun reflected off a
// surface of fine ripples carried downstream. The ripples are laid out in
// world space and carried along the flow by two crossfaded phases (a flow
// map), so they follow every bend without stretching; over a waterfall they
// stream down the sheet instead.

uniform float time;
uniform vec3 sun_direction = vec3(0.0, 0.4, 0.9);
uniform vec3 sun_color = vec3(1.0);
uniform vec3 view_pos;
uniform float planet_radius = 6400000.0;

uniform vec3 deep_color = vec3(0.016, 0.055, 0.042);
uniform vec3 scatter_color = vec3(0.045, 0.13, 0.085);
uniform vec3 absorption = vec3(0.45, 0.12, 0.2);   // per metre: red first, then blue; the water greens with depth
uniform float clarity = 0.15;         // at most this much of the bed shows through
uniform float refraction = 0.02;
uniform float ripple_strength = 0.5;
uniform float flow_period = 1.6;      // s: each flow-map phase lasts this long
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec2 rp;        // across (m), downstream (m)
varying float speed;
varying float fill;
varying float hw;
varying vec3 down;      // world, downstream (sloping down over a fall)
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
	hw = COLOR.a * 128.0;
	rp = vec2(UV.x * hw, UV.y);
	down = normalize(NORMAL + vec3(0.0, 0.0, 1e-6));   // the mesh's normals carry the downstream direction
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

// The same pattern without any motion or stretching: isotropic ripples at a
// world point (slope d/dx, d/dz), each octave fading out once it is finer
// than the pixel can show (fp: the pixel's footprint, m), so far water
// doesn't glitter.
vec2 ripple_field(vec2 p, float fp) {
	vec2 s = vec2(0.0);
	float amp = 1.0;
	float freq = 0.45;
	const mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	mat2 m = mat2(1.0);   // each octave's frame, rotated so the octaves don't line up
	for (int o = 0; o < 5; o++) {
		float fade = clamp(1.0 / (freq * fp * 3.0) - 1.0, 0.0, 1.0);
		vec2 g = noise_slope((m * p) * freq + float(o) * 17.3);
		s += (transpose(m) * g) * freq * amp * fade;   // (back into world space)
		amp *= 0.55;
		freq *= 2.1;
		m = rot * m;
	}
	return s * 0.12;
}

// Ripples carried along the flow v (m/s): two copies of the field, each
// drifting downstream for one period and then starting over, crossfaded so
// neither restart shows.
vec2 flowing(vec2 p, vec2 v, float fp) {
	float t0 = fract(time / flow_period);
	float t1 = fract(time / flow_period + 0.5);
	vec2 a = ripple_field(p - v * t0 * flow_period, fp);
	vec2 b = ripple_field(p - v * t1 * flow_period + vec2(37.1, 11.7), fp);
	float wa = 1.0 - abs(2.0 * t0 - 1.0);
	return (a * wa + b * (1.0 - wa)) * 1.35;   // (crossfading halves the contrast at worst; give some back)
}

float view_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

void fragment() {
	// the surface's frame: downstream, and across (horizontal, to the left);
	// level water faces up, a fall faces downstream
	vec3 dn = normalize(down);
	vec3 ax = normalize(vec3(-dn.z, 0.0, dn.x) + vec3(1e-6, 0.0, 0.0));
	float falling = smoothstep(0.3, 0.7, -dn.y);
	float liveliness = ripple_strength * (0.6 + 0.5 * clamp(speed / 2.0, 0.0, 1.5));
	// level water: world-space ripples carried along the current
	vec2 flow = normalize(dn.xz + vec2(1e-6)) * speed;
	vec2 sf = flowing(wpos.xz, flow, max(length(fwidth(wpos.xz)), 0.001)) * liveliness;
	vec3 n_flat = normalize(vec3(-sf.x, 1.0, -sf.y));
	// a falling sheet: ripples streaming down it, in the sheet's own frame
	vec2 sl = ripples(rp, speed) * liveliness;
	vec3 n_fall = normalize(normalize(cross(ax, dn)) - (ax * sl.x + dn * sl.y));
	vec3 n_world = normalize(mix(n_flat, n_fall, falling));
	vec2 slope = mix(sf, (ax * sl.x + dn * sl.y).xz, falling);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// the water's body: its own green, with only a little of the bed showing
	// through where it is shallow and clear
	float surface_depth = -VERTEX.z;
	float thickness = max(view_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_depth, 0.0);
	vec2 offset = slope * refraction * clamp(thickness * 0.5, 0.0, 1.0);
	float behind = view_depth(SCREEN_UV + offset, INV_PROJECTION_MATRIX);
	if (behind < surface_depth)
		offset = vec2(0.0);
	else
		thickness = behind - surface_depth;
	vec3 background = texture(screen_tex, SCREEN_UV + offset).rgb;
	vec3 transmit = min(exp(-absorption * thickness), vec3(clarity));
	float diffuse = max(dot(n_world, sun_direction), 0.0);
	vec3 body = (deep_color * (0.5 + 0.8 * diffuse) + scatter_color * 0.45 * (0.5 + 0.5 * diffuse)) * (0.12 + 0.88 * sun_color);
	vec3 refracted = background * transmit + body * (1.0 - transmit);

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.05;
	SPECULAR = 0.5;
	EMISSION = refracted * (1.0 - fresnel);
	// whole across the channel (the banks cut its edge); a soft fringe only
	// at the ribbon's very edge, and thinning in at a river's head
	ALPHA = (1.0 - smoothstep(1.25, 1.5, abs(rp.x) / max(hw, 0.01))) * smoothstep(0.0, 0.25, fill);
}
