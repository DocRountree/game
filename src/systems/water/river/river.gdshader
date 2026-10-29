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
// Falls are single steep drops down stepped rock, the water coming down in
// separate streams (FallFace, RiverRibbons): over each ledge a stream's water
// leaves it, glassy for a moment, then white and streaming in strands, and
// churns white where it lands on the ledge below; the rock between the
// streams is left bare (it is drawn by the ribbons too). Below a fall the water
// churns where each stream landed and the foam spreads and drifts away
// downstream, thinning out. Above a lip the water runs rough and flecked with
// white, and frets round the rock that stands up between the streams. Round an island the current parts along its shore, with a little
// foam at its head. Wakes and ripples from the player and the boat come from
// the ocean's ripple simulation (which drifts with the current in a river),
// churning white where they're steep. Highlights are capped and fall away
// with distance (light()), so no reach turns into a glinting blob.

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
uniform float foam_strength = 1.0;
uniform float glint_cap = 0.6;       // the sun's highlight on the water is never brighter than this
uniform int island_count = 0;
uniform vec4 islands[8];             // middle x, z; downstream x, z
uniform vec3 island_sizes[8];        // half length, half width (at its middle), top
uniform sampler2D ripple_tex : filter_linear, repeat_disable;  // r height (the ocean's ripple simulation)
// the falls' faces (FallFace.texture()): per row of a face, texel 0 its cells'
// offset, texel 1 + c cell c's water, top jitter and ledge
uniform sampler2D fall_cells : filter_nearest, repeat_disable;
uniform vec4 fall_params[32];   // per face: its first row, rows, row height, cell width
uniform vec2 fall_extra[32];    // per face: where its rows' first cells start (u), its cells a row
// and its streams (FallFace.stream_texture()): texel (s, row) stream s's
// middle and half width, a row every STREAM_STEP down the face
uniform sampler2D fall_streams : filter_nearest, repeat_disable;
uniform vec4 fall_sparams[32];  // per face: its first row, rows, row step, streams
uniform vec3 ripple_rect = vec3(0.0, 0.0, -1.0);                // origin x, origin z, size (m); none until set
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
varying float spec_cap; // (fragment to light: how bright the sun's highlight may get here)
varying flat int face;  // the fall it's on, just above or a little below (-1 away from them)
varying float fd;       // m down that fall's face (negative above its lip; its height and more below its foot)

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
	face = int(round(CUSTOM1.x));
	fd = CUSTOM1.y;
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

// A pattern carried downstream (along p.y) at v per second: two phases half
// a period apart, crossfaded, so however long the game runs it never shears
// where the current changes.
float drift_noise(vec2 p, float v, float period) {
	float t = time / period;
	float t0 = fract(t);
	float t1 = fract(t + 0.5);
	float a = gnoise(p - vec2(0.0, v * period * t0)).x;
	float b = gnoise(p + vec2(13.7, 4.1) - vec2(0.0, v * period * t1)).x;
	float w = abs(t0 - 0.5) * 2.0;
	return mix(a, b, w) / sqrt(w * w + (1.0 - w) * (1.0 - w));
}

// The sheet of a fall at `across` (m), `tau` s after leaving the lip, where
// it falls at `v` m/s: (thickness 0..1, slope across, slope down; per m).
// The pattern is fixed in the falling water, so it streams down, stretching
// as the water speeds up.
// Each octave fades out where it would be finer than about two pixels (px:
// metres a pixel spans), so far off the streaks don't shimmer.
vec3 fall_sheet(float across, float tau, float v, float px) {
	vec3 acc = vec3(0.0);
	float amp = 1.0;
	float fx = 1.1;    // cycles per metre across
	float ft = 2.2;    // cycles per second of fall
	for (int o = 0; o < 4; o++) {
		vec3 g = gnoise(vec2(across * fx, (tau - time) * ft) + float(o) * 17.3);
		g *= 1.0 - smoothstep(0.25, 0.5, px * fx);
		acc += vec3(g.x, g.y * fx, g.z * ft / max(v, 0.5)) * amp;
		amp *= 0.5;
		fx *= 2.1;
		ft *= 1.9;
	}
	return vec3(clamp(acc.x * 0.9 + 0.5, 0.0, 1.0), acc.yz * 0.15);
}

// A fall's face (FallFace, the same layout): the column of row r at u, and
// the top of cell (r, c).
int fall_col(int f, int r, float u) {
	float off = texelFetch(fall_cells, ivec2(0, int(fall_params[f].x) + r), 0).r;
	return clamp(int(floor((u - fall_extra[f].x - off) / fall_params[f].w)), 0, int(fall_extra[f].y) - 1);
}

float fall_top(int f, int r, int c) {
	return float(r) * fall_params[f].z + texelFetch(fall_cells, ivec2(1 + c, int(fall_params[f].x) + r), 0).g;
}

// The cell of face f at (u, d): (unused, how far down it 0..1, how far
// across it 0..1, its height m); side: unused here.
vec4 fall_cell(int f, float u, float d, out vec2 side) {
	vec4 P = fall_params[f];
	int rows = int(P.y);
	int r = clamp(int(floor(d / P.z)), 0, rows - 1);
	int c = fall_col(f, r, u);
	if (r > 0 && d < fall_top(f, r, c)) {
		r -= 1;
		c = fall_col(f, r, u);
	} else if (r < rows - 1) {
		int c2 = fall_col(f, r + 1, u);
		if (d >= fall_top(f, r + 1, c2)) {
			r += 1;
			c = c2;
		}
	}
	float t0 = fall_top(f, r, c);
	float t1 = r == rows - 1 ? fall_h : fall_top(f, r + 1, fall_col(f, r + 1, u));
	int row = int(P.x) + r;
	int cols = int(fall_extra[f].y);
	float off = texelFetch(fall_cells, ivec2(0, row), 0).r;
	float fc = (u - fall_extra[f].x - off) / P.w;
	side = vec2(c > 0 ? texelFetch(fall_cells, ivec2(c, row), 0).r : 0.0,
			c < cols - 1 ? texelFetch(fall_cells, ivec2(2 + c, row), 0).r : 0.0);
	return vec4(texelFetch(fall_cells, ivec2(1 + c, row), 0).r, clamp((d - t0) / max(t1 - t0, 0.01), 0.0, 1.0),
			fc - floor(fc), t1 - t0);
}

// How far inside the nearest of face f's streams (u, d) is (m; negative
// outside them all), as FallFace.inside() has it.
float fall_inside(int f, float u, float d) {
	vec4 S = fall_sparams[f];
	float fy = clamp(d / S.z, 0.0, S.y - 1.001);
	int j = int(floor(fy));
	float a = fy - float(j);
	int row = int(S.x) + j;
	float best = -1e3;
	for (int i = 0; i < 8; i++) {
		if (i >= int(S.w))
			break;
		vec2 p = mix(texelFetch(fall_streams, ivec2(i, row), 0).rg, texelFetch(fall_streams, ivec2(i, row + 1), 0).rg, a);
		if (p.y > 0.05)
			best = max(best, p.y - abs(u - p.x));
	}
	return best;
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
		float w = island_sizes[i].y * clamp(1.15 - 0.45 * clamp(a, -1.0, 1.0), 0.3, 1.3);   // blunt head, tapering tail
		float e = length(vec2(a, b / max(w, 0.5)));
		float dist = (e - 0.86) * min(w, half_len);   // (its shore 0.86 of the way out, as the generator raises it)
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
	// level water faces up, a riser faces downstream
	vec3 dn = normalize(down);
	vec3 ax = normalize(vec3(-dn.z, 0.0, dn.x) + vec3(1e-6, 0.0, 0.0));
	float falling = smoothstep(0.25, 0.6, -dn.y);
	float across = abs(rp.x) / max(hw, 0.01);
	// how much water a pixel spans (in 3D: a riser is steep)
	float px = max(length(dFdx(wpos)), length(dFdy(wpos)));

	// level water: the current, fastest mid-channel, slowing toward the
	// banks; stirred up in a plunge pool
	float fh = clamp(fall_h / 4.0, 0.0, 1.0);
	float pool = below < 999.0 ? exp(-below / (1.5 * hw + 6.0)) * smoothstep(2.0, 6.0, fall_h) : 0.0;
	float rapids = to_fall < 999.0 ? smoothstep(25.0, 2.0, to_fall) * (1.0 - falling) : 0.0;
	vec2 dir_h = normalize(dn.xz + vec2(1e-6));
	vec2 flow = dir_h * speed * (1.0 - 0.6 * min(across * across, 1.0));
	// round an island the current parts: it turns along the shore rather
	// than into it, and closes again behind
	vec2 outward;
	vec4 isl = island_at(wpos.xz, outward);
	float near_isl = exp(-max(isl.x, 0.0) / max(0.8 * isl.w, 2.0));
	flow -= outward * min(dot(flow, outward), 0.0) * near_isl;
	vec3 n_flat = flowing_normal(wpos.xz, flow, 1.0 + 1.5 * pool + 1.2 * rapids + 0.5 * near_isl);
	// wakes and ripples (the player swimming, the boat): their slope, from the
	// simulation's heights, fading out toward its edges
	float rip = 0.0;
	if (ripple_rect.z > 0.0) {
		vec2 ruv = (wpos.xz - ripple_rect.xy) / ripple_rect.z;
		float rf = smoothstep(0.0, 0.1, min(min(ruv.x, ruv.y), min(1.0 - ruv.x, 1.0 - ruv.y)));
		if (rf > 0.0) {
			float e = 1.0 / float(textureSize(ripple_tex, 0).x);
			vec2 rs = vec2(texture(ripple_tex, ruv + vec2(e, 0.0)).r - texture(ripple_tex, ruv - vec2(e, 0.0)).r,
					texture(ripple_tex, ruv + vec2(0.0, e)).r - texture(ripple_tex, ruv - vec2(0.0, e)).r)
					/ (2.0 * e * ripple_rect.z) * rf * (1.0 - falling);
			n_flat = normalize(n_flat - vec3(rs.x, 0.0, rs.y));
			rip = length(rs);
		}
	}

	// down a fall's face (FallFace): the water comes down in separate
	// streams, rock between them. Over each ledge (the cell of the rock it's
	// on) a stream's water leaves the ledge tau seconds before and falls at v,
	// its streaks fixed in it, so they stream down, stretching as it speeds
	// up; glassy for a moment at the ledge (the line where it breaks white
	// wavering across it), white and streaming below, churning white where it
	// lands on the ledge below; its sides ragged.
	float d = max(sheet, 0.0);
	bool on_face = face >= 0 && sheet >= 0.0;
	vec2 nb = vec2(1.0);
	vec4 cl = vec4(1.0, d / max(fall_h, 0.3), 0.5, max(fall_h, 0.3));
	if (on_face)
		cl = fall_cell(face, rp.x, d, nb);
	float dl = cl.y * cl.w;   // (m below this cell's ledge)
	float v0 = max(speed, 1.5);
	float v = sqrt(v0 * v0 + 19.6 * dl);
	float tau = (v - v0) / 9.8;
	vec3 fs = fall_sheet(rp.x, tau, v, px);
	float rf = cl.y;
	float wav = gnoise(vec2(rp.x * 0.7, 2.1 + 3.7 * floor(d))).x * 0.5 + 0.5;
	float lip = (1.0 - smoothstep(0.0, 0.2 + 0.35 * wav, dl)) * step(0.0, sheet);
	float rag = 0.1 + 0.3 * (gnoise(vec2(rp.x * 0.6, (tau - time) * 2.0)).x * 0.5 + 0.5);
	float cell_a = on_face ? smoothstep(-0.05, rag, fall_inside(face, rp.x, d)) : 1.0;
	// strands straight down each little fall, thin water between them
	float sn = gnoise(vec2(rp.x * 1.1, 31.7)).x + 0.5 * gnoise(vec2(rp.x * 2.7, 7.1 + tau)).x;
	float strands = mix(0.55, 1.0, smoothstep(-0.55, -0.25, sn + 0.25 * fs.x));
	strands = mix(strands, 0.85, smoothstep(0.08, 0.3, px));   // (too fine to show far off: no barcode)
	float ledge = smoothstep(0.75, 1.0, rf);   // (landing on the ledge below)
	vec2 sl = fs.yz * sheet_streaks * mix(2.0, 1.0, lip) / (1.0 + px * px * 4.0);   // (streaked, the light catching it unevenly; no sparkle far off)
	vec3 n_fall = normalize(normalize(cross(ax, dn)) - (ax * sl.x + dn * sl.y));
	vec3 n_world = normalize(mix(n_flat, n_fall, falling));
	// seen from behind or from below, it faces the eye, rather than turning black
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
	vec3 transmit = water_extinction(thickness) * bed_visibility * (1.0 - smoothstep(0.0, 0.4, falling));   // (water pouring down a riser is its own body, not glass)
	if (dot(n_geom, to_eye) < 0.0)
		transmit = vec3(0.0);   // (seen from below or behind: its own body, not what lies beyond it)
	float sun_dot_v = dot(sun_direction, -view_world);
	float diffuse = max(dot(n_world, sun_direction), 0.0);
	vec3 body = (deep_color * (0.5 + 0.8 * diffuse) + scatter_color * 0.45 * (0.5 + 0.5 * diffuse) * (1.0 + 0.5 * sun_dot_v));
	// coming down to the sea (its last few metres of fall) it becomes sea water
	float sea = 1.0 - smoothstep(0.5, 3.5, wpos.y);
	transmit = mix(transmit, exp(-sea_absorption * thickness), sea);
	body = mix(body, sea_deep_color * (0.5 + 0.8 * diffuse) + sea_scatter_color * 0.04 * (0.5 + 0.5 * diffuse), sea);
	// falling water is thin and full of air, lit through: lighter, in bands where it's thinner
	vec3 sheet_body = (deep_color * 1.6 + scatter_color * (0.6 + 0.5 * max(sun_dot_v, 0.0))) * mix(0.7, 1.35, fs.x) * (0.5 + 0.4 * diffuse);
	body = mix(body, sheet_body, falling) * (0.12 + 0.88 * sun_color);
	vec3 refracted = background * transmit * mix(bed_tint, vec3(1.0), sea) + body * (1.0 - transmit);

	// white water: down a riser (more as it drops, banded at its ledges);
	// churning at each riser's foot and drifting away downstream from it,
	// thinning out (the patterns move out from the foot with the water);
	// streaked through the rapids above a lip; a little round an island's
	// head and shore; and where a wake or a splash is steep
	float foam = falling * clamp(0.5 + 0.45 * smoothstep(0.0, 0.45, rf) + 0.35 * ledge, 0.0, 0.97)
			* (0.6 + 0.4 * fs.x) * (1.0 - 0.7 * lip);
	float churn_n = drift_noise(vec2(rp.x * 0.35, below * 0.45), 1.6 * 0.45, 2.0);
	// (below a fall, only where its streams landed, spreading out as it
	// drifts away from them)
	float landed = 1.0;
	if (face >= 0 && sheet < 0.0 && fd > 0.0)
		landed = smoothstep(-0.6 - 0.35 * below, 0.4, fall_inside(face, rp.x, fall_h - 0.01));
	float churn = exp(-below / (0.35 * hw + 2.5)) * fh * smoothstep(-0.15, 0.35, churn_n) * landed;
	float drift_v = max(speed, 0.9);
	float trail_n = drift_noise(vec2(rp.x * 0.25, below * 0.2), drift_v * 0.2, 4.0)
			+ 0.5 * drift_noise(vec2(rp.x * 0.7, below * 0.6) + 7.3, drift_v * 0.6, 3.0);   // (patches, a little drawn out downstream)
	float trail = exp(-below / (2.5 * hw + 12.0)) * fh * smoothstep(0.2, 0.8, trail_n) * 0.6
			* mix(landed, 1.0, smoothstep(0.0, 2.0 * hw + 20.0, below));
	foam += (churn + trail) * (1.0 - falling);
	// (right at its foot, white wherever it lands, steep or level)
	foam = max(foam, (1.0 - smoothstep(0.3, 2.5, below)) * step(sheet, -0.5) * fh * (0.7 + 0.25 * churn_n) * landed);
	float streak = drift_noise(vec2(rp.x * 0.6, rp.y * 0.3), max(speed, 1.0) * 0.3, 3.0);
	foam += rapids * smoothstep(0.3, 0.7, streak) * 0.3;
	// just above a lip, the water parting round the rock between the
	// streams, and gathering into them
	if (face >= 0 && sheet < 0.0 && fd < 0.0) {
		float ins = fall_inside(face, rp.x, 0.0);
		float near_lip = smoothstep(-2.5, -0.3, fd);
		foam += near_lip * (1.0 - smoothstep(0.0, 0.5 + 0.3 * churn_n, abs(ins))) * 0.55
				* smoothstep(-0.2, 0.4, drift_noise(vec2(rp.x * 1.5, fd * 1.5), max(speed, 1.0) * 1.5, 1.5));
	}
	// round an island: a thin, broken lace of foam along its waterline (where
	// the water over the ground is only a few centimetres deep), a little
	// more at its head where the current meets it, drifting with the current
	float lace = drift_noise(vec2(rp.x * 1.3, rp.y * 1.3), max(speed, 0.6) * 1.3, 3.0)
			+ 0.5 * drift_noise(vec2(rp.x * 3.1, rp.y * 3.1) + 5.1, max(speed, 0.6) * 3.1, 2.0);
	float shallow = 1.0 - smoothstep(0.03, 0.35 + 0.25 * clamp(-isl.y, 0.0, 1.0), thickness * max(abs(view_world.y), 0.05));
	foam += shallow * (1.0 - smoothstep(0.0, 6.0, isl.x)) * smoothstep(0.15, 0.6, lace)
			* (0.35 + 0.25 * clamp(-isl.y, 0.0, 1.0)) * (1.0 - falling);
	foam += smoothstep(0.2, 0.55, rip) * 0.6 * (gnoise(wpos.xz * 1.7).x * 0.5 + 0.6);
	foam = clamp(foam * foam_strength, 0.0, 1.0);

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	// gloss falls away where a pixel spans more water: the ripples too fine to
	// show still roughen it, so far water has a soft sheen, never a mirror
	// that turns the sun into one white-hot blob
	float gloss = 1.0 - clamp(0.07 + px * 0.3, 0.07, 0.6);
	// (white water streaked lighter and darker down a riser)
	ALBEDO = vec3(0.92) * foam * mix(1.0, 0.62 + 0.42 * fs.x, falling);
	// falling water is broken water: never a mirror (it would flash the sun
	// from far off), rougher the further it is
	// (and just below one, where it pours on over the rock at its foot)
	float on_fall = max(max(falling, smoothstep(-0.9, 0.0, sheet)), 1.0 - smoothstep(2.0, 3.0, below));
	ROUGHNESS = mix(mix(clamp(1.0 - gloss, 0.02, 0.6), clamp(0.6 + px * 0.1, 0.6, 0.9), on_fall), 0.9, foam);
	SPECULAR = mix(0.5, 0.1, max(on_fall, foam));
	spec_cap = glint_cap * mix(1.0, 0.2, max(on_fall, foam)) / (1.0 + px * 1.5);
	EMISSION = refracted * (1.0 - fresnel) * (1.0 - foam);
	// whole across the channel (the banks cut its edge); a soft fringe only
	// at the ribbon's very edge (ragged down a riser's sides), thinning in at a
	// river's head, and fading out where it comes down to the sea
	float edge = mix(1.25, 0.92 + 0.1 * fs.x, falling);
	ALPHA = (1.0 - smoothstep(edge, edge + 0.25, across)) * smoothstep(0.0, 0.25, fill)
			* smoothstep(0.15, 1.2, wpos.y);   // (by then it's sea water, as the sea is: a long, gentle crossfade)
	// the strands down a riser, the wet rock between them showing; and the
	// very edge of the water fading in over its first 30 cm, so the shore is soft
	ALPHA *= cell_a * mix(1.0, strands, falling);
	ALPHA *= mix(max(smoothstep(0.0, 0.3, thickness * max(abs(view_world.y), 0.05)), foam * 0.85), 1.0, on_fall);
}

// The sun (and moon) on the water: a GGX highlight, capped (lower far off and
// on white water), so a calm reach turned to the sun shines rather than
// blooms; foam lit as a rough white.
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
	SPECULAR_LIGHT += min(dist * fr * vis * ndl, spec_cap) * ATTENUATION * LIGHT_COLOR / PI;
}
