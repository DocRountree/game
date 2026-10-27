#[compute]
#version 450

// Local wakes and ripples on a grid that follows the player, with exact
// deep-water dispersion. Each frame the height h and vertical velocity v are
// packed into one complex field (h + i v), FFT'd, and every wavelength is
// advanced exactly by its own frequency omega = sqrt(g k + sigma k^3) before
// transforming back. So long waves outrun short ones: a moving hull leaves a
// Kelvin wake (the 19.5 degree V, with feathered diverging waves and transverse
// waves behind) and a swimmer makes dispersing rings. Exact in time, so one
// step per frame is stable at any speed.
//
// Floating things "occupy" water by how deep they sit; any change in occupancy
// pushes that water out (height only, no injected velocity), so moving hulls
// make wakes and bobbing makes rings. A sponge border soaks up waves before the
// FFT's wrap-around could bring them back.
//
// Modes, one workgroup per grid row (x = column):
//   0  scroll the grid, apply sources and the sponge, pack h + i v      A -> B, field_a
//   2  forward FFT along rows of field_a      3  ... along columns
//   1  advance every wavelength exactly                                  field_a -> field_b
//   4  inverse FFT along rows of field_b      5  ... along columns
//   6  unpack h, v, write the display texture               B -> A, disp
//   7  record occupancy without displacing water (objects already present)

#define N 256
#define LOG_N 8

layout(local_size_x = N, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict image2D state_a;   // h, v, unused, occupancy
layout(set = 0, binding = 1, rgba32f) uniform restrict image2D state_b;

struct Source {
	vec4 a;  // centre x, centre z, forward x, forward z
	vec4 b;  // half length, half width, depth, shape (0 hull, 1 box, 2 disc)
};
layout(set = 0, binding = 2, std430) restrict readonly buffer Sources {
	Source items[];
} sources;

layout(set = 0, binding = 3, rgba16f) uniform restrict writeonly image2D disp_img;   // h
layout(set = 0, binding = 4, std430) restrict buffer FieldA { vec2 field_a[]; };
layout(set = 0, binding = 5, std430) restrict buffer FieldB { vec2 field_b[]; };

layout(push_constant, std430) uniform Params {
	vec2 origin;       // world x, z of the grid's corner
	ivec2 shift;       // grid scroll this frame, in cells (mode 0)
	float cell;        // cell size (m)
	float dt;          // frame time (s)
	float damping;     // per second, all wavelengths
	float viscosity;   // extra damping per second per (rad/m)^2: short waves die sooner
	int mode;
	int source_count;
	int sponge;        // border width in cells
	float pad;
} pc;

shared vec2 lane[2][N];

const float TAU = 6.28318530718;
const float G = 9.81;
const float TENSION = 7.28e-5;   // surface tension / density: capillary ripples

vec2 cmul(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

vec2 conj2(vec2 a) {
	return vec2(a.x, -a.y);
}

// How deep the cell at world point p is pushed down by floating things.
float occupancy(vec2 p) {
	float occ_max = 0.0;
	float occ_add = 0.0;
	for (int i = 0; i < pc.source_count; i++) {
		Source s = sources.items[i];
		vec2 d = p - s.a.xy;
		float hl = s.b.x;
		float hw = s.b.y;
		int shape = int(s.b.w + 0.5);
		if (shape == 2) {
			occ_add += clamp(1.0 - length(d) / hl, 0.0, 1.0) * s.b.z;
			continue;
		}
		float f = dot(d, s.a.zw);
		float r = dot(d, vec2(-s.a.w, s.a.z));
		if (shape == 0 && f > hl * 0.2)       // pointed bow
			hw *= clamp((hl - f) / (hl * 0.8), 0.0, 1.0);
		// soft edges: cells fade in and out instead of popping
		float m = clamp((hw - abs(r)) / 0.4 + 0.5, 0.0, 1.0) * clamp((hl - abs(f)) / 0.4 + 0.5, 0.0, 1.0);
		occ_max = max(occ_max, m * s.b.z);
	}
	return occ_max + occ_add;
}

// One radix-2 FFT of N points held one per thread in lane[0] (bit-reversed);
// returns the index of the lane holding the result. dir -1 forward, +1 inverse.
uint fft_lane(uint x, float dir) {
	uint src = 0u;
	for (uint span = 2u; span <= uint(N); span <<= 1u) {
		uint half_span = span >> 1u;
		uint pos = x % span;
		vec2 v;
		if (pos < half_span) {
			float a = dir * TAU * float(pos) / float(span);
			v = lane[src][x] + cmul(vec2(cos(a), sin(a)), lane[src][x + half_span]);
		} else {
			float a = dir * TAU * float(pos - half_span) / float(span);
			v = lane[src][x - half_span] - cmul(vec2(cos(a), sin(a)), lane[src][x]);
		}
		lane[1u - src][x] = v;
		barrier();
		src = 1u - src;
	}
	return src;
}

uint at(uint row, uint col) {
	return row * uint(N) + col;
}

void main() {
	uint x = gl_LocalInvocationID.x;
	uint y = gl_WorkGroupID.y;
	ivec2 c = ivec2(x, y);
	uint rev = bitfieldReverse(x) >> (32 - LOG_N);

	if (pc.mode == 0 || pc.mode == 7) {
		ivec2 from = c + pc.shift;
		vec4 s = vec4(0.0);
		if (all(greaterThanEqual(from, ivec2(0))) && all(lessThan(from, ivec2(N))))
			s = imageLoad(state_a, from);
		float occ = occupancy(pc.origin + (vec2(c) + 0.5) * pc.cell);
		float d = pc.mode == 0 ? occ - s.a : 0.0;
		s.r -= d;                                 // move water, don't kick it
		s.b = 0.0;
		s.a = occ;
		// sponge: waves fade out over the border instead of wrapping round
		int e = min(min(c.x, c.y), min(N - 1 - c.x, N - 1 - c.y));
		float soak = clamp(float(e) / float(pc.sponge), 0.0, 1.0);
		float keep = mix(0.9, 1.0, soak * soak);
		s.r *= keep;
		s.g *= keep;
		imageStore(state_b, c, s);
		field_a[at(y, x)] = s.rg;
	} else if (pc.mode == 2 || pc.mode == 3 || pc.mode == 4 || pc.mode == 5) {
		bool rows = pc.mode == 2 || pc.mode == 4;
		bool forward = pc.mode <= 3;
		uint i = rows ? at(y, x) : at(x, y);
		lane[0][rev] = forward ? field_a[i] : field_b[i];
		barrier();
		uint src = fft_lane(x, forward ? -1.0 : 1.0);
		if (forward)
			field_a[i] = lane[src][x];
		else
			field_b[i] = lane[src][x];
	} else if (pc.mode == 1) {
		// F = FFT(h + i v); since h and v are real, H(k) and V(k) separate out
		// using F(-k). Rotate each wavelength by its own phase, then repack.
		vec2 f = field_a[at(y, x)];
		vec2 fm = conj2(field_a[at((uint(N) - y) % uint(N), (uint(N) - x) % uint(N))]);
		vec2 hk = 0.5 * (f + fm);
		vec2 vk = 0.5 * vec2(f.y - fm.y, -(f.x - fm.x));   // (f - fm) / 2i
		vec2 n = vec2(x < uint(N / 2) ? float(x) : float(x) - float(N),
				y < uint(N / 2) ? float(y) : float(y) - float(N));
		float k = length(n) * TAU / (float(N) * pc.cell);
		vec2 out_f = vec2(0.0);
		if (k > 0.0 && abs(n.x) < float(N / 2) && abs(n.y) < float(N / 2)) {   // drop the mean and Nyquist
			float w = sqrt(G * k + TENSION * k * k * k);
			float cw = cos(w * pc.dt);
			float sw = sin(w * pc.dt);
			float fade = exp(-(pc.damping + pc.viscosity * k * k) * pc.dt);
			vec2 h2 = (hk * cw + vk * (sw / w)) * fade;
			vec2 v2 = (vk * cw - hk * (w * sw)) * fade;
			out_f = h2 + vec2(-v2.y, v2.x);   // h + i v
		}
		field_b[at(y, x)] = out_f;
	} else if (pc.mode == 6) {
		vec2 hv = field_b[at(y, x)] / float(N * N);
		vec4 s = imageLoad(state_b, c);
		float h = clamp(hv.x, -1.5, 1.5);
		imageStore(state_a, c, vec4(h, hv.y, 0.0, s.a));
		imageStore(disp_img, c, vec4(h, 0.0, 0.0, 0.0));
	}
}
