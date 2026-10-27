shader_type spatial;
render_mode cull_disabled;   // the shared polar grid is wound for viewing from either side

// The sea floor on a camera-centred polar grid (dense underfoot, coarse far
// away). Vertices take the coarse height from the CPU heightfield texture (the
// same one collision uses) plus fine fractal relief limited to what the local
// mesh spacing can hold. The fragment shader keeps adding octaves to the
// shading normal down to the pixel's footprint, using value noise with analytic
// derivatives, so detail never runs out and costs one lookup set per octave.

uniform sampler2D heights : filter_linear, repeat_disable;   // r: height (m)
uniform vec3 patch_rect = vec3(0.0, 0.0, 768.0);             // corner x, corner z, size (m)
uniform float relief = 0.55;          // m of fine relief on top of the coarse field
uniform float relief_wavelength = 9.0; // m: longest fine octave
uniform float ripple_height = 0.035;    // m: small sand ripples
uniform float ripple_wavelength = 0.7;  // m
uniform float wave_height = 0.12;       // m: larger sand waves (megaripples)
uniform float wave_wavelength = 6.0;    // m
uniform vec2 current = vec2(0.8, 0.6);  // direction the bottom current runs (ripple crests lie across it)
uniform vec3 sand_deep = vec3(0.55, 0.5, 0.38);
uniform vec3 sand_shallow = vec3(0.72, 0.67, 0.52);
uniform vec3 rock = vec3(0.28, 0.28, 0.26);

varying vec3 wpos;
varying float spacing;

float hash2(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1030));
	p += dot(p, p.yx + 33.33);
	return fract((p.x + p.y) * p.x);
}

// value noise with its gradient (Inigo Quilez): returns (value, d/dx, d/dy)
vec3 noised(vec2 x) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	float k1 = b - a;
	float k2 = c - a;
	float k4 = a - b - c + d;
	return vec3(a + k1 * u.x + k2 * u.y + k4 * u.x * u.y,
			du * vec2(k1 + k4 * u.y, k2 + k4 * u.x));
}

// fine relief: height and gradient, octaves down to min_wavelength
vec3 relief_at(vec2 p, float min_wavelength) {
	vec3 sum = vec3(0.0);
	float wl = relief_wavelength;
	float amp = relief;
	mat2 turn = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int o = 0; o < 9; o++) {
		if (wl < min_wavelength)
			break;
		float fade = clamp(wl / min_wavelength - 1.0, 0.0, 1.0);   // no popping as octaves come in
		vec3 n = noised(p / wl);
		sum += vec3(n.x - 0.5, n.yz / wl) * amp * fade;
		wl *= 0.5;
		amp *= 0.5;
		p = turn * p;   // rotate octaves so their grids don't line up
	}
	return sum;
}

// Sand ripples: crests across the current, gently curving and forking (the phase
// is warped by smooth noise), with a steep lee side. Returns (height, gradient);
// only scales the mesh or pixel can hold contribute.
vec3 ripples_at(vec2 p, float min_wavelength) {
	vec2 dir = normalize(current);
	vec3 sum = vec3(0.0);
	for (int k = 0; k < 2; k++) {
		float wl = k == 0 ? wave_wavelength : ripple_wavelength;
		float amp = k == 0 ? wave_height : ripple_height;
		float fade = clamp(wl / min_wavelength - 1.0, 0.0, 1.0);
		if (fade <= 0.0)
			continue;
		vec3 warp = noised(p / (wl * 7.0) + float(k) * 13.7);   // bends and forks the crests
		float tau = 6.2831853 / wl;
		float ph = dot(p, dir) * tau + warp.x * 9.0;
		vec2 dph = dir * tau + warp.yz * 9.0 / (wl * 7.0);
		// asymmetric profile: gentle stoss side, steeper lee side
		float h = sin(ph) + 0.3 * sin(2.0 * ph);
		float dh = cos(ph) + 0.6 * cos(2.0 * ph);
		float patchy = 0.55 + 0.45 * noised(p / (wl * 11.0) + 5.0).x;   // stronger in places
		sum += vec3(h, dh * dph) * amp * 0.5 * fade * patchy;
	}
	return sum;
}

float flatness(vec2 xz) {
	float e = 4.0;
	vec2 g = vec2(texture(heights, (xz + vec2(e, 0.0) - patch_rect.xy) / patch_rect.z).r
			- texture(heights, (xz - vec2(e, 0.0) - patch_rect.xy) / patch_rect.z).r,
			texture(heights, (xz + vec2(0.0, e) - patch_rect.xy) / patch_rect.z).r
			- texture(heights, (xz - vec2(0.0, e) - patch_rect.xy) / patch_rect.z).r) / (2.0 * e);
	return 1.0 - smoothstep(0.2, 0.45, length(g));   // ripples only where sand can lie
}

float coarse(vec2 xz) {
	return texture(heights, (xz - patch_rect.xy) / patch_rect.z).r;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	spacing = UV.x;
	w.y = coarse(w.xz) + relief_at(w.xz, spacing * 3.0).x + ripples_at(w.xz, spacing * 3.0).x * flatness(w.xz);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(w, 1.0)).xyz;
	wpos = w;
}

void fragment() {
	// coarse slope from the heightfield, fine slope from the octaves this pixel resolves
	float e = patch_rect.z / float(textureSize(heights, 0).x);
	vec2 g = vec2(coarse(wpos.xz + vec2(e, 0.0)) - coarse(wpos.xz - vec2(e, 0.0)),
			coarse(wpos.xz + vec2(0.0, e)) - coarse(wpos.xz - vec2(0.0, e))) / (2.0 * e);
	float footprint = max(length(fwidth(wpos.xz)), 0.003);
	vec3 r = relief_at(wpos.xz, footprint * 2.0);
	float sandy = flatness(wpos.xz);
	g += r.yz + ripples_at(wpos.xz, footprint * 2.0).yz * sandy;
	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float rocky = 1.0 - smoothstep(0.65, 0.85, n.y);
	vec3 sand = mix(sand_deep, sand_shallow, clamp((wpos.y + 40.0) / 25.0, 0.0, 1.0));
	float speckle = noised(wpos.xz * 3.1).x * 0.15 + noised(wpos.xz * 0.37).x * 0.12;
	ALBEDO = mix(sand, rock, rocky) * (0.88 + speckle);
	ROUGHNESS = 0.95;
}
