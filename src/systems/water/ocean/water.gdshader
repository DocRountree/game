shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

// Open-ocean surface. The same Gerstner waves as Ocean.height_at() displace a
// camera-centred mesh; per pixel it adds the analytic wave normal, interactive
// ripples, and detail normal maps that churn in place. Godot's lighting handles the
// sky reflection and sun glints; this shader supplies the light coming up
// through the water (refraction + depth absorption + crest scattering) and foam.

const int NW = 6;
uniform vec4 waves[NW];          // dir.x, dir.z, k, amplitude
uniform vec2 waves2[NW];         // omega, phase
uniform float steepness = 0.8;
uniform float time;
uniform vec3 sun_direction = vec3(0.0, 0.4, 0.9);
uniform vec3 sun_color = vec3(1.0);

uniform sampler2D ripple_tex : filter_linear, repeat_disable;  // r height, g foam
uniform vec3 ripple_rect = vec3(0.0, 0.0, 1.0);                // origin x, origin z, size

group_uniforms detail;
uniform sampler2D detail_a : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_b : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_tile = 19.3;          // meters per texture repeat (odd sizes and angles
                                           // per layer, so their repeats never line up)
uniform float detail_strength = 0.3;
uniform float fine_tile = 4.13;             // meters per repeat of the finest ripple layer
uniform float fine_strength = 0.18;
uniform float fine_fade = 40.0;            // the fine layer fades out by this distance (no sparkle)
uniform float churn_period = 3.0;          // seconds for a detail layer to fade out and re-form
uniform float patch_size = 140.0;          // meters: scale of the slow variation in which layer dominates
uniform sampler2D foam_noise : filter_linear_mipmap, repeat_enable;

group_uniforms water;
uniform vec3 deep_color = vec3(0.004, 0.03, 0.06);
uniform vec3 scatter_color = vec3(0.0, 0.13, 0.14);
uniform vec3 absorption = vec3(0.45, 0.09, 0.06);   // per meter: red goes first
uniform float refraction = 0.03;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec2 x0;          // undisplaced world xz of this vertex
varying float spacing;    // mesh spacing here (m)
varying float crest;      // height above rest

float theta(int i, vec2 p) {
	return waves[i].z * dot(waves[i].xy, p) - waves2[i].x * time + waves2[i].y;
}

// fade out waves too short for the local mesh spacing (no aliasing far away)
float lod(int i, float sp) {
	float lambda = 6.2831853 / waves[i].z;
	return clamp((lambda - 3.0 * sp) / (3.0 * sp), 0.0, 1.0);
}

vec2 rip_uv(vec2 p) { return (p - ripple_rect.xy) / ripple_rect.z; }
float rip_fade(vec2 uv) { vec2 e = min(uv, 1.0 - uv); return clamp(min(e.x, e.y) * 25.0, 0.0, 1.0); }

// Slope from a detail normal map that churns in place instead of scrolling:
// two copies cross-fade, each drifting only a little before it fades out and
// comes back at a fresh random offset. A plain scroll reads as a film sliding
// over the waves; this keeps the ripples attached to the water.
vec2 churn(sampler2D tex, vec2 uv, vec2 drift, float t) {
	vec2 s = vec2(0.0);
	for (int k = 0; k < 2; k++) {
		float phase = t / churn_period + float(k) * 0.5;
		float cycle = floor(phase);
		float f = fract(phase);
		vec2 jump = fract(sin(vec2(cycle * 12.9898 + float(k) * 3.1, cycle * 78.233 + float(k) * 7.7)) * 43758.5453);
		vec3 n = texture(tex, uv + jump + drift * (f - 0.5)).xyz * 2.0 - 1.0;
		s += (1.0 - abs(2.0 * f - 1.0)) * n.xy / max(n.z, 0.2);   // triangle weights sum to 1
	}
	return s * 1.35;   // blending two copies flattens them a little; restore contrast
}

vec2 rot(vec2 p, float a) {
	return vec2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a));
}

float view_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	x0 = world.xz;
	spacing = UV.x;
	vec3 disp = vec3(0.0);
	for (int i = 0; i < NW; i++) {
		float a = waves[i].w * lod(i, spacing);
		float th = theta(i, x0);
		disp.xz += steepness * a * waves[i].xy * cos(th);
		disp.y += a * sin(th);
	}
	vec2 ruv = rip_uv(x0);
	disp.y += texture(ripple_tex, ruv).r * rip_fade(ruv) * clamp(1.5 - spacing * 2.0, 0.0, 1.0);
	crest = disp.y;
	VERTEX += disp;   // the surface node is only ever translated
}

void fragment() {
	// analytic Gerstner normal and Jacobian (GPU Gems 1, ch. 1)
	vec2 slope = vec2(0.0);
	float nz = 1.0, jxx = 1.0, jzz = 1.0, jxz = 0.0;
	for (int i = 0; i < NW; i++) {
		float wa = waves[i].z * waves[i].w * lod(i, spacing);
		float th = theta(i, x0);
		float c = cos(th);
		float s = sin(th);
		slope += waves[i].xy * wa * c;
		nz -= steepness * wa * s;
		jxx -= steepness * wa * waves[i].x * waves[i].x * s;
		jzz -= steepness * wa * waves[i].y * waves[i].y * s;
		jxz -= steepness * wa * waves[i].x * waves[i].y * s;
	}
	slope /= nz;
	float jac = jxx * jzz - jxz * jxz;   // < 1 where crests bunch up

	// interactive ripples
	vec2 ruv = rip_uv(x0);
	float rf = rip_fade(ruv);
	float e = 1.0 / float(textureSize(ripple_tex, 0).x);
	slope += vec2(texture(ripple_tex, ruv + vec2(e, 0.0)).r - texture(ripple_tex, ruv - vec2(e, 0.0)).r,
			texture(ripple_tex, ruv + vec2(0.0, e)).r - texture(ripple_tex, ruv - vec2(0.0, e)).r)
			/ (2.0 * e * ripple_rect.z) * rf;
	float ripple_foam = texture(ripple_tex, ruv).g * rf;

	// small waves: detail normal maps churning in place on the (orbiting) water.
	// x0 is the undisplaced position, so they ride the swell like real ripples.
	// A slow, large noise trades strength between the layers from place to
	// place, so no single repeating pattern dominates the whole sea.
	float patch = texture(foam_noise, x0 / patch_size + vec2(0.37, 0.61)).r;
	float wa = mix(0.45, 1.4, smoothstep(0.25, 0.75, patch));
	float wb = mix(1.4, 0.45, smoothstep(0.3, 0.7, patch));
	slope += detail_strength * (wa * churn(detail_a, rot(x0, 0.83) / detail_tile, vec2(0.04, 0.02), time)
			+ 0.6 * wb * churn(detail_b, rot(x0, 2.37) / (detail_tile * 1.618), vec2(-0.02, 0.035), time + 1.3));
	// finest capillary ripples close up, so the near water isn't smooth blotches
	float fine = fine_strength * (1.0 - smoothstep(fine_fade * 0.3, fine_fade, -VERTEX.z));
	if (fine > 0.0) {
		slope += fine * churn(detail_a, rot(x0, 4.11) / fine_tile, vec2(0.08, -0.05), time * 1.7 + 0.6);
	}

	vec3 n_world = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// light coming up through the water: refracted background, absorbed with depth
	float surface_depth = -VERTEX.z;
	float thickness = max(view_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_depth, 0.0);
	vec2 offset = slope * refraction * clamp(thickness * 0.5, 0.0, 1.0);
	float behind = view_depth(SCREEN_UV + offset, INV_PROJECTION_MATRIX);
	if (behind < surface_depth) {
		offset = vec2(0.0);   // don't refract things in front of the water into it
	} else {
		thickness = behind - surface_depth;
	}
	vec3 background = texture(screen_tex, SCREEN_UV + offset).rgb;
	vec3 transmit = exp(-absorption * thickness);

	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 to_eye = normalize(CAMERA_POSITION_WORLD - world_pos);
	float diffuse = max(dot(n_world, sun_direction), 0.0);
	float toward_sun = max(dot(-to_eye, sun_direction), 0.0);   // light shining through crests
	float crest_t = clamp(crest * 0.5 + 0.3, 0.0, 1.0);
	crest_t *= crest_t;
	vec3 body = deep_color * (0.5 + 0.8 * diffuse)
			+ scatter_color * crest_t * (0.35 + 1.5 * pow(toward_sun, 4.0)) * (0.5 + 0.5 * diffuse);
	body *= 0.12 + 0.88 * sun_color;   // the water body is lit by the (possibly sunset-coloured) sun
	vec3 refracted = background * transmit + body * (1.0 - transmit);

	// foam: crest compression + ripple foam, broken up by noise so it reads as foam
	float f = smoothstep(0.72, 0.55, jac) * 0.6 + ripple_foam * 0.5;   // whitecaps only on the sharpest crests
	float noise = texture(foam_noise, (x0 + vec2(0.2, 0.0) * time) * (2.5 / detail_tile)).r * 0.6
			+ texture(foam_noise, (x0 - vec2(0.0, 0.15) * time) * (5.0 / detail_tile)).r * 0.4;
	float lo = 1.0 - 0.6 * clamp(f, 0.0, 1.0);
	float foam = smoothstep(lo, lo + 0.25, noise) * sqrt(min(f, 1.0));

	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = vec3(0.9) * foam;
	ROUGHNESS = mix(0.03, 0.85, foam);
	SPECULAR = 0.5;
	EMISSION = refracted * (1.0 - fresnel) * (1.0 - foam);
	ALPHA = 1.0;
}
