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
//   then carved by the river channels: exact distances to the baked river,
//   oxbow and meander-scar segments (found through a coarse tile index), so
//   banks are smooth at any resolution and channels merge at confluences.
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

// Every channel near p: the lowest channel profile (carve), and the channel
// p is most inside of (relative to its width), which owns the water there.
struct Channel {
	float r;        // distance / half width
	float hw;
	float surface;
	float depth;
	float speed;    // < 0: dry bed
	float fill;     // how much of the channel holds water (0..1)
	vec2 dir;
};

// best: the channel p is most inside of (any); water: the same among channels
// holding water, so a dry bed joining a river never punches a hole in it.
float channels(vec2 p, out Channel best, out Channel water) {
	best.r = 1e9;
	best.hw = 1.0;
	best.surface = 0.0;
	best.depth = 0.0;
	best.speed = -1.0;
	best.fill = 0.0;
	best.dir = vec2(1.0, 0.0);
	water = best;
	float carve = 1e9;
	ivec2 tile = ivec2(floor((p - (pc.center - 0.5 * pc.world_size)) / pc.tile_size));
	if (any(lessThan(tile, ivec2(0))) || any(greaterThanEqual(tile, ivec2(pc.tiles_per_side))))
		return carve;
	int t = tile.y * pc.tiles_per_side + tile.x;
	int base = pc.tiles_per_side * pc.tiles_per_side + 1;
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
		if (r > 10.0)
			continue;
		float surface = mix(b.x, b.y, u);
		float speed = mix(c.z, c.w, u);
		float depth = mix(c.x, c.y, u) * (speed < 0.0 ? 0.7 : 1.0);
		// A rounded bed whose sides still slope where they meet the water
		// (a bed that met it flat would turn every tiny mesh error into a
		// jagged shoreline metres wide); the banks carry on up at that slope,
		// round over onto the floodplain a little above the water, which then
		// rises gently; far out the ground fades back to the natural terrain
		// (see main), so there are no walls. Every level carves every channel,
		// so levels always agree.
		float bank = 0.6 + 0.2 * depth;
		float rise = 2.0 * depth * (r - 1.0);   // the bed's slope carried on up, straight for a while
		float profile = r < 1.0 ? surface - depth * (1.0 - r * r)
				: surface + rise / (1.0 + rise / bank) + max(0.0, r - 2.0) * hw * 0.06;
		carve = min(carve, profile);
		Channel here;
		here.r = r;
		here.hw = hw;
		here.surface = surface;
		here.depth = depth;
		here.speed = speed;
		here.fill = mix(e.x, e.y, u);
		here.dir = normalize(ab);
		if (r < best.r)
			best = here;
		if (speed >= 0.0 && here.fill > 0.02 && r < water.r)
			water = here;
	}
	return carve;
}

float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
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

	// how rugged: rock most, dirt, then sand; the seafloor and beaches stay smooth
	float rough = dot(gw, vec4(0.15, 0.55, 1.0, 0.15));
	rough *= sea ? 0.25 : mix(0.25, 1.0, smoothstep(1.0, 40.0, h));

	Channel ch;
	Channel wc;
	float carve = channels(p, ch, wc);
	// detail calms down in and right beside channels
	float calm = smoothstep(2.5, 6.0, ch.r);

	// fractal detail, band-limited to what this level can show
	float amp = 6.0 * rough * calm * pc.detail;
	float freq = 1.0 / 300.0;
	vec2 d = vec2(0.0);
	vec2 pp = p;
	const mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int o = 0; o < 14; o++) {
		float wl = 1.0 / freq;
		float fade = clamp((wl - 4.0 * pc.spacing) / (4.0 * pc.spacing), 0.0, 1.0);
		if (fade <= 0.0)
			break;
		vec3 nz = noised(pp * freq, uint(o + 1));
		d += nz.yz * amp * freq;
		h += amp * fade * nz.x / (1.0 + 0.6 * dot(d, d));
		amp *= 0.45;
		freq *= 2.03;
		pp = rot * pp;
	}

	// river channels: a parabolic bed below the water surface, banks rising out
	float water = 0.0;
	float lake = lake_level[idx(ivec2(floor(grid_of(p) + 0.5)))];
	bool in_lake = lake > NO_WATER * 0.5;
	if (carve < 1e8)
		h = mix(smin(h, carve, 0.4), h, smoothstep(5.0, 10.0, ch.r));   // blend out gently: no walls
	bool wet = wc.speed >= 0.0 && wc.fill > 0.02 && wc.r < 4.0;
	// where a river starts to flow it is a thin stream low in its bed
	float level = wc.surface - wc.depth * (1.0 - wc.fill);
	// at the mouth the river water slips under the sea's surface, so the two
	// meet without a seam
	level -= 0.8 * (1.0 - smoothstep(0.3, 1.6, level));
	if (wet && wc.r > 1.0) {
		// natural levees: the banks never dip below the water beside them,
		// fading out into the floodplain well before the river's reach ends
		// (rising gradually from the waterline: a step there would serrate it)
		float levee = max(h, level + 0.5 * smoothstep(1.0, 1.8, wc.r) - max(0.0, wc.r - 2.2) * wc.hw * 0.25);
		h = mix(levee, h, smoothstep(2.4, 3.6, wc.r));
	}
	// One water sheet for rivers, oxbow lakes and lakes: level across the
	// water and a little past its edge (the ground cuts the shoreline, exactly),
	// then diving under the ground. Where a river meets a lake the higher of
	// the two wins, which is continuous because the river ends at lake level.
	vec4 sheet = vec4(h - 5.0, 0.0, 0.0, 0.0);
	if (wet) {
		float y = level - max(0.0, wc.r - 1.8) * wc.hw * 1.5;
		vec2 current = wc.dir * wc.speed * (1.0 - 0.6 * min(wc.r * wc.r, 1.0));
		sheet = vec4(max(y, h - 5.0), current, 0.0);
	}
	if (in_lake && lake >= sheet.x)
		sheet = vec4(lake, 0.0, 0.0, 0.0);
	// damp ground just above the water (or under it); dry beds pale instead
	float surface = 0.0;   // sea level
	if (in_lake)
		surface = max(surface, lake);
	if (wet)
		surface = max(surface, level);
	water = 1.0 - smoothstep(0.0, 0.3, h - surface);
	if (ch.speed < 0.0 && ch.r < 1.3 && !(wet && wc.r < 1.2))
		water = -0.7 * (1.0 - smoothstep(0.7, 1.3, ch.r));

	imageStore(levels, at, vec4(h, 0.0, 0.0, water));
	imageStore(water_levels, at, sheet);
}
