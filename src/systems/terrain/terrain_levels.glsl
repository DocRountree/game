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
// Per segment, 3 vec4: (p0.xz, p1.xz), (surface 0, 1, half width 0, 1), (depth 0, 1, speed 0, 1; -1 = dry)
layout(set = 0, binding = 1, std430) restrict readonly buffer Segments { vec4 seg[]; };
// tiles_per_side^2 + 1 offsets, then segment indices
layout(set = 0, binding = 2, std430) restrict readonly buffer Tiles { int tiles[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Ground { uint ground[]; };    // RGBA8 weights: sand, dirt, rock, lakebed
layout(set = 0, binding = 4, std430) restrict readonly buffer Lake { float lake_level[]; };
layout(set = 0, binding = 5, rgba32f) uniform restrict image2DArray levels;
// River water per texel: sheet height (tucked under the ground where there is
// no river), current x, z (m/s), and foam (rapids).
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
	vec2 dir;
};

float channels(vec2 p, out Channel best) {
	best.r = 1e9;
	best.hw = 1.0;
	best.surface = 0.0;
	best.depth = 0.0;
	best.speed = -1.0;
	best.dir = vec2(1.0, 0.0);
	float carve = 1e9;
	ivec2 tile = ivec2(floor((p - (pc.center - 0.5 * pc.world_size)) / pc.tile_size));
	if (any(lessThan(tile, ivec2(0))) || any(greaterThanEqual(tile, ivec2(pc.tiles_per_side))))
		return carve;
	int t = tile.y * pc.tiles_per_side + tile.x;
	int base = pc.tiles_per_side * pc.tiles_per_side + 1;
	for (int k = tiles[t]; k < tiles[t + 1]; k++) {
		int i = tiles[base + k] * 3;
		vec4 a = seg[i];
		vec4 b = seg[i + 1];
		vec4 c = seg[i + 2];
		vec2 ab = a.zw - a.xy;
		float u = clamp(dot(p - a.xy, ab) / dot(ab, ab), 0.0, 1.0);
		float hw = mix(b.z, b.w, u);
		float r = distance(p, a.xy + ab * u) / hw;
		if (r > 6.0)
			continue;
		float surface = mix(b.x, b.y, u);
		float speed = mix(c.z, c.w, u);
		float depth = mix(c.x, c.y, u) * (speed < 0.0 ? 0.7 : 1.0);
		// a smooth, rounded bed below the surface (every level carves every
		// channel, so levels always agree)
		// banks round over onto a floodplain a little above the water, which
		// then rises gently away from the river
		float bank = 0.6 + 0.15 * depth;
		float profile = r < 1.0 ? surface - depth * (1.0 - smoothstep(0.0, 1.0, r * r))
				: surface + bank * smoothstep(1.0, 2.0, r) + max(0.0, r - 2.0) * hw * 0.25
				+ pow(max(0.0, r - 2.5), 2.0) * hw * 0.35;   // steepening, to meet the hillside by r = 6
		carve = min(carve, profile);
		if (r < best.r) {
			best.r = r;
			best.hw = hw;
			best.surface = surface;
			best.depth = depth;
			best.speed = speed;
			best.dir = normalize(ab);
		}
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
	float carve = channels(p, ch);
	// detail calms down in and right beside channels
	float calm = smoothstep(1.5, 4.0, ch.r);

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
		h = smin(h, carve, 0.6);
	bool wet = ch.speed >= 0.0 && ch.r < 4.0;
	if (wet && ch.r > 1.0) {
		// natural levees: the banks never dip below the water beside them,
		// fading out into the floodplain well before the river's reach ends
		float levee = max(h, ch.surface + 0.25 - max(0.0, ch.r - 2.2) * ch.hw * 0.25);
		h = mix(levee, h, smoothstep(2.4, 3.6, ch.r));
	}
	// the water sheet: level across the channel and a little past the banks
	// (the ground cuts the shoreline), then diving under the ground
	vec4 river_water = vec4(h - 5.0, 0.0, 0.0, 0.0);
	if (wet && !in_lake && ch.surface > 0.6) {
		float y = ch.surface - max(0.0, ch.r - 2.0) * ch.hw;
		vec2 current = ch.dir * ch.speed * (1.0 - 0.6 * min(ch.r * ch.r, 1.0));
		float foam = smoothstep(1.8, 3.6, ch.speed);
		river_water = vec4(max(y, h - 5.0), current, foam);
	}
	// damp ground just above the water (or under it); dry beds pale instead
	float surface = 0.0;   // sea level
	if (in_lake)
		surface = max(surface, lake);
	if (wet && ch.r < 4.0)
		surface = max(surface, ch.surface);
	water = 1.0 - smoothstep(0.0, 0.6, h - surface);
	if (ch.speed < 0.0 && ch.r < 1.3)
		water = -0.7 * (1.0 - smoothstep(0.7, 1.3, ch.r));

	imageStore(levels, at, vec4(h, 0.0, 0.0, water));
	imageStore(water_levels, at, river_water);
}
