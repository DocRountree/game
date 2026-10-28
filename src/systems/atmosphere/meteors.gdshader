shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// A meteor: a white streak with a rounded, brightest head and a tail that
// fades out. The quad runs tail (UV.x = 0) to head (UV.x = 1).
// INSTANCE_CUSTOM = (brightness, length / width, 0, 0).

varying float brightness;
varying float aspect;

void vertex() {
	brightness = INSTANCE_CUSTOM.r;
	aspect = max(INSTANCE_CUSTOM.g, 1.0);
}

void fragment() {
	// to units of the streak's half-width, with the head a semicircle
	vec2 p = vec2(UV.x * aspect * 2.0, (UV.y - 0.5) * 2.0);
	float head_x = aspect * 2.0 - 1.0;
	vec2 nearest = vec2(clamp(p.x, 0.0, head_x), 0.0);
	float d = length(p - nearest);                    // 0 on the centre line, 1 at the edge
	float along = clamp(p.x / head_x, 0.0, 1.0);
	float radius = mix(0.25, 1.0, along * along);     // the tail tapers to a thread; the head is round
	float body = 1.0 - smoothstep(radius * 0.45, radius, d);
	float tail = pow(along, 1.5);                     // faint at the tail, full at the head
	ALBEDO = vec3(1.0) * brightness * body * tail;
	ALPHA = 1.0;
}
