shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// The aurora as a 3D emission field above a round Earth, drawn on a sky dome.
// Units: km. Local frame: x east, n north, altitude above the surface.
//
// Curtains are made of pillars: field-aligned rays, at two scales with gaps,
// each with its own ragged base and length, brightest near the bottom. A
// curtain only reads as a sheet where pillars crowd together.
//
// Shape: each curtain is a straight line (plus gentle folds) in an "unwarped"
// plane; the plane is then warped by a few swirls. A swirl rotates points about
// its centre by an angle that fades with distance, so it maps every circle to
// itself: an exact bijection. Straight parallel curtains therefore become S
// folds, spirals and folds within folds, yet can never cross themselves or each
// other. The inverse of a swirl is the opposite rotation, so the shader maps
// each sample back exactly.
//
// Field lines tilt toward the equator as they rise, so pillars overhead
// converge on the magnetic zenith. Per pixel the view ray is stepped through
// the shell; near or inside a sheet each step is refined into exact sub-steps,
// and per sub-step the length of ray inside the sheet's profile is integrated
// in closed form (error functions), with the light blended from both ends. So
// edge-on sheets glow brighter and neighbouring pixels change smoothly: no
// stripes, grain or moire, even where rays graze swirled sheets. Pillar detail
// fades by its actual on-screen size (catching pillars seen end-on overhead).
//
// Colour by altitude, per curtain and drifting along it: green (yellow-green to
// cyan), red or violet-blue tops, optional magenta (N2) lower parts. Only
// genuinely bright light whitens.

#define MAX_CURTAINS 4
#define MAX_SWIRLS 5
#define SUBSAMPLES 3   // extra exact sub-steps per step, only near or inside a sheet
const float EARTH_R = 6371.0;
const vec3 GREEN_YELLOW = vec3(0.55, 1.0, 0.22);
const vec3 GREEN_CYAN = vec3(0.12, 1.0, 0.72);
const vec3 RED = vec3(1.0, 0.14, 0.2);
const vec3 BLUE_VIOLET = vec3(0.42, 0.3, 1.0);
const vec3 MAGENTA = vec3(1.0, 0.2, 0.75);

uniform float strength = 0.0;
uniform float clock = 0.0;            // display time (s), from aurora.gd
uniform float gain = 0.012;
uniform float saturation = 0.75;      // below 1 pulls colour toward grey: a fainter, see-through glow
uniform float blur = 1.0;             // softens pillars and fine detail (higher = less defined)
uniform float field_tilt = 0.6;       // cot(inclination): ~59 degrees at this latitude
uniform int steps = 72;
uniform int curtain_count = 0;
uniform vec4 c_shape[MAX_CURTAINS];   // line north (km, unwarped), fold amplitude (km), base altitude (km), base softness (km)
uniform vec4 c_glow[MAX_CURTAINS];    // decay height (km), thickness (km), brightness, pillar spacing (km)
uniform vec4 c_color[MAX_CURTAINS];   // magenta share, red, blue-violet, green hue (0 yellow .. 1 cyan)
uniform vec4 c_style[MAX_CURTAINS];   // green top (km), seed, pace, sheet share (0 pillars only .. 1 continuous)
uniform vec4 c_extent[MAX_CURTAINS];  // west end, east end (km, unwarped), fold wavelength scale, base raggedness (km)
uniform int swirl_count = 0;
uniform vec4 swirls[MAX_SWIRLS];      // centre x, centre n (km), radius (km), angle at the centre (rad)
uniform float red_glow = 0.0;
uniform float green_patches = 0.0;
uniform float glow_seed = 0.0;

varying vec3 world_pos;

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

float erf_approx(float x) {
	return tanh(1.1284 * x + 0.1009 * x * x * x);
}

float altitude(float t, float ey) {
	return sqrt(EARTH_R * EARTH_R + 2.0 * EARTH_R * t * ey + t * t) - EARTH_R;
}

float ray_to(float h, float ey) {
	return -EARTH_R * ey + sqrt(EARTH_R * EARTH_R * ey * ey + 2.0 * EARTH_R * h + h * h);
}

// fades detail below a few pixels at distance t (pa: radians per pixel)
float resolved(float size, float t, float pa) {
	return smoothstep(2.0 + 4.0 * blur, 6.0 + 8.0 * blur, size / max(t * pa, 1e-4));
}

// fades pillar detail of this size (km along the curtain) once it is under a few
// pixels on screen; dx_px is how far the along-curtain coordinate moves per
// pixel here, which also catches pillars seen end-on near the magnetic zenith
float on_screen(float size, float dx_px) {
	return smoothstep(2.0 + 4.0 * blur, 6.0 + 8.0 * blur, size / dx_px);
}

// map a foot point back through the swirls (each undone by the opposite rotation)
vec2 unwarp(vec2 q) {
	for (int i = MAX_SWIRLS - 1; i >= 0; i--) {
		if (i >= swirl_count)
			continue;
		vec2 d = q - swirls[i].xy;
		float r = length(d) / swirls[i].z;
		float a = -swirls[i].w * exp(-r * r);
		float c = cos(a);
		float s = sin(a);
		q = swirls[i].xy + vec2(c * d.x - s * d.y, s * d.x + c * d.y);
	}
	return q;
}

// curtain k's line in the unwarped plane: gentle folds, slope under 0.6
float line(int k, float x, float t, float pa) {
	float s = c_style[k].y;
	float w = c_extent[k].z;
	float p = c_style[k].z * clock;
	float a = c_shape[k].y;
	float k1 = 0.021 / w;
	float k2 = 0.07 / w;
	float k3 = 0.25 / w;
	return c_shape[k].x + min(0.6 * a, 0.6 / k1) * sin(x * k1 + s + p * 0.05)
			+ min(0.3 * a, 0.6 / k2) * sin(x * k2 + s * 2.3 - p * 0.11)
			+ min(0.1 * a, 0.6 / k3) * resolved(25.0 * w, t, pa) * sin(x * k3 + s * 5.1 + p * 0.3);
}

// the ray point at t, as a foot point on the map (following its field line down)
vec2 foot_point(float t, vec2 track, float ey) {
	vec2 g = track * t;
	return vec2(g.x, g.y + altitude(t, ey) * field_tilt);
}

float offset(int k, float t, vec2 track, float ey, float pa) {
	vec2 u = unwarp(foot_point(t, track, ey));
	return u.y - line(k, u.x, t, pa);
}

vec3 curtain_light(int k, float t, vec2 track, float ey, float pa, float dx_px) {
	float h = altitude(t, ey);
	float x = unwarp(foot_point(t, track, ey)).x;   // along the curtain's own material
	float s = c_style[k].y;
	float pace = c_style[k].z;
	float ends = smoothstep(c_extent[k].x, c_extent[k].x + 400.0, x) * smoothstep(c_extent[k].y, c_extent[k].y - 400.0, x);
	// pillars at two scales, each flickering; where they crowd, a sheet appears
	float sp = c_glow[k].w;
	float big = noise(x / sp + s * 11.0 + clock * 0.05 * pace);
	float fine = noise(x / (sp * 0.33) - clock * 0.25 * pace + s * 3.0);
	float detail = on_screen(sp * 0.33, dx_px);
	// softer profiles as blur rises: rounded pillars rather than sharp lines
	float pillars = pow(big, mix(3.0, 1.8, clamp(blur, 0.0, 1.0))) * 2.0 + mix(0.35, pow(fine, 2.5) * 1.6, detail * (1.0 - 0.5 * blur)) * big;
	pillars = mix(0.75, pillars, on_screen(sp * (1.0 + 2.0 * blur), dx_px));   // too fine on screen: merge into a glow
	pillars = mix(pillars, 0.75, 0.35 * blur);                                // and softer everywhere
	float crowd = smoothstep(0.1, 0.9, noise(x / 180.0 + s * 5.0 + clock * 0.01 * pace));   // dense stretches
	float sheet = c_style[k].w;
	float amount = mix(pillars * (0.4 + 0.9 * crowd), 1.0, sheet) * mix(0.25, 1.0, crowd);
	// each pillar has its own base height and length: ragged, staggered bottoms
	float far = on_screen(sp * (1.0 + 2.0 * blur), dx_px);   // 0 where pillars are too fine to keep crisp
	float ragged = c_extent[k].w * (noise(x / (sp * 0.5) + s * 17.0) - 0.5) * 2.0 * far;
	float base = c_shape[k].z + 8.0 * (noise(x / 160.0 + s * 7.0 + clock * 0.004) - 0.5) + ragged;
	float decay = c_glow[k].x * mix(1.0, mix(0.5, 1.4, noise(x / sp + s * 23.0)), far);
	float above = h - base;
	float lower = 1.0 / (1.0 + exp(-above / (c_shape[k].w * (1.0 + 0.6 * blur))));
	float upper = exp(-max(above, 0.0) / decay);
	float bottom_glow = 1.0 + 0.8 * exp(-pow(max(above, 0.0) / 15.0, 2.0));   // brightest near the bottom
	// colour by altitude, drifting along the curtain
	float drift = mix(0.3, 1.7, noise(x / 350.0 + s * 9.0 + clock * 0.003));
	float top = c_style[k].x;
	vec3 green = mix(GREEN_YELLOW, GREEN_CYAN, c_color[k].w);
	vec3 low = mix(green, MAGENTA, clamp(c_color[k].x * drift, 0.0, 1.0));
	float gw = 1.0 - smoothstep(top - 25.0, top + 25.0, h);
	float rw = c_color[k].y * drift * smoothstep(top - 40.0, top + 50.0, h);
	float bw = c_color[k].z * (2.0 - drift) * smoothstep(top + 10.0, top + 110.0, h);
	vec3 col = low * gw + RED * rw * 1.5 + BLUE_VIOLET * bw;
	return col * (lower * upper * bottom_glow * amount * ends * c_glow[k].z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(world_pos - CAMERA_POSITION_WORLD);
	if (dir.y < -0.02 || strength <= 0.0)
		discard;
	float pa = max(length(fwidth(dir)), 1e-5);
	float ey = max(dir.y, 0.0005);
	vec2 track = vec2(dir.x, -dir.z);   // east, north per km of ray
	float t0 = ray_to(80.0, ey);
	float t1 = ray_to(450.0, ey);
	float dt = (t1 - t0) / float(steps);
	// how far the along-curtain coordinate moves per pixel, at a typical pillar height
	float x_ref = unwarp(foot_point(ray_to(115.0, ey), track, ey)).x;
	float dx_px = max(fwidth(x_ref), 1e-3);
	vec3 light = vec3(0.0);

	for (int k = 0; k < MAX_CURTAINS; k++) {
		if (k >= curtain_count)
			break;
		float w = c_glow[k].y * (1.0 + blur);   // thicker sheets: softer edges
		float ta = t0;
		float ga = offset(k, ta, track, ey, pa);
		vec3 la = vec3(0.0);   // light at ta, carried over from the previous step
		bool has_la = false;
		for (int i = 1; i <= steps; i++) {
			float tb = t0 + dt * float(i);
			float gb = offset(k, tb, track, ey, pa);
			vec3 lb = vec3(0.0);
			bool has_lb = false;
			bool crossing = (ga < 0.0) != (gb < 0.0);
			if (crossing || min(abs(ga), abs(gb)) < 4.0 * w) {
				// Near or inside a sheet: split the step into sub-steps with the exact
				// offset at each, integrate the length of ray inside the sheet's
				// profile per sub-step in closed form, and blend the light at the
				// sub-step ends by closeness. The offset is far from linear where rays
				// graze swirled sheets; refining only here keeps that accurate (no
				// stripes, grain or moire) without paying for it everywhere.
				if (!has_la)
					la = curtain_light(k, ta, track, ey, pa, dx_px);
				float tp = ta;
				float gp = ga;
				vec3 lp = la;
				float wp = exp(-gp * gp / (w * w));
				float sub = dt / float(SUBSAMPLES + 1);
				for (int j = 1; j <= SUBSAMPLES + 1; j++) {
					float tj = j <= SUBSAMPLES ? ta + sub * float(j) : tb;
					float gj = j <= SUBSAMPLES ? offset(k, tj, track, ey, pa) : gb;
					vec3 lj = curtain_light(k, tj, track, ey, pa, dx_px);
					float wj = exp(-gj * gj / (w * w));
					float dg = gj - gp;
					float inside;   // km of ray, weighted by the sheet's profile exp(-(g/w)^2)
					if (abs(dg) < 1e-3 * w)
						inside = sub * 0.5 * (wp + wj);
					else
						inside = abs(sub * w / dg) * 0.8862 * abs(erf_approx(gj / w) - erf_approx(gp / w));
					light += (lp * wp + lj * wj) / max(wp + wj, 1e-6) * min(inside, 25.0);
					tp = tj;
					gp = gj;
					lp = lj;
					wp = wj;
				}
				lb = lp;
				has_lb = true;
			}
			ta = tb;
			ga = gb;
			la = lb;
			has_la = has_lb;
		}
	}

	// structureless glows, marched coarsely (they vary slowly)
	if (red_glow > 0.0 || green_patches > 0.0) {
		float ds = (t1 - t0) / 14.0;
		for (int i = 0; i < 14; i++) {
			float t = t0 + ds * (float(i) + 0.5);
			float h = altitude(t, ey);
			vec2 f = foot_point(t, track, ey);
			float high = smoothstep(220.0, 280.0, h) * (1.0 - smoothstep(380.0, 450.0, h));
			light += RED * red_glow * high * noise2(f / 600.0 + glow_seed + clock * 0.0015) * ds * 0.0013;
			float lowband = smoothstep(95.0, 110.0, h) * (1.0 - smoothstep(120.0, 150.0, h));
			float pulse = 0.6 + 0.4 * sin(clock * 0.35 + noise2(f / 150.0 + glow_seed) * 12.0);
			float patches = noise2(f / 180.0 - glow_seed + clock * 0.002);
			light += GREEN_CYAN * green_patches * lowband * patches * patches * pulse * ds * 0.02;
		}
	}

	light *= exp(-0.06 / max(ey, 0.01)) * gain * strength;   // fades through the thick air low down
	// only genuinely bright light whitens, as the eye and camera see it
	float lum = dot(light, vec3(0.3, 0.55, 0.15));
	light = mix(light, vec3(lum * 1.15), smoothstep(0.6, 2.5, lum) * 0.5);
	light = mix(vec3(dot(light, vec3(0.3, 0.55, 0.15))), light, saturation);
	ALBEDO = light;
	ALPHA = 1.0;
}
