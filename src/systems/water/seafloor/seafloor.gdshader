shader_type spatial;
render_mode cull_disabled;   // the shared polar grid is wound for viewing from either side

// The sea floor on a camera-centred polar grid (dense underfoot, coarse far
// away). Vertices take the coarse height from the CPU heightfield texture (the
// same one collision uses) plus fine detail limited to what the local
// mesh spacing can hold: sand ripples and sand waves, displaced where the mesh
// is fine enough to carry them, and shaded to match.

uniform sampler2D heights : filter_linear, repeat_disable;   // r: height (m)
uniform vec3 patch_rect = vec3(0.0, 0.0, 768.0);             // corner x, corner z, size (m)
uniform sampler2D far_heights : filter_linear, repeat_disable; // coarse field for distant land
uniform vec3 far_rect = vec3(0.0, 0.0, 16000.0);
uniform vec3 beach = vec3(0.82, 0.76, 0.6);
uniform vec3 grass = vec3(0.24, 0.36, 0.14);
uniform vec3 scrub = vec3(0.36, 0.38, 0.2);
uniform float ripple_height = 0.06;     // m: small sand ripples
uniform float ripple_wavelength = 1.0;  // m
uniform float wave_height = 0.2;        // m: larger sand waves (megaripples)
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
		// the second harmonic has half the wavelength: include it only where the
		// mesh can carry it too, or it shades as thin dark lines on the crests
		float fade2 = clamp(wl * 0.5 / min_wavelength - 1.0, 0.0, 1.0) * 0.3;
		float h = sin(ph) + fade2 * sin(2.0 * ph);
		float dh = cos(ph) + 2.0 * fade2 * cos(2.0 * ph);
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
	float under = 1.0 - smoothstep(-2.0, -0.5, texture(heights, (xz - patch_rect.xy) / patch_rect.z).r);
	return (1.0 - smoothstep(0.2, 0.45, length(g))) * under;   // ripples only on underwater sand
}

float coarse(vec2 xz) {
	vec2 uv = (xz - patch_rect.xy) / patch_rect.z;
	float near = texture(heights, uv).r;
	float far = texture(far_heights, (xz - far_rect.xy) / far_rect.z).r;
	// the detailed patch near the camera, blending to the coarse far field toward its edge
	vec2 edge = min(uv, 1.0 - uv) * patch_rect.z;
	float w = clamp((min(edge.x, edge.y) - 20.0) / 60.0, 0.0, 1.0);
	return mix(far, near, w);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	spacing = UV.x;
	w.y = coarse(w.xz) + ripples_at(w.xz, spacing * 3.0).x * flatness(w.xz);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(w, 1.0)).xyz;
	wpos = w;
}

void fragment() {
	// coarse slope from the heightfield, fine slope from the octaves this pixel resolves
	float e = patch_rect.z / float(textureSize(heights, 0).x);
	vec2 g = vec2(coarse(wpos.xz + vec2(e, 0.0)) - coarse(wpos.xz - vec2(e, 0.0)),
			coarse(wpos.xz + vec2(0.0, e)) - coarse(wpos.xz - vec2(0.0, e))) / (2.0 * e);
	float sandy = flatness(wpos.xz);
	// ripples shade only where they are real geometry (same limit as the vertex
	// shader), so they never turn into drawn-on lines beyond the mesh's reach
	g += ripples_at(wpos.xz, spacing * 3.0).yz * sandy;
	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float rocky = 1.0 - smoothstep(0.65, 0.85, n.y);
	vec3 sand = mix(sand_deep, sand_shallow, clamp((wpos.y + 40.0) / 25.0, 0.0, 1.0));
	// above the sea: beach, then vegetation, thinning to scrub and rock with height
	float speck = noised(wpos.xz * 0.05).x;
	vec3 land = mix(grass, scrub, clamp((wpos.y - 15.0) / 60.0 + speck * 0.5 - 0.25, 0.0, 1.0));
	land = mix(land, rock, smoothstep(70.0, 110.0, wpos.y + speck * 20.0));
	sand = mix(sand, beach, smoothstep(-1.5, 0.5, wpos.y));
	sand = mix(sand, land, smoothstep(1.5, 3.5, wpos.y + speck * 1.5));
	float speckle = noised(wpos.xz * 3.1).x * 0.15 + noised(wpos.xz * 0.37).x * 0.12;
	ALBEDO = mix(sand, rock, rocky) * (0.88 + speckle);
	ROUGHNESS = 0.95;
}
