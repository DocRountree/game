shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// Aurora curtains on an arc over the northern horizon. UV.x runs along the arc,
// UV.y from the horizon up. A few curtains, each a wavy lower edge that folds
// and drifts, with fine vertical rays shimmering along it; green where the
// glow is brightest (the lower edge), shading through teal to violet-red above.

uniform float strength = 0.0;
uniform vec3 low_color = vec3(0.15, 1.0, 0.35);
uniform vec3 high_color = vec3(0.55, 0.15, 0.6);

float hash(float x) { return fract(sin(x * 127.1) * 43758.5453); }

float noise(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

void fragment() {
	float u = UV.x;
	float v = UV.y;
	float t = TIME;
	vec3 glow = vec3(0.0);
	for (int c = 0; c < 3; c++) {
		float fc = float(c);
		// the curtain's lower edge: slow folds drifting along the arc
		float edge = 0.12 + 0.12 * fc + 0.06 * sin(u * (7.0 + 3.0 * fc) + t * (0.15 + 0.05 * fc) + fc * 2.1)
				+ 0.04 * sin(u * 23.0 - t * 0.4 + fc);
		float above = v - edge;
		if (above < -0.02)
			continue;
		// bright just above the edge, fading upward over a tall curtain
		float profile = smoothstep(-0.02, 0.02, above) * exp(-max(above, 0.0) * (4.5 + fc));
		// vertical rays shimmering along it
		float rays = 0.45 + 0.55 * noise(u * 260.0 + fc * 40.0 + t * 0.6) * noise(u * 90.0 - t * 0.3 + fc * 13.0);
		// each curtain waxes and wanes along its length
		float patchy = smoothstep(0.2, 0.8, noise(u * 6.0 + fc * 5.0 + t * 0.05));
		vec3 col = mix(low_color, high_color, smoothstep(0.0, 0.35, above));
		glow += col * profile * rays * patchy * (1.0 - 0.3 * fc);
	}
	float ends = smoothstep(0.0, 0.15, u) * smoothstep(1.0, 0.85, u)   // fade at the arc's ends
			* smoothstep(1.0, 0.55, v);                                  // and well before its top
	float pulse = 0.75 + 0.25 * sin(t * 0.21) * sin(t * 0.13 + 1.0);
	ALBEDO = glow * ends * pulse * strength * 0.18;
	ALPHA = 1.0;
}
