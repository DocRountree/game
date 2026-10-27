#[compute]
#version 450

// Terrain heights around the camera, as nested square levels (a geometry
// clipmap): level k has 256 x 256 texels spaced 0.5 * 2^k m. Each texel is the
// terrain function at that point:
//   baked height (smooth cubic B-spline over the world grid)
//   + fractal detail, finer octaves only where the level can resolve them,
//     damped on steep ground (derivative-damped fBm)
//   + gullies: stripes running straight downhill, phase-randomised per cell
//     and blended (in the spirit of runevision's erosion filter / phasor noise)
//   then carved by the river channels from the nearest-river field.
// Mode 0 writes height and water info; mode 1 fills in the gradient from the
// neighbouring texels.
//   r height (m)  g dh/dx  b dh/dz
//   a water: |a| < 15000 = nearby water surface height (sea 0, lake, river);
//     a >= 20000 = dry riverbed, a - 20000 = how much (0..1)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Base { float base_h[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer RiverA { vec4 river_a[]; };   // offset xz to centreline, surface, half width
layout(set = 0, binding = 2, std430) restrict readonly buffer RiverB { vec4 river_b[]; };   // flow dir xz, depth, speed (0 = dry)
layout(set = 0, binding = 3, std430) restrict readonly buffer Ground { uint ground[]; };    // RGBA8 weights: sand, dirt, rock, lakebed
layout(set = 0, binding = 4, std430) restrict readonly buffer Lake { float lake_level[]; };
layout(set = 0, binding = 5, rgba32f) uniform restrict image2DArray levels;

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
	float pad0;
	float pad1;
} pc;

const int SIZE = 256;
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
	return (p + 0.5 * pc.world_size) / pc.cell - 0.5;
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

// Baked height and its gradient (per metre), smooth cubic B-spline.
vec3 base_height(vec2 p) {
	vec2 g = grid_of(p);
	vec2 i = floor(g);
	vec2 f = g - i;
	vec4 wx = bspline(f.x);
	vec4 wy = bspline(f.y);
	vec4 dx = bspline_d(f.x);
	vec4 dy = bspline_d(f.y);
	vec3 s = vec3(0.0);
	for (int y = 0; y < 4; y++) {
		for (int x = 0; x < 4; x++) {
			float h = base_h[idx(ivec2(i) + ivec2(x - 1, y - 1))];
			s += h * vec3(wx[x] * wy[y], dx[x] * wy[y] / pc.cell, wx[x] * dy[y] / pc.cell);
		}
	}
	return s;
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

// Stripes running downhill (gullies and spurs), blended from the four nearest
// cells, each with its own random phase so the pattern never repeats.
float gullies(vec2 p, vec2 down, float wavelength, uint salt) {
	vec2 across = vec2(-down.y, down.x);
	vec2 g = p / wavelength;
	ivec2 i = ivec2(floor(g));
	vec2 f = g - floor(g);
	vec2 w = f * f * (3.0 - 2.0 * f);
	float s = 0.0;
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			float phase = float(hash2(i + ivec2(x, y), salt) & 0xffffu) / 65536.0 * TAU;
			float c = cos(dot(p, across) / wavelength * TAU + phase);
			s += c * (x == 1 ? w.x : 1.0 - w.x) * (y == 1 ? w.y : 1.0 - w.y);
		}
	}
	return s;
}

// Interpolated nearest-river data: centreline point, surface, half width,
// flow direction, depth, wetness.
void river_at(vec2 p, out vec2 q, out vec4 ra, out vec4 rb) {
	vec2 g = grid_of(p);
	ivec2 i = ivec2(floor(g));
	vec2 f = g - floor(g);
	vec2 qs = vec2(0.0);
	ra = vec4(0.0);
	rb = vec4(0.0);
	float wsum = 0.0;
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			ivec2 c = i + ivec2(x, y);
			int k = idx(c);
			vec4 a = river_a[k];
			float w = (x == 1 ? f.x : 1.0 - f.x) * (y == 1 ? f.y : 1.0 - f.y);
			if (a.w <= 0.0)
				continue;
			vec2 centre = (vec2(clamp(c, ivec2(0), ivec2(pc.n - 1))) + 0.5) * pc.cell - 0.5 * pc.world_size;
			qs += (centre + a.xy) * w;
			ra += a * w;
			rb += river_b[k] * w;
			wsum += w;
		}
	}
	if (wsum > 0.0) {
		q = qs / wsum;
		ra /= wsum;
		rb /= wsum;
		ra.w *= smoothstep(0.0, 0.6, wsum);   // fade out at the edge of the field
	} else {
		q = p + vec2(1e6);
	}
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
	float rough = dot(gw, vec4(0.18, 0.7, 1.0, 0.2));
	rough *= sea ? 0.25 : mix(0.25, 1.0, smoothstep(1.0, 40.0, h));

	vec2 q;
	vec4 ra;
	vec4 rb;
	river_at(p, q, ra, rb);
	float hw = max(ra.w, 0.01);
	float r = distance(p, q) / hw;
	// detail calms down in and right beside channels
	float calm = ra.w > 0.0 ? smoothstep(1.0, 4.0, r) : 1.0;

	// gullies down the baked slopes, two scales
	float slope = length(base.yz);
	if (slope > 0.01 && pc.detail > 0.0) {
		vec2 down = -base.yz / slope;
		float strength = smoothstep(0.03, 0.35, slope) * rough * calm * pc.detail;
		for (int o = 0; o < 2; o++) {
			float wl = o == 0 ? 240.0 : 75.0;
			float fade = clamp((wl - 4.0 * pc.spacing) / (4.0 * pc.spacing), 0.0, 1.0);
			h += gullies(p, down, wl, uint(31 + o)) * wl * 0.035 * strength * fade;
		}
	}

	// fractal detail, band-limited to what this level can show
	float amp = 22.0 * rough * calm * pc.detail;
	float freq = 1.0 / 420.0;
	vec2 d = base.yz * 0.0;
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
		amp *= 0.47;
		freq *= 2.03;
		pp = rot * pp;
	}

	// river channels: a parabolic bed below the water surface, banks rising out
	float water = 0.0;
	if (ra.w > 0.0) {
		float surface = ra.z;
		bool wet = rb.w > 0.01;
		float depth = rb.z * (wet ? 1.0 : 0.6);
		float carve = surface - depth * max(0.0, 1.0 - r * r) + max(0.0, r - 1.0) * hw * 0.55;
		h = smin(h, carve, 0.8);
		if (wet && r < 3.0)
			water = surface;
		else if (!wet && r < 1.6)
			water = 20000.0 + 1.0 - smoothstep(0.9, 1.6, r);
	}
	float lake = lake_level[idx(ivec2(floor(grid_of(p) + 0.5)))];
	if (lake > NO_WATER * 0.5 && water < 15000.0)
		water = max(water, lake);

	imageStore(levels, at, vec4(h, 0.0, 0.0, water));
}
