#[compute]
#version 450

// Terrain heights around the camera, as nested square levels (a geometry
// clipmap): level k has 256 x 256 texels spaced 0.5 * 2^k m. Each texel is the
// terrain function at that point:
//   baked height (smooth cubic B-spline), read from a pre-filtered mip of the
//     baked grid that matches the level's spacing, so coarse levels never
//     alias the 48 m grid (no shimmering or popping mountains as you move)
//   + fractal detail, finer octaves only where the level can resolve them,
//     damped on steep ground (derivative-damped fBm)
//   then, near rivers, replaced by the river's valley: one smooth field from
//   the exact distances to the baked river, oxbow and meander-scar segments
//   (found through a coarse tile index), so banks are smooth at any
//   resolution, channels merge at confluences and the water always lies in
//   its bed.
// Mode 0 writes height and water info; mode 1 fills in the gradient from the
// neighbouring texels.
//   r height (m)  g dh/dx  b dh/dz
//   a ground wetness: 0..1 = damp near water (sea, lakes, rivers), negative =
//     dry riverbed (how much, 0..-1); smooth either way, so it filters cleanly

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Base { float base_h[]; };   // mip chain, finest first
// Per segment, 4 vec4: (p0.xz, p1.xz), (surface 0, 1, half width 0, 1),
// (depth 0, 1, speed 0, 1; -1 = dry), (fill 0, 1, -, -)
layout(set = 0, binding = 1, std430) restrict readonly buffer Segments { vec4 seg[]; };
// tiles_per_side^2 + 1 offsets, then segment indices
layout(set = 0, binding = 2, std430) restrict readonly buffer Tiles { int tiles[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Ground { uint ground[]; };    // RGBA8 weights: sand, dirt, rock, lakebed
layout(set = 0, binding = 4, std430) restrict readonly buffer Lake { float lake_level[]; };
layout(set = 0, binding = 5, rgba32f) uniform restrict image2DArray levels;
// River water per texel: sheet height (tucked under the ground where there is
// no river), current x, z (m/s), unused.
layout(set = 0, binding = 6, rgba32f) uniform restrict writeonly image2DArray water_levels;
// Biome weights per baked cell, two RGBA8 each: (mesa, plains, forest,
// own-biome landmass), (coral reef, root maze, kelp forest, riparian wetlands).
layout(set = 0, binding = 7, std430) restrict readonly buffer Biomes { uint biome[]; };

layout(push_constant, std430) uniform Params {
	vec2 origin;        // world xz of texel (0, 0) in this level
	float spacing;      // m between texels
	float world_size;   // m
	int n;              // baked grid cells per side
	int layer;
	int mode;
	int seed;
	float cell;         // baked grid cell size (m)
	float detail;       // overall detail strength
	vec2 center;        // world xz of the baked grid's centre
	int tiles_per_side;
	float tile_size;
	float pad0;
	float pad1;
} pc;

const int SIZE = 256;
const int MIPS = 6;
const float TAU = 6.28318530718;
const float NO_WATER = -100000.0;

uint hash(uint x) {
	x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
	return x;
}

uint hash2(ivec2 c, uint salt) {
	return hash(uint(c.x) * 0x9e3779b9u ^ hash(uint(c.y) + salt * 0x85ebca6bu + uint(pc.seed)));
}

vec2 grad_at(ivec2 c, uint salt) {
	float a = float(hash2(c, salt) & 0xffffu) / 65536.0 * TAU;
	return vec2(cos(a), sin(a));
}

// Gradient noise with its derivatives (value, d/dx, d/dy), quintic fade.
vec3 noised(vec2 p, uint salt) {
	ivec2 i = ivec2(floor(p));
	vec2 f = p - floor(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = grad_at(i, salt);
	vec2 gb = grad_at(i + ivec2(1, 0), salt);
	vec2 gc = grad_at(i + ivec2(0, 1), salt);
	vec2 gd = grad_at(i + ivec2(1, 1), salt);
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
	vec2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
			+ du * (u.yx * (va - vb - vc + vd) + vec2(vb, vc) - va);
	return vec3(v, d);
}

int idx(ivec2 c) {
	c = clamp(c, ivec2(0), ivec2(pc.n - 1));
	return c.y * pc.n + c.x;
}

vec2 grid_of(vec2 p) {
	return (p - pc.center + 0.5 * pc.world_size) / pc.cell - 0.5;
}

vec4 bspline(float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return vec4(1.0 - 3.0 * t + 3.0 * t2 - t3, 4.0 - 6.0 * t2 + 3.0 * t3, 1.0 + 3.0 * t + 3.0 * t2 - 3.0 * t3, t3) / 6.0;
}

vec4 bspline_d(float t) {
	float t2 = t * t;
	return vec4(-3.0 + 6.0 * t - 3.0 * t2, -12.0 * t + 9.0 * t2, 3.0 + 6.0 * t - 9.0 * t2, 3.0 * t2) / 6.0;
}

// Baked height and its gradient (per metre) from mip m (cell * 2^m), cubic B-spline.
vec3 base_mip(vec2 p, int m) {
	int size = pc.n;
	int offset = 0;
	for (int i = 0; i < m; i++) {
		offset += size * size;
		size /= 2;
	}
	float cell = pc.cell * float(1 << m);
	vec2 g = (p - pc.center + 0.5 * pc.world_size) / cell - 0.5;
	vec2 i = floor(g);
	vec2 f = g - i;
	vec4 wx = bspline(f.x);
	vec4 wy = bspline(f.y);
	vec4 dx = bspline_d(f.x);
	vec4 dy = bspline_d(f.y);
	vec3 s = vec3(0.0);
	for (int y = 0; y < 4; y++) {
		for (int x = 0; x < 4; x++) {
			ivec2 c = clamp(ivec2(i) + ivec2(x - 1, y - 1), ivec2(0), ivec2(size - 1));
			float h = base_h[offset + c.y * size + c.x];
			s += h * vec3(wx[x] * wy[y], dx[x] * wy[y] / cell, wx[x] * dy[y] / cell);
		}
	}
	return s;
}

// The mip whose cells are about as big as this level's texels, blended.
vec3 base_height(vec2 p) {
	float lod = clamp(log2(max(pc.spacing * 1.5 / pc.cell, 1.0)), 0.0, float(MIPS - 1));
	int m0 = int(floor(lod));
	int m1 = min(m0 + 1, MIPS - 1);
	vec3 a = base_mip(p, m0);
	return m1 == m0 ? a : mix(a, base_mip(p, m1), fract(lod));
}

vec4 bilinear_ground(vec2 p) {
	vec2 g = grid_of(p);
	ivec2 i = ivec2(floor(g));
	vec2 f = g - floor(g);
	vec4 a = unpackUnorm4x8(ground[idx(i)]);
	vec4 b = unpackUnorm4x8(ground[idx(i + ivec2(1, 0))]);
	vec4 c = unpackUnorm4x8(ground[idx(i + ivec2(0, 1))]);
	vec4 d = unpackUnorm4x8(ground[idx(i + ivec2(1, 1))]);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// The rivers near p, as one smooth field (after Peytavie et al., "Procedural
// Riverscapes"): every river, oxbow and scar segment within reach adds to
//   level  the water level (or a dry bed's would-be level), blended over all
//          nearby segments, weighted steeply to the one p is most inside of;
//          where two reaches are about as near (the neck of a loop) it
//          crosses over smoothly, so the ground there never steps
//   shape  the ground relative to that level: each channel's bed below it,
//          banks rounding up onto the floodplain a little above it; the
//          lowest of all (channels merge at confluences)
//   valley how much of the ground is the river's (1 near, 0 far out)
// and for the water: the blended level drop of thin streams, the current
// (direction blended too, so it turns smoothly round bends), and how far
// inside the nearest wet channel p is. Ground and water both come from this,
// so the water always lies in its bed and the bed always falls downstream.
struct Rivers {
	float level;
	float shape;
	float valley;
	float r;          // nearest segment of any kind: distance / half width
	bool dry;         // ... and it is a dry bed or scar
	float wet_r;      // nearest wet channel
	float wet_hw;
	float thin;       // how far a thin stream sits below the level (m)
	vec2 current;     // m/s
};

const float VALLEY_IN = 1.3;    // the valley's own ground reaches this far (half widths)...
const float VALLEY_OUT = 9.0;   // ... and blends smoothly back into the land by here

Rivers rivers(vec2 p) {
	Rivers o;
	o.level = 0.0;
	o.shape = 1e9;
	o.valley = 0.0;
	o.r = 1e9;
	o.dry = false;
	o.wet_r = 1e9;
	o.wet_hw = 1.0;
	o.thin = 0.0;
	o.current = vec2(0.0);
	ivec2 tile = ivec2(floor((p - (pc.center - 0.5 * pc.world_size)) / pc.tile_size));
	if (any(lessThan(tile, ivec2(0))) || any(greaterThanEqual(tile, ivec2(pc.tiles_per_side))))
		return o;
	int t = tile.y * pc.tiles_per_side + tile.x;
	int base = pc.tiles_per_side * pc.tiles_per_side + 1;
	float ws = 0.0, wl = 0.0;            // level, over all segments
	float ww = 0.0, wt = 0.0, wh = 0.0;  // water, over wet segments
	vec2 wc = vec2(0.0);
	for (int k = tiles[t]; k < tiles[t + 1]; k++) {
		int i = tiles[base + k] * 4;
		vec4 a = seg[i];
		vec4 b = seg[i + 1];
		vec4 c = seg[i + 2];
		vec4 e = seg[i + 3];
		vec2 ab = a.zw - a.xy;
		float u = clamp(dot(p - a.xy, ab) / dot(ab, ab), 0.0, 1.0);
		float hw = mix(b.z, b.w, u);
		float r = distance(p, a.xy + ab * u) / hw;
		if (r > VALLEY_OUT)
			continue;
		float surface = mix(b.x, b.y, u);
		float speed = mix(c.z, c.w, u);
		bool wet = speed >= 0.0 && min(e.x, e.y) > 0.02;
		float depth = mix(c.x, c.y, u) * (wet ? 1.0 : 0.7);
		// bed: a parabola, its slope carried on up through the waterline,
		// easing over onto the floodplain, which rises very gently
		float bank = 0.5 + 0.15 * depth;
		float shape = r < 1.0 ? -depth * (1.0 - r * r)
				: bank * (1.0 - exp(-2.0 * depth * (r - 1.0) / bank)) + max(0.0, r - VALLEY_IN) * hw * 0.01;
		o.shape = min(o.shape, shape);
		o.valley = max(o.valley, 1.0 - smoothstep(VALLEY_IN, VALLEY_OUT, r));
		float w = exp(-4.0 * r);
		ws += w;
		wl += w * surface;
		if (r < o.r) {
			o.r = r;
			o.dry = !wet;
		}
		if (wet) {
			float fill = mix(e.x, e.y, u);
			float wv = exp(-6.0 * r);
			ww += wv;
			wt += wv * depth * (1.0 - fill);
			wh += wv * hw;
			// fastest mid-channel, slower toward the banks
			wc += wv * normalize(ab) * speed * (1.0 - 0.5 * min(r * r, 1.0));
			o.wet_r = min(o.wet_r, r / sqrt(max(fill, 0.05)));
		}
	}
	if (ws > 0.0)
		o.level = wl / ws;
	if (ww > 0.0) {
		o.thin = wt / ww;
		o.wet_hw = wh / ww;
		o.current = wc / ww;
	}
	return o;
}

// Smooth minimum: like min(a, b), rounded over a band k wide.
float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

// Biome weights, bilinear (WorldMaps.biome).
vec4 biome_bilinear(vec2 p, int which) {
	vec2 g = grid_of(p);
	ivec2 i = ivec2(floor(g));
	vec2 f = g - floor(g);
	vec4 a = unpackUnorm4x8(biome[idx(i) * 2 + which]);
	vec4 b = unpackUnorm4x8(biome[idx(i + ivec2(1, 0)) * 2 + which]);
	vec4 c = unpackUnorm4x8(biome[idx(i + ivec2(0, 1)) * 2 + which]);
	vec4 d = unpackUnorm4x8(biome[idx(i + ivec2(1, 1)) * 2 + which]);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Plain fractal noise, band-limited to what this level can show, about -1..1.
float fbm(vec2 p, float freq, int octaves) {
	float v = 0.0;
	float amp = 0.5;
	const mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int o = 0; o < octaves; o++) {
		float wl = 1.0 / freq;
		float fade = clamp((wl - 4.0 * pc.spacing) / (4.0 * pc.spacing), 0.0, 1.0);
		if (fade <= 0.0)
			break;
		v += noised(p * freq, uint(o + 40)).x * amp * fade;
		amp *= 0.5;
		freq *= 2.03;
		p = rot * p;
	}
	return v * 1.4;
}

// One tier of mesa caprock at level lvl: below it the ground is unchanged; a
// 12 m band under the rim stretches into a ~60 m cliff; above, the ground is
// pressed nearly flat (an eighth of its rise). Smooth and always rising.
float caprock(float h, float lvl) {
	const float BAND = 12.0;
	const float CLIFF = 60.0;
	float x = h - lvl;
	float over = 0.5 * (x + sqrt(x * x + 9.0));   // smooth max(x, 0)
	return h + CLIFF * smoothstep(-BAND, 0.0, x) - 0.875 * over;
}

// The erosion filter (after Clay John's "Eroded Terrain Noise" and Rune
// Skovbo Johansen's refinement of it): in each cell of a jittered grid a
// little wave runs straight down the slope; blended, they make gullies and
// spurs that follow the land downhill. Each finer octave runs down the slope
// the coarser ones made, so gullies branch like a real drainage network.
// Cheap (a 4 x 4 neighbourhood per octave) and the same at any resolution.
vec3 gully_cells(vec2 q, vec2 dir) {
	vec2 iq = floor(q);
	vec2 fq = q - iq;
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int j = -1; j <= 2; j++) {
		for (int i = -1; i <= 2; i++) {
			ivec2 c = ivec2(iq) + ivec2(i, j);
			uint hc = hash2(c, 91u);
			vec2 jit = vec2(float(hc & 0xffffu), float(hc >> 16)) / 65536.0;
			uint hv = hash2(c, 92u);
			float strength = 0.55 + 0.9 * float(hv & 0xffffu) / 65536.0;   // no two gullies alike
			float tight = 0.8 + 0.45 * float(hv >> 16) / 65536.0;
			vec2 r = fq - vec2(i, j) - jit;
			float w = exp(-1.6 * dot(r, r));
			float ph = dot(r, dir) * TAU * tight;
			acc += vec3(cos(ph), -sin(ph) * TAU * tight * dir) * w * strength;
			wsum += w;
		}
	}
	return acc / wsum;
}

float erosion(vec2 p, vec2 slope) {
	float h = 0.0;
	vec2 dh = vec2(0.0);
	float amp = 1.0;
	const float WL0 = 700.0;   // gully spacing of the first octave (m)
	float wl = WL0;
	// a gentle warp, so even a long even slope isn't combed straight
	p += vec2(noised(p / 2400.0, 71u).x, noised(p / 2400.0 + 19.0, 72u).x) * 450.0;
	vec2 down = slope / max(length(slope), 0.02);
	for (int o = 0; o < 6; o++) {
		float fade = clamp((wl - 4.0 * pc.spacing) / (4.0 * pc.spacing), 0.0, 1.0);
		if (fade <= 0.0)
			break;
		// down the land's slope, bent by the gullies made so far
		vec2 g = down + dh * WL0 * 0.3;
		vec2 dir = normalize(vec2(g.y, -g.x) + 1e-5);
		vec3 e = gully_cells(p / wl, dir);
		h += e.x * amp * fade;
		dh += e.yz / wl * amp * fade;
		// finer gullies cut the ridges more than the floors of bigger ones
		amp *= 0.5 * (0.6 + 0.4 * smoothstep(-0.6, 0.6, e.x));
		wl *= 0.5;
	}
	return h;
}

void main() {
	ivec2 t = ivec2(gl_GlobalInvocationID.xy);
	if (t.x >= SIZE || t.y >= SIZE)
		return;
	ivec3 at = ivec3(t, pc.layer);

	if (pc.mode == 1) {
		float hl = imageLoad(levels, ivec3(max(t.x - 1, 0), t.y, pc.layer)).r;
		float hr = imageLoad(levels, ivec3(min(t.x + 1, SIZE - 1), t.y, pc.layer)).r;
		float hd = imageLoad(levels, ivec3(t.x, max(t.y - 1, 0), pc.layer)).r;
		float hu = imageLoad(levels, ivec3(t.x, min(t.y + 1, SIZE - 1), pc.layer)).r;
		vec4 v = imageLoad(levels, at);
		float sx = float(min(t.x + 1, SIZE - 1) - max(t.x - 1, 0)) * pc.spacing;
		float sz = float(min(t.y + 1, SIZE - 1) - max(t.y - 1, 0)) * pc.spacing;
		v.g = (hr - hl) / sx;
		v.b = (hu - hd) / sz;
		imageStore(levels, at, v);
		return;
	}

	vec2 p = pc.origin + vec2(t) * pc.spacing;
	vec3 base = base_height(p);
	float h = base.x;
	vec4 gw = bilinear_ground(p);
	bool sea = h < 0.0;

	vec4 bl = biome_bilinear(p, 0);   // mesa, plains, forest, own-biome landmass
	vec4 bs = biome_bilinear(p, 1);   // coral reef, root maze, kelp forest, riparian wetlands
	Rivers rv = rivers(p);
	// detail calms down in and right beside channels, and toward the shore
	float calm = smoothstep(2.5, 6.0, rv.r);
	float shore = smoothstep(0.5, 6.0, abs(h));

	// mesas: tablelands. Two tiers of caprock at levels that wander across
	// the desert; the ground above each tier is pressed nearly flat into a
	// tabletop and a narrow band below its rim stretched into a sheer cliff.
	// Where the land rises past a tier you get a mesa, isolated hills become
	// buttes, and rivers cut canyons through it all.
	float table = 0.0;
	if (bl.x > 0.0 && h > 3.0) {
		float h0 = h;
		float lvl = 120.0 + 90.0 * (noised(p / 3500.0, 61u).x * 0.5 + 0.5);
		h = mix(h, caprock(h, lvl), bl.x);
		h = mix(h, caprock(h, lvl + 110.0 + 40.0 * noised(p / 2500.0, 62u).x), bl.x);
		table = bl.x * smoothstep(lvl - 6.0, lvl + 4.0, h0);
	}

	if (!sea) {
		// how strongly the land is carved: rock most, dirt, sand least; the
		// prairie only gently, the mesas' badlands and the mountains hard
		float rough = dot(gw, vec4(0.25, 0.7, 1.0, 0.2));
		rough *= mix(1.0, 0.35, bl.y) * mix(1.0, 1.25, bl.x) * mix(1.0, 1.15, bl.z) * mix(1.0, 0.7, bl.w * gw.r) * mix(1.0, 0.25, bs.w);
		float slope = length(base.yz);
		float ero = erosion(p, base.yz);
		h += ero * 110.0 * rough * smoothstep(0.004, 0.15, slope) * (1.0 - 0.85 * table) * calm * shore * pc.detail;
		// broad swells everywhere (the plains' rolling ground), the
		// forest's hills, dunes on sandy islands; the wetlands lie low and
		// flat, dimpled with hollows and pools
		h += fbm(p, 1.0 / 700.0, 4) * (1.5 + 2.5 * bl.y) * calm * shore * pc.detail;
		h += fbm(p * 1.7 + 31.0, 1.0 / 220.0, 4) * 6.0 * bl.z * calm * shore * pc.detail;
		h += abs(fbm(p * 0.9 - 57.0, 1.0 / 120.0, 3)) * 3.0 * gw.r * calm * smoothstep(0.3, 2.5, h) * pc.detail;
		float hollows = smoothstep(0.15, 0.45, fbm(p + 211.0, 1.0 / 90.0, 3));
		h = mix(h, h * 0.92 - hollows * 1.4, bs.w * smoothstep(1.0, 4.0, h));
	} else {
		// the seafloor: sand waves, coral heads in the reefs, rocky outcrops
		// under the kelp, a tangle of little channels among the roots
		float depthf = smoothstep(0.0, 3.0, -h);
		h += fbm(p, 1.0 / 220.0, 3) * 0.6 * depthf * pc.detail;
		float heads = max(0.0, fbm(p + 77.0, 1.0 / 45.0, 3)) * 3.5;
		h += heads * bs.x * depthf * pc.detail;
		float rocks = 1.0 - abs(fbm(p - 133.0, 1.0 / 70.0, 4));
		h += rocks * rocks * 4.0 * bs.z * depthf * pc.detail;
		float chan = abs(fbm(p + 9.0, 1.0 / 60.0, 3));
		h -= (1.0 - smoothstep(0.0, 0.12, chan)) * 0.7 * bs.y * pc.detail;
	}

	// the river's valley: its floor and channels replace the land (only ever
	// lowering it), blending back out over several widths, so no walls
	float lake = lake_level[idx(ivec2(floor(grid_of(p) + 0.5)))];
	bool in_lake = lake > NO_WATER * 0.5;
	if (rv.valley > 0.0) {
		// The channel shapes the ground both ways: where the land is higher
		// it is cut down to the channel (rounded where it meets the land up
		// at the rim, where a hard crease would render jagged; sharp at the
		// waterline); where it is lower, banks are built up to the channel
		// close to the river, so the water never floats above the ground.
		float target = rv.level + rv.shape;
		float cut = smin(h, target, clamp(rv.shape * 0.6, 0.01, 4.0));
		float built = max(cut, target);
		h = mix(h, mix(cut, built, 1.0 - smoothstep(1.6, 3.5, rv.r)), rv.valley);
	}
	// One water sheet for rivers, oxbow lakes and lakes: the river level
	// across the water and a little past its edge (the ground cuts the
	// shoreline, exactly), then diving under the ground. Where a river meets a
	// lake the higher of the two wins, which is continuous because the river
	// ends at lake level.
	bool wet = rv.wet_r < 2.2;
	float level = rv.level - rv.thin;
	// at the mouth the river water slips under the sea's surface, so the two
	// meet without a seam
	level -= 0.8 * (1.0 - smoothstep(0.3, 1.6, level));
	vec4 sheet = vec4(h - 5.0, 0.0, 0.0, 0.0);
	if (wet)
		sheet = vec4(max(level - max(0.0, rv.wet_r - 1.6) * rv.wet_hw * 1.5, h - 5.0), rv.current, 0.0);
	if (in_lake && lake >= sheet.x)
		sheet = vec4(lake, 0.0, 0.0, 0.0);
	// damp ground just above the water (or under it); dry beds pale instead
	float surface = 0.0;   // sea level
	if (in_lake)
		surface = max(surface, lake);
	if (wet)
		surface = max(surface, level);
	float water = 1.0 - smoothstep(0.0, 0.3, h - surface);
	// (eased in and out over a wide band, several texels even on coarse
	// levels, so the gravel's edge is a smooth curve, not a staircase)
	if (rv.dry && rv.r < 1.8) {
		float gravel = 0.7 * (1.0 - smoothstep(0.4, 1.8, rv.r)) * smoothstep(1.0, 2.0, rv.wet_r);
		if (gravel > 0.001)
			water = -gravel;
	}

	imageStore(levels, at, vec4(h, 0.0, 0.0, water));
	imageStore(water_levels, at, sheet);
}
