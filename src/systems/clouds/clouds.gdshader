shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// Volumetric clouds, ray marched (after Schneider's "Nubis" clouds in Horizon
// Zero Dawn and Hillaire's energy-conserving integration). Two cloud types:
// fair-weather cumulus (1.5-3.6 km) and, on stormy days, scattered
// cumulonimbus: tall towers to ~11 km under flat anvils that spread wider than
// the tower and are blown downwind. Drawn on a dome
// around the camera, after the stars, moon and aurora, so clouds cover them.
//
// The cloud layer is a spherical shell over the real Earth, so it curves away
// and compresses toward the horizon on its own. Density = a 2D coverage map
// (where clouds are) x a height profile (flat bases, rounded tops) x 3D noise
// (billows), eroded at the edges by finer noise. Each sample is lit by sunlight
// traced a few steps toward the sun (self-shadowing), with a two-lobe phase
// function (bright silver linings toward the sun), the "powder" darkening of
// thick cloud edges, and sky light. Output is premultiplied: light added, and
// what is behind dimmed by the transmittance.

uniform sampler3D shape_noise : filter_linear_mipmap, repeat_enable;    // r: billowy fBm
uniform sampler3D detail_noise : filter_linear_mipmap, repeat_enable;   // r: fine cellular
uniform float coverage = 0.45;        // 0 clear .. 1 overcast
uniform float fill = 0.0;             // 0 fair-weather cumulus .. 1 scattered thunderheads (cumulonimbus)
uniform float grey = 0.0;             // darker cloud (thunderhead underbellies)
uniform float base_altitude = 1500.0; // m
uniform float top_altitude = 3600.0;   // fair-weather cumulus tops
uniform float storm_top = 11000.0;     // thunderhead anvils
uniform float storm_scale = 70000.0;   // m: spacing pattern of thunderhead cells
uniform float anvil_shear = 9000.0;    // m: how far anvils are blown downwind at the top
uniform float planet_radius = 6371000.0;
uniform vec2 wind = vec2(7.0, 2.5);   // m/s
uniform float shape_scale = 9000.0;   // m per repeat of the billow noise
uniform float detail_scale = 1400.0;
uniform float map_scale = 26000.0;    // m: size of the coverage pattern
uniform float extinction = 0.045;     // per metre at density 1
uniform int steps = 56;
uniform int light_steps = 5;
uniform float max_distance = 160000.0;   // a layer 1.5 km up is visible ~140 km away, so the deck reaches the horizon
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_colour = vec3(1.0);
uniform vec3 ambient = vec3(0.2, 0.27, 0.4);
uniform float brightness = 1.0;
uniform float dim_start = 0.12;
uniform vec3 flash_pos = vec3(0.0);
uniform float flash = 0.0;

varying vec3 world_pos;

float remap(float v, float a, float b, float c, float d) {
	return c + (v - a) / max(b - a, 1e-4) * (d - c);
}

// distance along a ray from height above the planet's surface to a sphere of radius r
vec2 sphere_hits(float cam_h, float ey, float r) {
	float o = planet_radius + cam_h;
	float b = o * ey;
	float c = o * o - r * r;
	float disc = b * b - c;
	if (disc < 0.0)
		return vec2(-1.0);
	float s = sqrt(disc);
	return vec2(-b - s, -b + s);
}

float height_at(float cam_h, float ey, float t) {
	float o = planet_radius + cam_h;
	return sqrt(o * o + 2.0 * o * t * ey + t * t) - planet_radius;
}

float layer_top() {
	return mix(top_altitude, storm_top, fill);
}

// fair-weather cumulus: where they are (two octaves of the billow noise, as 2D)
float cumulus_cover(vec2 xz) {
	vec2 m = (xz + wind * TIME) / map_scale;
	float map = texture(shape_noise, vec3(m, 0.37)).r * 0.65 + texture(shape_noise, vec3(m * 2.7, 0.71)).r * 0.35;
	return clamp(remap(map, 1.0 - coverage * 1.1, 1.0, 0.0, 1.0), 0.0, 1.0);
}

// thunderhead cells: sparse, from a very low-frequency read of the noise. At
// height, the anvil is read from upwind (so it is blown downwind) and from a
// lower threshold (so it spreads wider than the tower).
float storm_cell(vec2 xz, float spread, float shift) {
	vec2 dirw = normalize(wind + vec2(1e-4));
	vec2 m = (xz - dirw * shift + wind * TIME) / storm_scale;
	float c = texture(shape_noise, vec3(m, 0.53)).r;
	return clamp(remap(c, mix(0.74, 0.56, spread), 0.9, 0.0, 1.0), 0.0, 1.0);
}

// whether any cloud can be here (cheap): for empty-space skipping
float cover_at(vec2 xz, float h) {
	float c = fill < 1.0 ? cumulus_cover(xz) * (1.0 - fill) : 0.0;
	if (fill > 0.0) {
		float hf = clamp((h - base_altitude) / (storm_top - base_altitude), 0.0, 1.0);
		c = max(c, storm_cell(xz, smoothstep(0.7, 0.85, hf), anvil_shear * hf * hf) * fill);
	}
	return c;
}

float cumulus(vec3 q, float h) {
	float hf = (h - base_altitude) / (top_altitude - base_altitude);
	if (hf <= 0.0 || hf >= 1.0)
		return 0.0;
	float cover = cumulus_cover(q.xz);
	if (cover <= 0.0)
		return 0.0;
	// flat base, rounded top that rises where clouds are dense
	float profile = smoothstep(0.0, 0.08, hf) * (1.0 - smoothstep(0.35, 1.0, hf / max(cover, 0.2)));
	float shape = texture(shape_noise, (q + vec3(wind.x, 0.0, wind.y) * TIME) / shape_scale).r;
	return clamp(remap(shape * profile, 1.0 - cover, 1.0, 0.0, 1.0), 0.0, 1.0) * cover;
}

float thunderhead(vec3 q, float h) {
	float hf = (h - base_altitude) / (storm_top - base_altitude);
	if (hf <= 0.0 || hf >= 1.0)
		return 0.0;
	vec3 drift = vec3(wind.x, 0.0, wind.y) * TIME;
	float shape = texture(shape_noise, (q + drift) / (shape_scale * 1.4)).r;
	// the tower: a billowing column from the flat base, narrowing a little as it rises
	float core = storm_cell(q.xz, 0.0, anvil_shear * hf * hf * 0.3);
	float tower = clamp(remap(shape, 1.0 - core * (1.0 - 0.25 * hf), 1.0, 0.0, 1.0), 0.0, 1.0)
			* smoothstep(0.0, 0.03, hf) * (1.0 - smoothstep(0.84, 0.93, hf));
	// the anvil: a wide, flat, smoother sheet spreading at the top, blown downwind
	float spread = storm_cell(q.xz, 1.0, anvil_shear * hf * hf);
	float band = smoothstep(0.76, 0.84, hf) * (1.0 - smoothstep(0.93, 0.99, hf));
	float anvil = clamp(remap(shape * 0.5 + 0.5, 1.0 - spread, 1.0, 0.0, 1.0), 0.0, 1.0) * band * 0.7;
	return max(tower, anvil);
}

float density(vec3 p, float h, bool cheap) {
	float d = 0.0;
	if (fill < 1.0)
		d = cumulus(p, h) * (1.0 - fill);
	if (fill > 0.0)
		d = max(d, thunderhead(p, h) * fill);
	if (d <= 0.0 || cheap)
		return d;
	// erode the edges with fine noise: wispy at the base, billowy higher up
	vec3 drift = vec3(wind.x, 0.0, wind.y) * TIME;
	float detail = texture(detail_noise, (p + drift * 1.3) / detail_scale).r;
	float hf = clamp((h - base_altitude) / 2000.0, 0.0, 1.0);
	float erode = mix(detail, 1.0 - detail, hf) * 0.35;
	return clamp(remap(d, erode, 1.0, 0.0, 1.0), 0.0, 1.0);
}

float hg(float g, float mu) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * mu, 1.5));
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 dir = normalize(world_pos - cam);
	if (coverage <= 0.001 || dir.y < -0.02)
		discard;
	float ey = dir.y;
	float cam_h = max(cam.y, 1.0);
	float top = layer_top();
	vec2 inner = sphere_hits(cam_h, ey, planet_radius + base_altitude);
	vec2 outer = sphere_hits(cam_h, ey, planet_radius + top);
	float t0 = max(inner.y, 0.0);
	float t1 = min(outer.y, max_distance);
	if (outer.y <= 0.0 || t1 <= t0)
		discard;
	vec3 sun = normalize(sun_direction);
	float mu = dot(dir, sun);
	float phase = mix(hg(0.75, mu), hg(-0.25, mu), 0.35) * 4.0 * PI * 0.6 + 0.25;
	// sunlight fades as the planet's shadow climbs through the layer
	float dip = sqrt(2.0 * base_altitude / planet_radius);
	float lit = smoothstep(0.0, 1.0, clamp((sun.y + dip) / (dim_start + dip), 0.0, 1.0));
	vec3 sunlight = sun_colour * lit;
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float span = t1 - t0;
	float dt = span / float(steps);
	float t = t0 + dt * jitter;
	float trans = 1.0;
	vec3 light = vec3(0.0);
	int budget = steps * 3;   // empty stretches are skipped in long strides
	for (int i = 0; i < budget && t < t1; i++) {
		vec3 p = cam + dir * t;
		// empty-space skipping: where the coverage map says no cloud, stride on
		// (cheap 2D lookups only); the full 3D noise and light march run only
		// inside clouds
		if (cover_at(p.xz, height_at(cam_h, ey, t)) <= 0.0) {
			t += dt * 2.5;
			continue;
		}
		float h = height_at(cam_h, ey, t);
		float d = density(p, h, false);
		if (d > 0.002) {
			// light march toward the sun
			float od = 0.0;
			float ls = 90.0;
			vec3 lp = p;
			for (int j = 0; j < light_steps; j++) {
				lp += sun * ls;
				od += density(lp, lp.y + h - p.y, j > 2) * ls;
				ls *= 1.8;
			}
			float tl = exp(-od * extinction * 0.9);
			float powder = 1.0 - exp(-d * dt * extinction * 2.0);
			vec3 direct = sunlight * phase * tl * mix(0.6, 1.0, powder);
			float hf = clamp((h - base_altitude) / (top - base_altitude), 0.0, 1.0);
			vec3 sky = ambient * mix(0.45, 1.25, hf);
			vec3 fd = p - flash_pos;
			vec3 bolt = vec3(0.8, 0.85, 1.0) * flash * 6.0 * exp(-dot(fd, fd) / (2600.0 * 2600.0));
			vec3 s = (direct + sky + bolt) * brightness * mix(1.0, 0.55, grey);
			float sigma = d * extinction;
			float step_t = exp(-sigma * dt);
			light += trans * s * (1.0 - step_t);
			trans *= step_t;
			if (trans < 0.01)
				break;
		}
		t += dt;
	}
	// distant cloud takes on the colour of the haze toward the horizon (it
	// stays opaque: haze tints what is behind it, it doesn't make it see-through)
	float haze = 1.0 - exp(-t0 / 45000.0);
	ALBEDO = mix(light, ambient * 1.2 * (1.0 - trans), haze * 0.6);
	ALPHA = 1.0 - trans;
}
