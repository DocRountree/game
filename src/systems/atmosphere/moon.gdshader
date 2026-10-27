shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// The moon as a lit sphere on a camera-facing disc. The phase is just the
// terminator where the sun's light falls on the sphere. Premultiplied
// blending: by day (alpha 0) it adds to the sky; at night (alpha 1) it covers
// the stars, its dark side faintly lit by earthshine.

uniform vec3 sun_local = vec3(1.0, 0.0, 0.0);   // sun direction in the disc's frame (x right, y up, z to the camera)
uniform float night = 0.0;                      // 0 by day, 1 at night
uniform float day_brightness = 0.35;
uniform float night_brightness = 1.6;

varying vec2 q;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	q = VERTEX.xy * 2.0;   // the quad spans -0.5..0.5
}

void fragment() {
	float r2 = dot(q, q);
	if (r2 > 1.0)
		discard;
	vec3 n = vec3(q, sqrt(1.0 - r2));
	float lit = smoothstep(-0.04, 0.06, dot(n, normalize(sun_local)));
	// dark "seas" (maria): a fixed noise pattern on the sphere
	float maria = noise(n * 2.6 + 3.1) * 0.65 + noise(n * 6.0) * 0.35;
	float albedo = mix(0.58, 1.0, smoothstep(0.42, 0.6, maria));
	float limb = mix(0.78, 1.0, n.z);
	float edge = 1.0 - smoothstep(0.94, 1.0, r2);
	float brightness = mix(day_brightness, night_brightness, night);
	vec3 colour = vec3(1.0, 0.97, 0.92) * albedo * limb * (lit * brightness + 0.012 * night);
	ALBEDO = colour * edge;
	// The dark side blocks the stars behind it, but the twilight sky glows in
	// front of the moon, so it only blocks once the sky is fully dark
	ALPHA = edge * smoothstep(0.85, 1.0, night);
}
