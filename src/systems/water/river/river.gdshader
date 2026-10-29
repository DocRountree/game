shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

// River water, drawn on ribbon meshes that follow each channel (RiverRibbons):
// UV.x runs across the river in half widths (0 mid-channel), UV.y downstream
// in metres. Vertex colour: current (r * 8 m/s), depth (g * 8 m), how much
// water there is (b) and the half width (a * 128 m). The mesh's normals carry
// the downstream direction. CUSTOM0: how far down a fall's sheet (m, -1 off
// it), the fall's height (m), and the distance below the last fall (m).
//
// The water is after P_Malin's "Adrift" (shadertoy.com/view/ldjfDD), without
// its foam:
//   - the surface normal comes from a flowing fractal of value noise with
//     analytic derivatives: each octave is carried downstream by the current,
//     the next the other way at three quarters of the speed, and each warped
//     a little up its own gradient, which makes the water's characteristic
//     boils and slicks; two phases of it, half a period apart, are
//     crossfaded so the flow never visibly resets; each octave is turned a
//     little from the last, so no grid shows;
//   - the current is fastest mid-channel and slows toward the banks, and the
//     surface is flatter where the water runs fast;
//   - light through the water dies away red and green last (brown-green
//     water), with sunlight scattered back out of it, and the surface's gloss
//     falls away with distance so far water doesn't sparkle.
// The bed shows through, fading with the depth of water over it, but never
// more than `bed_visibility` of it: the water keeps a body of its own however
// shallow it is, so it never seems to vanish at its edges. Where a river runs
// down to the sea its water turns into the sea's (the same colours and
// absorption) and it fades out into it (the ocean fades in, WorldData.river_mask()).
//
// Falls: the sheet leaves the lip smooth and glassy and speeds up as it
// drops (as falling water does), its streaks stretching as they go, with the
// water thicker and thinner in bands across it; below the lip it splits into
// strands down the rock (which shows between them), white where it tumbles
// over the little ledges in the face and churns at the foot; in the pool
// below, ripples run out from the foot and the surface is stirred up. Above
// a lip the water runs rough and streaked with white (the rapids, among their
// rocks). Round an island the current parts and closes again, with a ring of
// white at its shore and a ruffled wake behind it. The sun's highlight is
// capped (light()), so it never blooms into a blinding blob.

uniform float time;
uniform vec3 sun_direction = vec3(0.0, 0.4, 0.9);
uniform vec3 sun_color = vec3(1.0);
uniform vec3 view_pos;
uniform float planet_radius = 6400000.0;

uniform vec3 deep_color = vec3(0.02, 0.05, 0.035);
uniform vec3 scatter_color = vec3(0.05, 0.12, 0.075);
uniform float bed_visibility = 0.82;  // at most this much of the bed shows through
uniform vec3 bed_tint = vec3(0.86, 0.96, 0.9);
uniform float refraction = 0.03;
// the sea's water (as water.gdshader has it), which a river's turns into as
// it comes down to the sea, so the two meet without a seam
uniform vec3 sea_deep_color = vec3(0.004, 0.03, 0.06);
uniform vec3 sea_scatter_color = vec3(0.0, 0.13, 0.14);
uniform vec3 sea_absorption = vec3(0.45, 0.09, 0.06);   // per metre
uniform float noise_scale = 2.0;      // cycles per metre of the coarsest ripple octave
uniform float flow_period = 1.0;      // s: each flow phase lasts this long
uniform float sheet_streaks = 0.6;    // ripple strength on a fall's sheet
uniform float pool_ripples = 0.5;    // ripple strength in a plunge pool
uniform float foam_strength = 1.0;
uniform float glint_cap = 2.5;       // the sun's highlight on the water is never brighter than this
uniform int island_count = 0;
uniform vec4 islands[8];             // middle x, z; downstream x, z
uniform vec3 island_sizes[8];        // half length, half width (at its middle), top
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec2 rp;        // across (m), downstream (m)
varying float speed;
varying float depth;    // mid-channel (m)
varying float fill;
varying float hw;
varying vec3 down;      // world, downstream (sloping down over a fall)
varying vec3 wpos;      // the water surface, world (before the planet's curve)
varying float sheet;    // m down a fall's sheet (-1 off it)
varying float fall_h;   // that fall's height
varying float below;    // m below the last fall's foot
varying float to_fall;  // m above the next fall's lip

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wpos = world;
	// the planet curves away, as the terrain does
	world.y -= dot(world.xz - view_pos.xz, world.xz - view_pos.xz) / (2.0 * planet_radius);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	speed = COLOR.r * 8.0;
	depth = COLOR.g * 8.0;
	fill = COLOR.b;
	hw = COLOR.a * 128.0;
	rp = vec2(UV.x * hw, UV.y);
	down = normalize(NORMAL + vec3(0.0, 0.0, 1e-6));   // the mesh's normals carry the downstream direction
	NORMAL = vec3(0.0, 1.0, 0.0);
	sheet = CUSTOM0.x;
	fall_h = CUSTOM0.y;
	below = CUSTOM0.z;
	to_fall = CUSTOM0.w;
}

// --- Adrift's water ---------------------------------------------------------

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Value noise with its derivatives: (d/dx, d/dy, value).
vec3 smooth_noise_dxy(vec2 o) {
	vec2 p = floor(o);
	vec2 f = fract(o);
	float a = hash12(p);
	float b = hash12(p + vec2(1.0, 0.0));
	float c = hash12(p + vec2(0.0, 1.0));
	float d = hash12(p + vec2(1.0, 1.0));
	vec2 f2 = f * f;
	vec2 t = 3.0 * f2 - 2.0 * f2 * f;
	vec2 dt = 6.0 * f - 6.0 * f2;
	float res = a + (b - a) * t.x + (c - a) * t.y + (a - b + d - c) * t.x * t.y;
	float dx = (b - a) * dt.x + (a - b + d - c) * dt.x * t.y;
	float dy = (c - a) * dt.y + (a - b + d - c) * t.x * dt.y;
	return vec3(dx, dy, res);
}

const mat2 TURN = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));

// The flowing fractal: each octave carried by the flow, the next the other
// way at 3/4 of it, and warped up its own gradient (df). Each octave is
// turned from the last; the derivatives are turned back to the world's.
vec3 fbm_dxy(vec2 p, vec2 flow, float ps, float df) {
	vec3 f = vec3(0.0);
	float tot = 0.0;
	float a = 1.0;
	mat2 m = mat2(1.0);
	for (int i = 0; i < 4; i++) {
		p += flow;
		flow *= -0.75;
		vec3 v = smooth_noise_dxy(p);
		f += vec3(transpose(m) * v.xy, v.z) * a;
		p += v.xy * df;
		p = TURN * p * 2.0;
		flow = TURN * flow;
		m = TURN * m;
		tot += a;
		a *= ps;
	}
	return f / tot;
}

// The surface normal at p (m) for one phase, flattened where the pixel is too
// coarse to show the ripples.
vec3 water_normal(vec2 p, vec2 flow_offset, float mag, float filter_width) {
	float scale = 1.0 / (1.0 + filter_width * filter_width * 2000.0);
	vec3 dxy = fbm_dxy(p * noise_scale, flow_offset * noise_scale, 0.75, 0.25);
	return normalize(mix(vec3(0.0, 1.0, 0.0), normalize(vec3(dxy.x, mag, dxy.y)), scale));
}

// Two phases of the flowing surface, half a period apart and crossfaded. The
// pattern is looked up upstream of each point by the distance the water has
// come, so it moves downstream.
vec3 flowing_normal(vec2 p, vec2 flow, float rough) {
	float mag = 2.5 / (1.0 + dot(flow, flow) * 0.05) / rough;   // flatter where it runs fast
	vec2 fw = max(abs(dFdx(p)), abs(dFdy(p))) * noise_scale / 20.0;
	float filter_width = max(fw.x, fw.y);
	float t = time / flow_period;
	float t0 = fract(t);
	float t1 = fract(t + 0.5);
	vec3 n0 = water_normal(p, -flow * flow_period * (t0 - 0.5), mag, filter_width);
	vec3 n1 = water_normal(p + vec2(17.3, 5.1), -flow * flow_period * (t1 - 0.5), mag, filter_width);
	return normalize(mix(n0, n1, abs(t0 - 0.5) * 2.0));
}

// Light through the water: red and green get furthest (Adrift's extinction).
vec3 water_extinction(float dist) {
	return exp2(-dist * 0.14 * vec3(0.5, 0.6, 0.9));
}

// --- falls ------------------------------------------------------------------------

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

// Gradient noise: (value, d/dx, d/dy).
vec3 gnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = hash22(i), gb = hash22(i + vec2(1, 0)), gc = hash22(i + vec2(0, 1)), gd = hash22(i + vec2(1, 1));
	float va = dot(ga, f), vb = dot(gb, f - vec2(1, 0)), vc = dot(gc, f - vec2(0, 1)), vd = dot(gd, f - vec2(1, 1));
	float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
	vec2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
			+ du * (u.yx * (va - vb - vc + vd) + vec2(vb, vc) - va);
	return vec3(v, d);
}

// The sheet of a fall at `across` (m), `tau` s after leaving the lip, where
// it falls at `v` m/s: (thickness 0..1, slope across, slope down; per m).
// The pattern is fixed in the falling water, so it streams down, stretching
// as the water speeds up.
vec3 fall_sheet(float across, float tau, float v) {
	vec3 acc = vec3(0.0);
	float amp = 1.0;
	float fx = 1.1;    // cycles per metre across
	float ft = 2.2;    // cycles per second of fall
	for (int o = 0; o < 4; o++) {
		vec3 g = gnoise(vec2(across * fx, (tau - time) * ft) + float(o) * 17.3);
		acc += vec3(g.x, g.y * fx, g.z * ft / max(v, 0.5)) * amp;
		amp *= 0.5;
		fx *= 2.1;
		ft *= 1.9;
	}
	return vec3(clamp(acc.x * 0.9 + 0.5, 0.0, 1.0), acc.yz * 0.15);
}

// The nearest island to p: (distance from its shore in m, negative on it;
// along it, -1 at its head to 1 at its tail; across it, m; its half width
// there), and its outward direction there.
vec4 island_at(vec2 p, out vec2 outward) {
	vec4 best = vec4(1e5, 0.0, 0.0, 1.0);
	outward = vec2(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= island_count)
			break;
		vec2 c = islands[i].xy;
		vec2 d = islands[i].zw;
		vec2 side = vec2(-d.y, d.x);
		float half_len = island_sizes[i].x;
		vec2 r = p - c;
		float a = dot(r, d) / half_len;
		float b = dot(r, side);
		float w = island_sizes[i].y * clamp(1.15 - 0.45 * clamp(a, -1.0, 1.0), 0.0, 1.3);   // blunt head, tapering tail
		float e = length(vec2(a, b / max(w, 0.5)));
		float dist = (e - 1.0) * min(w, half_len);
		if (dist < best.x) {
			best = vec4(dist, a, b, w);
			outward = normalize(d * (a / half_len) + side * (b / max(w * w, 0.25)) + vec2(1e-6));
		}
	}
	return best;
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
	float across = abs(rp.x) / max(hw, 0.01);

	// level water: the current, fastest mid-channel, slowing toward the
	// banks; stirred up in a plunge pool, with ripples running out from the fall
	float pool = below < 999.0 ? exp(-below / (1.5 * hw + 6.0)) * clamp(fall_h / 8.0, 0.0, 1.0) : 0.0;
	float rapids = to_fall < 999.0 ? smoothstep(35.0, 3.0, to_fall) : 0.0;
	vec2 flow = normalize(dn.xz + vec2(1e-6)) * speed * (1.0 - 0.6 * min(across * across, 1.0));
	// round an island the current parts: it turns along the shore rather
	// than into it, closes again behind, and the water there is ruffled
	vec2 outward;
	vec4 isl = island_at(wpos.xz, outward);
	float near_isl = exp(-max(isl.x, 0.0) / max(0.8 * isl.w, 2.0));
	flow -= outward * min(dot(flow, outward), 0.0) * near_isl;
	float behind = max(isl.y - 1.0, 0.0) * (isl.w * 2.2);   // m past its tail
	float wake = isl.y > 1.0 ? exp(-abs(abs(isl.z) - behind * 0.3) / 2.0) * exp(-behind / 70.0) : 0.0;
	vec3 n_flat = flowing_normal(wpos.xz, flow, 1.0 + 1.5 * pool + 1.5 * rapids + 1.2 * near_isl + wake);
	float ring = sin(below * 1.7 - time * 5.0 + 2.5 * gnoise(rp * 0.12).x) * pool;
	vec2 dn_h = normalize(dn.xz + vec2(1e-6));
	n_flat = normalize(n_flat - vec3(dn_h.x, 0.0, dn_h.y) * ring * pool_ripples);

	// a fall's sheet: smooth over the lip, streaming and banded below it
	float d = max(sheet, 0.0);
	float v0 = max(speed, 1.0);
	float v = sqrt(v0 * v0 + 19.6 * d);
	float tau = (v - v0) / 9.8;
	vec3 fs = fall_sheet(rp.x, tau, v);
	float glassy = smoothstep(0.2, 1.8, d);
	// below the lip the sheet splits into strands down the rock, and tumbles
	// white over the little ledges in the face
	float split = smoothstep(0.5, 4.0, d) * falling;
	float strand_n = gnoise(vec2(rp.x * 0.32, 31.7)).x + 0.5 * gnoise(vec2(rp.x * 0.9, 7.1)).x;   // (straight down the face)
	float strands = smoothstep(-0.35, -0.05, strand_n + 0.15);   // (most of the face; each strand runs right down to the pool)
	float ledge = smoothstep(0.72, 1.0, fract(d / 4.0 + 0.2 * gnoise(vec2(rp.x * 0.15, 3.3)).x));
	// how much water a pixel spans (in 3D: a fall's sheet is upright)
	float px = max(length(dFdx(wpos)), length(dFdy(wpos)));
	vec2 sl = fs.yz * sheet_streaks * glassy / (1.0 + px * px * 4.0);   // (no sparkle far off)
	vec3 n_fall = normalize(normalize(cross(ax, dn)) - (ax * sl.x + dn * sl.y));
	vec3 n_world = normalize(mix(n_flat, n_fall, falling));
	// seen from behind (the back of a fall's sheet) or from below, it faces
	// the eye, rather than turning black
	vec3 n_geom = normalize(mix(vec3(0.0, 1.0, 0.0), cross(ax, dn), falling));
	vec3 to_eye = (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;
	if (dot(n_geom, to_eye) < 0.0)
		n_world = reflect(n_world, n_geom);   // (mirrored through the surface)
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// light coming up through the water: the bed, refracted, dying away with
	// the distance it travels (never more than bed_visibility of it), and
	// sunlight scattered back out of the water's body. The water's thickness
	// along the view comes from the depth texture; where there is none (with
	// MSAA there isn't), from the channel's own depth (its bed a parabola
	// across) and the viewing angle.
	vec3 view_world = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float surface_depth = -VERTEX.z;
	float thickness;
	vec2 offset;
	if (texture(depth_tex, SCREEN_UV).r > 0.0) {
		thickness = max(view_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_depth, 0.0);
		offset = n_world.xz * refraction * clamp(thickness * 0.5, 0.0, 1.0);
		float behind = view_depth(SCREEN_UV + offset, INV_PROJECTION_MATRIX);
		if (behind < surface_depth)
			offset = vec2(0.0);
		else
			thickness = behind - surface_depth;
	} else {
		thickness = depth * max(1.0 - across * across, 0.0) / max(abs(view_world.y), 0.1);
		offset = n_world.xz * refraction * clamp(thickness * 0.5, 0.0, 1.0);
	}
	vec3 background = min(texture(screen_tex, SCREEN_UV + offset).rgb, vec3(4.0));   // (not the sun's disc, seen through a sheet)
	vec3 transmit = water_extinction(thickness) * bed_visibility * (1.0 - smoothstep(0.0, 0.4, falling));   // (water pouring over a lip is its own body, not glass)
	if (dot(n_geom, to_eye) < 0.0)
		transmit = vec3(0.0);   // (seen from below or behind: its own body, not what lies beyond it)
	float sun_dot_v = dot(sun_direction, -view_world);
	float diffuse = max(dot(n_world, sun_direction), 0.0);
	vec3 body = (deep_color * (0.5 + 0.8 * diffuse) + scatter_color * 0.45 * (0.5 + 0.5 * diffuse) * (1.0 + 0.5 * sun_dot_v));
	// coming down to the sea (its last few metres of fall) it becomes sea water
	float sea = 1.0 - smoothstep(0.5, 3.5, wpos.y);
	transmit = mix(transmit, exp(-sea_absorption * thickness), sea);
	body = mix(body, sea_deep_color * (0.5 + 0.8 * diffuse) + sea_scatter_color * 0.04 * (0.5 + 0.5 * diffuse), sea);
	// the sheet is thin water, lit through: lighter, in bands where it's thinner
	vec3 sheet_body = (deep_color * 1.4 + scatter_color * (0.45 + 0.5 * max(sun_dot_v, 0.0))) * mix(0.65, 1.3, fs.x) * (0.45 + 0.4 * diffuse);
	body = mix(body, sheet_body, falling) * (0.12 + 0.88 * sun_color);
	vec3 refracted = background * transmit * mix(bed_tint, vec3(1.0), sea) + body * (1.0 - transmit);

	// white water: down a fall (more as it drops, banded at its ledges),
	// churning at its foot, streaked through the rapids above a lip, and in
	// a ring round an island's shore and along its wake
	float foam = falling * clamp(0.1 + 0.55 * smoothstep(1.0, 14.0, d) + 0.45 * ledge * glassy, 0.0, 0.9) * (0.4 + 0.6 * fs.x);
	float churn = gnoise(rp * 0.3 - vec2(0.0, time * 0.6)).x * 0.5 + 0.5;
	foam += exp(-below / (0.5 * hw + 4.0)) * clamp(fall_h / 6.0, 0.0, 1.0) * churn * (1.0 - falling);
	float streak = gnoise(vec2(rp.x * 0.8, rp.y * 0.12 - time * max(speed, 1.0) * 0.12)).x;
	foam += rapids * smoothstep(0.15, 0.55, streak) * 0.55 * (1.0 - falling);
	float lace = gnoise(wpos.xz * 0.5 + vec2(time * 0.3, 0.0)).x * 0.5 + 0.5;
	foam += (exp(-max(isl.x, 0.0) / 2.5) * step(-0.5, isl.x) * (0.5 + 0.5 * clamp(-isl.y, 0.0, 1.0)) + 0.5 * wake) * lace * 0.5;
	foam = clamp(foam * foam_strength, 0.0, 1.0);

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	// gloss falls away where a pixel spans more water: the ripples too fine to
	// show still roughen it, so far water has a soft sheen, never a mirror
	// that turns the sun into one white-hot blob
	float gloss = 1.0 - clamp(0.05 + px * 0.08, 0.05, 0.45);
	ALBEDO = vec3(0.92) * foam;
	// a fall's sheet is broken water: never a mirror (it would flash the sun
	// from far off), rougher the further it is
	// (from the curve of its lip down, which would otherwise catch the sun
	// over a wide range of angles like a lens)
	float on_fall = max(falling, smoothstep(-0.9, 0.0, sheet));
	ROUGHNESS = mix(mix(clamp(1.0 - gloss, 0.02, 0.6), clamp(0.55 + px * 0.1, 0.55, 0.85), on_fall), 0.9, foam);
	SPECULAR = mix(0.5, 0.15, on_fall);
	EMISSION = refracted * (1.0 - fresnel) * (1.0 - foam);
	// whole across the channel (the banks cut its edge); a soft fringe only
	// at the ribbon's very edge (ragged down a fall's sides), thinning in at a
	// river's head, and fading out where it comes down to the sea
	float edge = mix(1.25, 0.95 + 0.12 * fs.x, falling);
	ALPHA = (1.0 - smoothstep(edge, edge + 0.25, across)) * smoothstep(0.0, 0.25, fill)
			* smoothstep(0.15, 1.2, wpos.y);   // (by then it's sea water, as the sea is: a long, gentle crossfade)
	// the strands of a fall, the rock between them showing; and the very edge
	// of the water fading in over its first 30 cm, so the shore is soft
	ALPHA *= mix(1.0, max(strands, foam * 0.5), split);
	ALPHA *= mix(smoothstep(0.0, 0.3, thickness * max(abs(view_world.y), 0.05)), 1.0, on_fall);
}

// The sun (and moon) on the water: a GGX highlight, capped, so a calm reach
// turned to the sun shines rather than blooms; foam lit as a rough white.
void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR / PI;
	vec3 h = normalize(VIEW + LIGHT);
	float ndh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float ndv = clamp(dot(NORMAL, VIEW), 1e-3, 1.0);
	float a = max(ROUGHNESS * ROUGHNESS, 0.002);
	float a2 = a * a;
	float dd = ndh * ndh * (a2 - 1.0) + 1.0;
	float dist = a2 / (PI * dd * dd);
	float fr = 0.02 + 0.98 * pow(1.0 - clamp(dot(VIEW, h), 0.0, 1.0), 5.0);
	float k = a * 0.5;
	float vis = 0.25 / ((ndl * (1.0 - k) + k) * (ndv * (1.0 - k) + k));
	SPECULAR_LIGHT += min(dist * fr * vis * ndl, glint_cap) * ATTENUATION * LIGHT_COLOR / PI;
}
