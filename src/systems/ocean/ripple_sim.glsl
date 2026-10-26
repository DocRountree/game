#[compute]
#version 450

// Interactive ripples: a damped 2D wave equation on a grid that follows the player.
//
// State texels hold (height, previous height, foam, previous occupancy).
// Mode 0 scrolls the grid and applies sources: every floating object
// "occupies" water by how deep it sits, and any change in occupancy pushes
// that water out, so moving hulls make wakes and bobbing makes rings.
// Mode 1 is one wave-equation step and also writes the sampled display texture.
// Mode 2 records occupancy without displacing water (objects already present).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D src_img;
layout(set = 0, binding = 1, rgba32f) uniform restrict writeonly image2D dst_img;

struct Source {
	vec4 a;  // centre x, centre z, forward x, forward z
	vec4 b;  // half length, half width, depth, shape (0 hull, 1 box, 2 disc)
};
layout(set = 0, binding = 2, std430) restrict readonly buffer Sources {
	Source items[];
} sources;

layout(set = 0, binding = 3, rgba16f) uniform restrict writeonly image2D disp_img;

layout(push_constant, std430) uniform Params {
	vec2 origin;       // world x, z of the grid's corner
	ivec2 shift;       // grid scroll this frame, in cells (mode 0)
	float cell;        // cell size (m)
	float dt;          // wave step (s)
	float k;           // (wave speed * dt / cell)^2
	float frame_dt;    // frame time (s), for foam decay
	int mode;
	int source_count;
	int size;
	float pad;
} pc;

vec4 load_state(ivec2 c) {
	if (c.x < 0 || c.y < 0 || c.x >= pc.size || c.y >= pc.size)
		return vec4(0.0);
	return imageLoad(src_img, c);
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

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (c.x >= pc.size || c.y >= pc.size)
		return;

	if (pc.mode != 1) {
		vec4 v = load_state(c + pc.shift);
		float occ = occupancy(pc.origin + (vec2(c) + 0.5) * pc.cell);
		float d = pc.mode == 0 ? occ - v.a : 0.0;
		v.r -= d;                               // shift both time levels: moves water
		v.g -= d;                               // without injecting velocity
		v.b += max(d - 0.02, 0.0) * 5.0;        // foam where a hull shoves water hard
		v.b *= exp(-pc.frame_dt / 2.0);
		v.a = occ;
		imageStore(dst_img, c, v);
		return;
	}

	vec4 v = load_state(c);
	float h = v.r;
	float lap = load_state(c + ivec2(1, 0)).r + load_state(c - ivec2(1, 0)).r
			+ load_state(c + ivec2(0, 1)).r + load_state(c - ivec2(0, 1)).r - 4.0 * h;
	float nh = h + (h - v.g) * (1.0 - 0.6 * pc.dt) + (pc.k + 0.004) * lap;
	// absorbing border so waves leave the grid instead of bouncing back
	int e = min(min(c.x, c.y), min(pc.size - 1 - c.x, pc.size - 1 - c.y));
	nh *= 0.94 + 0.06 * clamp(float(e) / 24.0, 0.0, 1.0);
	nh = clamp(nh, -1.0, 1.0);
	float foam = v.b + pc.dt * clamp((abs(nh - h) / pc.dt - 1.2) * 1.5, 0.0, 2.0);
	foam = min(foam, 1.5);
	imageStore(dst_img, c, vec4(nh, h, foam, v.a));
	imageStore(disp_img, c, vec4(nh, foam, 0.0, 0.0));
}
