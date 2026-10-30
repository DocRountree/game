shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

// Open-ocean surface. The same Gerstner waves as Ocean.height_at() displace a
// camera-centred mesh; per pixel it adds the analytic wave normal, interactive
// ripples, and FFT small waves. Godot's lighting handles the
// sky reflection and sun glints; this shader supplies the light coming up
// through the water (refraction + depth absorption + crest scattering).

const int NW = 6;
uniform vec4 waves[NW];          // dir.x, dir.z, k, amplitude
uniform vec2 waves2[NW];         // omega, phase
uniform float steepness = 0.8;
uniform float time;
#include "res://src/systems/rendering/world_globals.gdshaderinc"

uniform sampler2D ripple_tex : filter_linear, repeat_disable;  // r height
uniform vec3 ripple_rect = vec3(0.0, 0.0, 1.0);                // origin x, origin z, size

group_uniforms detail;
// Small waves: slopes from the FFT ocean (OceanFFT), three cascades of
// different tile sizes. Mipmapped, so distant water averages instead of sparkling.
uniform sampler2D fft_0 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fft_1 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fft_2 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 fft_sizes = vec3(97.0, 13.7, 2.31);   // tile size (m) per cascade
uniform float detail_strength = 1.0;

group_uniforms water;
uniform vec3 deep_color = vec3(0.004, 0.03, 0.06);
uniform vec3 scatter_color = vec3(0.0, 0.13, 0.14);
uniform vec3 absorption = vec3(0.45, 0.09, 0.06);   // per meter: red goes first
uniform float refraction = 0.03;
#include "res://src/systems/water/water_core.gdshaderinc"

group_uniforms shore;
// The terrain's height map (Terrain: 16-bit heights in two R8 textures, as
// terrain.gdshader reads them): waves shrink as the water shoals and fade out
// at the shore.
uniform sampler2D height_hi : filter_nearest, repeat_disable;
uniform sampler2D height_lo : filter_nearest, repeat_disable;
uniform float world_size = 10240.0;
uniform int texels = 4096;
uniform float h_min = -300.0;
uniform float h_scale = 0.0213623;
uniform bool has_seabed = false;
// Where the rivers' water stands above the sea (WorldData.river_mask(): the
// level, 0..2 m as 0..1): the sea isn't drawn under it, and fades out where
// a river comes down to meet it.
uniform sampler2D river_mask : filter_linear, repeat_disable;
uniform bool has_river_mask = false;

group_uniforms body;
uniform float swell_scale = 1.0;
uniform float surface_level = 0.0;

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

float water_depth(vec2 p) {
	if (!has_seabed)
		return 1000.0;
	// mip 2 (10 m), bilinear
	vec2 g = ((p + world_size * 0.5) / (world_size / float(texels)) - 1.5) / 4.0;
	vec2 i = floor(g);
	vec2 f = g - i;
	ivec2 c = ivec2(i);
	int n = (texels >> 2) - 1;
	float h[4];
	for (int k = 0; k < 4; k++) {
		ivec2 q = clamp(c + ivec2(k & 1, k >> 1), ivec2(0), ivec2(n));
		h[k] = (round(texelFetch(height_hi, q, 2).r * 255.0) * 256.0 + round(texelFetch(height_lo, q, 2).r * 255.0)) * h_scale + h_min;
	}
	return surface_level - mix(mix(h[0], h[1], f.x), mix(h[2], h[3], f.x), f.y);
}

// waves feel the bottom in water shallower than about a third of their length
float shoal(int i, float depth) {
	float lambda = 6.2831853 / waves[i].z;
	return swell_scale * smoothstep(0.0, 0.35 * lambda, depth);
}

vec2 rip_uv(vec2 p) { return (p - ripple_rect.xy) / ripple_rect.z; }
float rip_fade(vec2 uv) { vec2 e = min(uv, 1.0 - uv); return clamp(min(e.x, e.y) * 25.0, 0.0, 1.0); }

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	x0 = world.xz;
	spacing = UV.x;
	vec3 disp = vec3(0.0);
	float depth = water_depth(x0);
	for (int i = 0; i < NW; i++) {
		float a = waves[i].w * lod(i, spacing) * shoal(i, depth);
		float th = theta(i, x0);
		disp.xz += steepness * a * waves[i].xy * cos(th);
		disp.y += a * sin(th);
	}
	vec2 ruv = rip_uv(x0);
	disp.y += texture(ripple_tex, ruv).r * rip_fade(ruv) * clamp(1.5 - spacing * 2.0, 0.0, 1.0);
	crest = disp.y;
	// the planet curves away: far water sinks toward the true horizon
	disp.y -= planet_drop(world.xz);
	VERTEX += disp;   // the surface node is only ever translated
}

void fragment() {
	float depth = water_depth(x0);
	// analytic Gerstner normal (GPU Gems 1, ch. 1)
	vec2 slope = vec2(0.0);
	float nz = 1.0;
	for (int i = 0; i < NW; i++) {
		float wa = waves[i].z * waves[i].w * lod(i, spacing) * shoal(i, depth);
		float th = theta(i, x0);
		float c = cos(th);
		float s = sin(th);
		slope += waves[i].xy * wa * c;
		nz -= steepness * wa * s;
	}
	slope /= nz;

	// interactive ripples
	vec2 ruv = rip_uv(x0);
	float rf = rip_fade(ruv);
	float e = 1.0 / float(textureSize(ripple_tex, 0).x);
	slope += vec2(texture(ripple_tex, ruv + vec2(e, 0.0)).r - texture(ripple_tex, ruv - vec2(e, 0.0)).r,
			texture(ripple_tex, ruv + vec2(0.0, e)).r - texture(ripple_tex, ruv - vec2(0.0, e)).r)
			/ (2.0 * e * ripple_rect.z) * rf;

	// small waves: FFT ocean slopes, attached to the water (x0 rides the swell)
	slope += detail_strength * smoothstep(0.0, 0.5, depth) * (texture(fft_0, x0 / fft_sizes.x).rg + texture(fft_1, x0 / fft_sizes.y).rg
			+ texture(fft_2, x0 / fft_sizes.z).rg);

	vec3 n_world = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// light coming up through the water: refracted background, absorbed with depth
	float thickness;
	vec3 background = water_background(SCREEN_UV, slope, refraction, -VERTEX.z, INV_PROJECTION_MATRIX, thickness);
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

	float fresnel = water_fresnel(NORMAL, VIEW);
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.03;
	SPECULAR = 0.5;
	EMISSION = refracted * (1.0 - fresnel);
	ALPHA = 1.0;
	if (has_river_mask)
		ALPHA = 1.0 - smoothstep(0.35, 0.9, texture(river_mask, x0 / world_size + 0.5).r);
	if (ALPHA < 0.02)
		discard;   // (it writes depth: none where it isn't)
}
