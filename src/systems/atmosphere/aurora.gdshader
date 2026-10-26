shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// The aurora as a 3D emission field above a round Earth, drawn on a sky dome.
// Units: km. Local frame: x east, n north, altitude above the surface.
//
// Curtains: thin sheets hanging along the geomagnetic field. Each one's foot
// follows a folding curve n = f(x) on the map, single-valued so it never
// crosses itself; aurora.gd keeps the curtains stacked north to south with a
// gap, so they never cross each other. Field lines tilt toward the equator as
// they rise (cot of the inclination), so overhead rays converge on the magnetic
// zenith. For every pixel the view ray is stepped through the shell and, per
// step, the length of ray inside each sheet's profile is integrated in closed
// form (the offset is nearly linear over a step), so sheets seen edge-on glow
// brighter, at any thickness, with no jumps between neighbouring pixels.
//
// Light along a sheet: a base altitude that wanders, a soft lower edge, decay
// upward, field-aligned rays, patchiness and finite length. Colour by
// altitude, per curtain: optional pink fringe at the base (N2), green (O 557.7
// nm) up to that curtain's green top, red (O 630 nm) above, violet tops, and
// whitened cores.
//
// Plus two structureless glows, marched coarsely: a broad red glow high up
// (typical of aurora at mid-latitudes) and faint pulsating green patches.

#define MAX_CURTAINS 6
const float EARTH_R = 6371.0;
const vec3 GREEN = vec3(0.30, 1.0, 0.50);
const vec3 RED = vec3(1.0, 0.16, 0.22);
const vec3 VIOLET = vec3(0.55, 0.35, 1.0);
const vec3 PINK = vec3(1.0, 0.35, 0.62);

uniform float strength = 0.0;
uniform float clock = 0.0;            // display time (s), from aurora.gd
uniform float gain = 0.06;
uniform float field_tilt = 0.6;       // cot(inclination): ~59 degrees at this latitude
uniform int root_steps = 64;
uniform int curtain_count = 0;
uniform vec4 c_shape[MAX_CURTAINS];   // foot north (km), fold amplitude (km), base altitude (km), base softness (km)
uniform vec4 c_glow[MAX_CURTAINS];    // decay height (km), thickness (km), brightness, ray contrast
uniform vec4 c_color[MAX_CURTAINS];   // pink, red, violet, white
uniform vec4 c_style[MAX_CURTAINS];   // green top (km), seed, pace, ray spacing (km)
uniform vec4 c_extent[MAX_CURTAINS];  // west end, east end (km), fold wavelength scale, patchiness
uniform float red_glow = 0.0;
uniform float green_patches = 0.0;
uniform float glow_seed = 0.0;

varying vec3 world_pos;
// pa below: radians per pixel here, so detail smaller than a few pixels fades out (no aliasing)

float hash(float x) { return fract(sin(x * 127.1) * 43758.5453); }

float noise(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i.x + i.y * 57.0);
	float b = hash(i.x + 1.0 + i.y * 57.0);
	float c = hash(i.x + (i.y + 1.0) * 57.0);
	float d = hash(i.x + 1.0 + (i.y + 1.0) * 57.0);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// error function, to ~1e-3 (tanh approximation)
float erf_approx(float x) {
	return tanh(1.1284 * x + 0.1009 * x * x * x);
}

// altitude after travelling t km from the surface with vertical component ey
float altitude(float t, float ey) {
	return sqrt(EARTH_R * EARTH_R + 2.0 * EARTH_R * t * ey + t * t) - EARTH_R;
}

// distance along the ray to a given altitude
float ray_to(float h, float ey) {
	return -EARTH_R * ey + sqrt(EARTH_R * EARTH_R * ey * ey + 2.0 * EARTH_R * h + h * h);
}

// how much of a feature of this size (km) survives at distance t (km): fades below ~4 pixels
float resolved(float size, float t, float pa) {
	return smoothstep(2.0, 6.0, size / max(t * pa, 1e-4));
}

// where curtain k's foot is (km north) at x km east. Three fold harmonics, each
// capped so its slope stays under 0.6 (real curls are gentle, not kinks); the
// total never exceeds the amplitude, which keeps curtains from crossing.
float foot(int k, float x, float t, float pa) {
	float s = c_style[k].y;
	float w = c_extent[k].z;
	float p = c_style[k].z * clock;
	float a = c_shape[k].y;
	float k1 = 0.021 / w;
	float k2 = 0.07 / w;
	float k3 = 0.25 / w;
	float fold = min(0.6 * a, 0.6 / k1) * sin(x * k1 + s + p * 0.05)
			+ min(0.3 * a, 0.6 / k2) * sin(x * k2 + s * 2.3 - p * 0.11)
			+ min(0.1 * a, 0.6 / k3) * resolved(25.0 * w, t, pa) * sin(x * k3 + s * 5.1 + p * 0.3);
	return c_shape[k].x + fold;
}

// signed offset of the ray point at t from curtain k's sheet, in foot coordinates
float offset(int k, float t, vec2 track, float ey, float pa) {
	vec2 g = track * t;
	return g.y + altitude(t, ey) * field_tilt - foot(k, g.x, t, pa);
}

vec3 curtain_light(int k, float t, vec2 track, float ey, float pa) {
	float x = track.x * t;
	float h = altitude(t, ey);
	float s = c_style[k].y;
	float pace = c_style[k].z;
	float ends = smoothstep(c_extent[k].x, c_extent[k].x + 400.0, x) * smoothstep(c_extent[k].y, c_extent[k].y - 400.0, x);
	float patch = mix(1.0, smoothstep(0.15, 0.85, noise(x / 70.0 + s * 3.0 + clock * 0.012 * pace)), c_extent[k].w);
	// rays depend only on position along the foot, so they follow the field lines
	float spacing = c_style[k].w;
	float r = noise(x / spacing + s * 11.0 + clock * 0.08 * pace) * noise(x / (spacing * 0.37) - clock * 0.3 * pace + s);
	float rays = mix(1.0, 0.3 + 2.4 * r * r, c_glow[k].w * resolved(spacing * 0.37, t, pa));
	float base = c_shape[k].z + 10.0 * (noise(x / 140.0 + s * 7.0 + clock * 0.004) - 0.5);
	float above = h - base;
	float lower = 1.0 / (1.0 + exp(-above / c_shape[k].w));              // soft, blurred bottom
	float upper = exp(-max(above, 0.0) / c_glow[k].x);
	// colour by altitude
	float top = c_style[k].x;
	float gw = 1.0 - smoothstep(top - 25.0, top + 25.0, h);
	float rw = c_color[k].y * smoothstep(top - 40.0, top + 50.0, h);
	float vw = c_color[k].z * smoothstep(top + 10.0, top + 120.0, h);
	float pw = c_color[k].x * exp(-pow((above + 2.0) / 7.0, 2.0));
	vec3 col = GREEN * gw + RED * rw * 1.6 + VIOLET * vw + PINK * pw * 1.5;
	col = mix(col, vec3(0.85, 1.0, 0.9) * dot(col, vec3(0.4)), c_color[k].w * gw);   // pale, white cores
	return col * (lower * upper * ends * patch * rays * c_glow[k].z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(world_pos - CAMERA_POSITION_WORLD);
	float pa = max(length(fwidth(dir)), 1e-5);
	if (dir.y < -0.02 || strength <= 0.0)
		discard;
	float ey = max(dir.y, 0.0005);
	vec2 track = vec2(dir.x, -dir.z);   // east, north per km of ray
	float t0 = ray_to(80.0, ey);
	float t1 = ray_to(450.0, ey);
	vec3 light = vec3(0.0);

	// curtains: along each step the ray's offset from a sheet is nearly linear,
	// so the length of ray inside the sheet's Gaussian profile has a closed form
	// (error functions). It is continuous for crossings, grazes and near misses
	// alike, so neighbouring pixels never jump.
	float dt = (t1 - t0) / float(root_steps);
	for (int k = 0; k < MAX_CURTAINS; k++) {
		if (k >= curtain_count)
			break;
		float w = c_glow[k].y;
		float ta = t0;
		float ga = offset(k, ta, track, ey, pa);
		for (int i = 1; i <= root_steps; i++) {
			float tb = t0 + dt * float(i);
			float gb = offset(k, tb, track, ey, pa);
			if (min(abs(ga), abs(gb)) < 4.0 * w || (ga < 0.0) != (gb < 0.0)) {
				float dg = gb - ga;
				float inside;   // km of ray, weighted by the sheet's profile exp(-(g/w)^2)
				if (abs(dg) < 1e-3 * w)
					inside = dt * exp(-ga * ga / (w * w));
				else
					inside = abs(dt * w / dg) * 0.8862 * abs(erf_approx(gb / w) - erf_approx(ga / w));
				if (inside > 1e-4) {
					float tc = ta + dt * clamp(-ga / (abs(dg) > 1e-6 ? dg : 1e-6), 0.0, 1.0);   // closest point
					light += curtain_light(k, tc, track, ey, pa) * min(inside, 120.0);
				}
			}
			ta = tb;
			ga = gb;
		}
	}

	// structureless glows, marched coarsely (they vary slowly)
	if (red_glow > 0.0 || green_patches > 0.0) {
		float ds = (t1 - t0) / 14.0;
		for (int i = 0; i < 14; i++) {
			float t = t0 + ds * (float(i) + 0.5);
			float h = altitude(t, ey);
			vec2 g = track * t;
			vec2 f = vec2(g.x, g.y + h * field_tilt);
			float high = smoothstep(220.0, 280.0, h) * (1.0 - smoothstep(380.0, 450.0, h));
			light += RED * red_glow * high * noise2(f / 600.0 + glow_seed + clock * 0.0015) * ds * 0.004;
			// diffuse aurora: faint, soft patches that pulse slowly, no edges
			float low = smoothstep(95.0, 110.0, h) * (1.0 - smoothstep(120.0, 150.0, h));
			float pulse = 0.6 + 0.4 * sin(clock * 0.35 + noise2(f / 150.0 + glow_seed) * 12.0);
			float patches = noise2(f / 180.0 - glow_seed + clock * 0.002);
			light += GREEN * green_patches * low * patches * patches * pulse * ds * 0.02;
		}
	}

	// a little extinction through the long low paths near the horizon
	light *= exp(-0.03 / max(ey, 0.01));
	ALBEDO = light * gain * strength;
	ALPHA = 1.0;
}
