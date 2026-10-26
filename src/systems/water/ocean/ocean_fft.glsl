#[compute]
#version 450

// FFT ocean (after Tessendorf, "Simulating Ocean Water"): the small waves as a
// wind-wave spectrum, turned into surface slopes by an inverse FFT each frame.
//
// Several cascades (tiles of different sizes) cover different wavelength bands,
// so nothing is counted twice and their repeats never line up. One shader with
// modes, one workgroup per row:
//   0  build the random initial spectrum h0(k) (once)
//   1  evolve it to time t and form the slope spectrum (i kx h) + i (i kz h)
//   2  inverse FFT along rows    (in shared memory)
//   3  inverse FFT along columns (in shared memory)
//   4  write slopes (x in r, z in g) to mip 0 of each cascade's texture
//   5  average mip level-1 into mip level (antialiasing for distant water)
// Packing both slopes into one complex field works because each is real: the
// real part of the result is the x slope, the imaginary part the z slope.

#define N 256
#define LOG_N 8
#define CASCADES 3

layout(local_size_x = N, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Spectrum { vec4 h0[]; };   // h0(k), conj(h0(-k))
layout(set = 0, binding = 1, std430) restrict buffer Field { vec2 field[]; };   // complex work buffer
layout(set = 0, binding = 2, rgba16f) uniform restrict writeonly image2D dst0;
layout(set = 0, binding = 3, rgba16f) uniform restrict writeonly image2D dst1;
layout(set = 0, binding = 4, rgba16f) uniform restrict writeonly image2D dst2;
layout(set = 0, binding = 5, rgba16f) uniform restrict readonly image2D src0;
layout(set = 0, binding = 6, rgba16f) uniform restrict readonly image2D src1;
layout(set = 0, binding = 7, rgba16f) uniform restrict readonly image2D src2;

layout(push_constant, std430) uniform Params {
	int mode;
	int level;
	int seed;
	int pad0;
	float time;
	float amplitude;       // Phillips constant A
	vec2 wind;             // unit vector
	float wind_speed;      // m/s
	float spread;          // directional spreading exponent
	float short_cutoff;    // m: damp waves shorter than this
	float pad1;
	vec4 size;             // tile size (m) per cascade
	vec4 k_min;            // wavenumber band per cascade
	vec4 k_max;
} pc;

shared vec2 lane[2][N];

const float TAU = 6.28318530718;
const float G = 9.81;
const float TENSION = 7.28e-5;   // surface tension / density (m^3/s^2): capillary waves

uint hash(uint x) {
	x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
	return x;
}

vec2 gaussian(uvec3 id) {
	uint h = hash(id.x + hash(id.y * 7919u + hash(id.z * 104729u + uint(pc.seed))));
	float u1 = max(float(h & 0xffffu) / 65535.0, 1e-6);
	float u2 = float(h >> 16) / 65535.0;
	float r = sqrt(-2.0 * log(u1));
	return vec2(r * cos(TAU * u2), r * sin(TAU * u2));
}

vec2 wave_vector(uvec2 id, uint c) {
	return TAU * (vec2(id) - float(N / 2)) / pc.size[c];
}

// Phillips spectrum, band-limited to this cascade, with broad directional spreading
// (cos^2s of half the angle to the wind) so crests aren't combed into lines.
float phillips(vec2 k, uint c) {
	float kl = length(k);
	if (kl < 1e-6 || kl < pc.k_min[c] || kl >= pc.k_max[c])
		return 0.0;
	float big = pc.wind_speed * pc.wind_speed / G;
	float along = dot(k / kl, pc.wind);
	float dir = pow(max(0.5 + 0.5 * along, 0.0), pc.spread);   // max: a rounding-negative base gives NaN, which the FFT spreads everywhere
	return pc.amplitude * exp(-1.0 / (kl * kl * big * big)) / (kl * kl * kl * kl) * dir
			* exp(-kl * kl * pc.short_cutoff * pc.short_cutoff);
}

vec2 cmul(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

uint index_of(uint c, uint row, uint col) {
	return (c * N + row) * N + col;
}

void main() {
	uint x = gl_LocalInvocationID.x;
	uint y = gl_WorkGroupID.y;
	uint c = gl_WorkGroupID.z;

	if (pc.mode == 0) {
		float dk = TAU / pc.size[c];
		vec2 k = wave_vector(uvec2(x, y), c);
		vec2 h = gaussian(uvec3(x, y, c)) * sqrt(phillips(k, c) * 0.5) * dk;
		uvec2 m = uvec2((N - x) % N, (N - y) % N);          // the index of -k
		vec2 hm = gaussian(uvec3(m, c)) * sqrt(phillips(-k, c) * 0.5) * dk;
		h0[index_of(c, y, x)] = vec4(h, hm.x, -hm.y);
	} else if (pc.mode == 1) {
		vec4 s = h0[index_of(c, y, x)];
		vec2 k = wave_vector(uvec2(x, y), c);
		float kl = length(k);
		float w = sqrt(G * kl + TENSION * kl * kl * kl) * pc.time;   // gravity-capillary dispersion
		vec2 e = vec2(cos(w), sin(w));
		vec2 h = cmul(s.xy, e) + cmul(s.zw, vec2(e.x, -e.y));
		vec2 sx = vec2(-k.x * h.y, k.x * h.x);   // i kx h
		vec2 sz = vec2(-k.y * h.y, k.y * h.x);   // i kz h
		field[index_of(c, y, x)] = sx + vec2(-sz.y, sz.x);
	} else if (pc.mode == 2 || pc.mode == 3) {
		bool rows = pc.mode == 2;
		uint at = rows ? index_of(c, y, x) : index_of(c, x, y);
		lane[0][bitfieldReverse(x) >> (32 - LOG_N)] = field[at];
		barrier();
		uint src = 0u;
		for (uint span = 2u; span <= uint(N); span <<= 1u) {
			uint half_span = span >> 1u;
			uint pos = x % span;
			vec2 v;
			if (pos < half_span) {
				float a = TAU * float(pos) / float(span);
				v = lane[src][x] + cmul(vec2(cos(a), sin(a)), lane[src][x + half_span]);
			} else {
				float a = TAU * float(pos - half_span) / float(span);
				v = lane[src][x - half_span] - cmul(vec2(cos(a), sin(a)), lane[src][x]);
			}
			lane[1u - src][x] = v;
			barrier();
			src = 1u - src;
		}
		field[at] = lane[src][x];
	} else if (pc.mode == 4) {
		// frequencies were stored centred, which flips the sign of every other texel
		float flip = ((x + y) & 1u) == 1u ? -1.0 : 1.0;
		vec4 v = vec4(field[index_of(c, y, x)] * flip, 0.0, 0.0);
		ivec2 p = ivec2(x, y);
		if (c == 0u) imageStore(dst0, p, v);
		else if (c == 1u) imageStore(dst1, p, v);
		else imageStore(dst2, p, v);
	} else {
		uint n = uint(N) >> uint(pc.level);
		if (x >= n)
			return;
		ivec2 p = ivec2(x, y);
		ivec2 q = p * 2;
		vec4 v;
		if (c == 0u)
			v = imageLoad(src0, q) + imageLoad(src0, q + ivec2(1, 0)) + imageLoad(src0, q + ivec2(0, 1)) + imageLoad(src0, q + ivec2(1, 1));
		else if (c == 1u)
			v = imageLoad(src1, q) + imageLoad(src1, q + ivec2(1, 0)) + imageLoad(src1, q + ivec2(0, 1)) + imageLoad(src1, q + ivec2(1, 1));
		else
			v = imageLoad(src2, q) + imageLoad(src2, q + ivec2(1, 0)) + imageLoad(src2, q + ivec2(0, 1)) + imageLoad(src2, q + ivec2(1, 1));
		v *= 0.25;
		if (c == 0u) imageStore(dst0, p, v);
		else if (c == 1u) imageStore(dst1, p, v);
		else imageStore(dst2, p, v);
	}
}
