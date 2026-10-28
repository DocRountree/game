shader_type sky;

// Single-scattering atmosphere after Sebastian Lague's Solar System
// (github.com/SebLague/Solar-System, Atmosphere.shader), reworked as a sky
// shader for a camera standing on the planet.
//
// Everything is in planet-radius units (planet radius = 1). Air density falls
// off as exp(-h * falloff) * (1 - h) with h = height / atmosphere thickness.
// Scattering strength goes as (400 / wavelength)^4, so blue scatters most.
// Sunlight reaching each sample is attenuated by a baked optical-depth lookup
// (no inner ray march). The view ray takes a handful of dithered samples,
// bunched toward the camera where the air is densest, and adds up its own
// optical depth as it goes (Lague subtracts baked values instead; summing is
// exact here and avoids banding with thin atmospheres).
// Parameters are pushed by atmosphere.gd, which also bakes the lookup.

uniform sampler2D optical_depth_lut : filter_linear, repeat_disable;  // optical depth to space: r air, g haze, b high aerosol
uniform vec3 scattering_coefficients = vec3(3.2, 9.73, 20.49);
// Ozone absorbs (mostly orange-green) without scattering: keeps twilight blue
// instead of the olive a pure Rayleigh sky gives. Not in Lague's version.
uniform vec3 ozone_absorption = vec3(0.27, 0.78, 0.04);
// Aerosols (haze): grey, concentrated near the surface, scatter strongly
// forward. They make the warm glow around a low sun. Not in Lague's version.
uniform float mie_scattering = 2.5;
uniform float mie_falloff = 28.0;
uniform float mie_g = 0.74;
// A thin high aerosol layer (stratosphere). Lit by reddened light after the
// sun has set below, seen through blue sky: the pink-purple twilight glow.
uniform float strat_scattering = 0.06;
uniform float strat_height = 0.2;
uniform float strat_width = 0.07;
uniform float strat_g = 0.6;
// Stylised twilight glow (not physical): a rose-violet band above the sunset
// point while the sun is just below the horizon, the "belt" of colour a
// single-scattering model can't produce on its own.
uniform vec3 twilight_tint = vec3(0.85, 0.42, 0.9);
uniform float twilight_glow = 1.0;
uniform float atmosphere_scale = 0.1;     // atmosphere thickness / planet radius
uniform float density_falloff = 4.3;
uniform float intensity = 1.0;
uniform int in_scattering_points = 16;
uniform float dither_strength = 0.35;   // jitters the samples; debanding handles the rest
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.8);
uniform float sun_disc_size = 0.9998;     // cos of the sun's angular radius
uniform float sun_disc_brightness = 8.0;  // low enough that a setting sun can show its colour
uniform vec3 night_sky = vec3(0.001, 0.002, 0.005);
uniform float planet_radius = 6400000.0;

// (distance to sphere, distance through sphere); (1e30, 0) on a miss
vec2 ray_sphere(float radius, vec3 origin, vec3 dir) {
	float b = 2.0 * dot(origin, dir);
	float c = dot(origin, origin) - radius * radius;
	float d = b * b - 4.0 * c;
	if (d > 0.0) {
		float s = sqrt(d);
		float near = max(0.0, (-b - s) / 2.0);
		float far = (-b + s) / 2.0;
		if (far >= 0.0)
			return vec2(near, far - near);
	}
	return vec2(1e30, 0.0);
}

// air (Rayleigh), low haze and high aerosol (Mie) densities
vec3 density_at(vec3 p) {
	float h01 = max((length(p) - 1.0) / atmosphere_scale, 0.0);   // (never below the surface: no overflow)
	float s = (h01 - strat_height) / strat_width;
	return vec3(exp(-h01 * density_falloff), exp(-h01 * mie_falloff), exp(-s * s)) * (1.0 - h01);
}

// optical depths from p to the edge of the atmosphere along dir
vec3 optical_depth_baked(vec3 p, vec3 dir) {
	float h01 = clamp((length(p) - 1.0) / atmosphere_scale, 0.0, 1.0);
	float u = 1.0 - (dot(normalize(p), dir) * 0.5 + 0.5);
	return texture(optical_depth_lut, vec2(u, h01)).rgb;
}

float henyey_greenstein(float g, float mu) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * mu, 1.5);
}

void sky() {
	vec3 dir = EYEDIR;
	// The sea's horizon dips below level the higher you are (the planet curves
	// away): sin(dip) = sqrt(1 - (R / (R + h))^2).
	float rel = planet_radius / (planet_radius + max(POSITION.y, 1.0));
	float horizon_y = -sqrt(max(1.0 - rel * rel, 0.0));
	// The ocean covers everything below the horizon, so look along the horizon
	// instead: reflections and distance haze below it get the horizon colour.
	// (Keeping the ray's heading: a ray straight down has none, so it takes
	// one, or it would stay pointing into the planet.)
	float ylim = horizon_y + 0.0015;
	if (dir.y < ylim) {
		vec2 hd = dir.xz;
		float hl = length(hd);
		hd = hl > 1e-5 ? hd / hl : vec2(1.0, 0.0);
		dir = vec3(hd.x, 0.0, hd.y) * sqrt(1.0 - ylim * ylim) + vec3(0.0, ylim, 0.0);
	}
	dir = normalize(dir);
	vec3 sun = normalize(sun_direction);

	vec3 origin = vec3(0.0, 1.0 + max(POSITION.y, 1.0) / planet_radius, 0.0);
	vec2 hit = ray_sphere(1.0 + atmosphere_scale, origin, dir);
	float through = hit.y;

	float noise = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float n = float(in_scattering_points);
	vec3 air_extinction = scattering_coefficients + ozone_absorption;
	float haze_extinction = mie_scattering * 1.1;
	float strat_extinction = strat_scattering * 1.05;
	vec3 air_light = vec3(0.0);
	vec3 haze_light = vec3(0.0);
	vec3 strat_light = vec3(0.0);
	vec3 view_depth = vec3(0.0);
	for (int i = 0; i < in_scattering_points; i++) {
		float x = (float(i) + 0.5 + (noise - 0.5) * dither_strength) / n;
		float ds = through * 2.0 * x / n;                  // samples at t = through * x^2
		vec3 p = origin + dir * (through * x * x);
		vec3 density = density_at(p);
		view_depth += density * ds * 0.5;                  // midpoint rule
		vec3 depth = optical_depth_baked(p, sun) + view_depth;
		vec3 transmittance = exp(-(depth.x * air_extinction + depth.y * haze_extinction + depth.z * strat_extinction));
		air_light += density.x * transmittance * ds;
		haze_light += density.y * transmittance * ds;
		strat_light += density.z * transmittance * ds;
		view_depth += density * ds * 0.5;
	}
	// phase functions, normalised to average 1 so Lague's brightness calibration holds
	float mu = dot(dir, sun);
	float air_phase = 0.75 * (1.0 + mu * mu);
	vec3 light = (air_light * scattering_coefficients * air_phase
			+ haze_light * mie_scattering * henyey_greenstein(mie_g, mu)
			+ strat_light * strat_scattering * henyey_greenstein(strat_g, mu)) * intensity;

	// twilight glow: strongest with the sun 1-6 degrees down, highest above it
	float sun_down = (1.0 - smoothstep(-0.01, 0.05, sun.y)) * smoothstep(-0.16, -0.05, sun.y);
	if (twilight_glow > 0.0 && sun_down > 0.0) {
		float elevation = asin(clamp(EYEDIR.y, 0.0, 1.0));
		vec2 sun_h = normalize(sun.xz + vec2(1e-5));
		vec2 dir_h = normalize(dir.xz + vec2(1e-5));
		float toward = 0.35 + 0.65 * pow(max(dot(sun_h, dir_h), 0.0), 1.5);
		float band = exp(-pow((elevation - 0.32) / 0.22, 2.0));
		light += twilight_tint * (0.05 * twilight_glow * sun_down * band * toward);
	}

	// the sun itself, dimmed and reddened by the air in front of it
	vec3 view_transmittance = exp(-(view_depth.x * air_extinction + view_depth.y * haze_extinction + view_depth.z * strat_extinction));
	if (!AT_CUBEMAP_PASS && EYEDIR.y > horizon_y - 0.002) {   // (it sets at the true horizon)
		float disc = smoothstep(sun_disc_size - 0.00004, sun_disc_size + 0.00004, mu);
		light += view_transmittance * disc * sun_disc_brightness;
	}

	COLOR = light + night_sky;
}
