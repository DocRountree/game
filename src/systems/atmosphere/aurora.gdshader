shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// Aurora on an arc over the northern horizon. UV.x runs along the arc, UV.y
// from the horizon up. Two kinds of structure, mixed per night and drifting
// over the night (all from uniforms set by aurora.gd, plus slow time noise):
//   ripples: curtains whose lower edge folds and drifts, with fine rays
//   pillars: separate columns of rays standing up from a lower band
// Green where the glow is brightest (the lower edge), shading to violet above.

uniform float strength = 0.0;
uniform float ripples = 1.0;      // weight of folding curtains
uniform float pillars = 0.0;      // weight of ray columns
uniform float bands = 2.0;        // 1..3 curtains
uniform float base_height = 0.12; // lower edge of the first band (0..1 of the arc's height)
uniform float fold_scale = 1.0;   // how tightly the curtains fold
uniform float drift = 1.0;        // how fast everything moves
uniform float seed = 0.0;
uniform vec3 low_color = vec3(0.25, 0.92, 0.42);
uniform vec3 high_color = vec3(0.52, 0.25, 0.56);

float hash(float x) { return fract(sin(x * 127.1 + seed * 31.7) * 43758.5453); }

float noise(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

void fragment() {
	float u = UV.x;
	float v = UV.y;
	float t = TIME * drift;
	// the display evolves over minutes: the mix of structure and its activity wander
	float slow = noise(TIME * 0.008 + 3.0);
	float rip_w = ripples * mix(0.4, 1.3, noise(TIME * 0.011 + 7.0));
	float pil_w = pillars * mix(0.4, 1.3, noise(TIME * 0.009 + 11.0));
	float surge = 1.0 + 0.8 * smoothstep(0.75, 0.95, noise(TIME * 0.02 + 19.0));   // brief brightenings
	vec3 glow = vec3(0.0);
	for (int c = 0; c < 3; c++) {
		float fc = float(c);
		if (fc >= bands)
			break;
		float folds = fold_scale * (6.0 + 3.0 * fc) * mix(0.7, 1.4, slow);
		float edge = base_height + 0.11 * fc + 0.06 * sin(u * folds + t * (0.15 + 0.05 * fc) + fc * 2.1 + seed)
				+ 0.04 * sin(u * folds * 3.3 - t * 0.4 + fc);
		float above = v - edge;
		if (above < -0.02)
			continue;
		vec3 col = mix(low_color, high_color, smoothstep(0.0, 0.35, above));
		float patchy = smoothstep(0.2, 0.8, noise(u * 6.0 + fc * 5.0 + t * 0.05));
		// ripples: a curtain, bright just above its edge and fading up, with fine rays
		float sheet = smoothstep(-0.02, 0.02, above) * exp(-max(above, 0.0) * (4.5 + fc));
		float fine = 0.45 + 0.55 * noise(u * 260.0 + fc * 40.0 + t * 0.6) * noise(u * 90.0 - t * 0.3 + fc * 13.0);
		// pillars: narrow columns of rays standing tall, each flickering on its own
		float col_id = floor(u * 70.0 + fc * 17.0);
		float column = pow(noise(u * 70.0 + fc * 17.0 + 0.3 * sin(t * 0.2 + col_id)), 6.0)
				* (0.5 + 0.5 * sin(t * (0.5 + hash(col_id)) + col_id));
		float tall = smoothstep(-0.02, 0.02, above) * exp(-max(above, 0.0) * (1.6 + fc));
		float shape = rip_w * sheet * fine + pil_w * tall * column * 2.5;
		glow += col * shape * patchy * (1.0 - 0.3 * fc);
	}
	float ends = smoothstep(0.0, 0.15, u) * smoothstep(1.0, 0.85, u)   // fade at the arc's ends
			* smoothstep(1.0, 0.55, v);                                  // and well before its top
	float pulse = 0.75 + 0.25 * sin(TIME * 0.21) * sin(TIME * 0.13 + 1.0);
	ALBEDO = glow * ends * pulse * surge * strength * 0.15;
	ALPHA = 1.0;
}
