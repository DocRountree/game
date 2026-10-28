shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// The night sky, drawn additively over the atmosphere. Daylight drowns it out
// on its own. At night nothing is dimmed by the air, right down to the horizon:
// the atmosphere shows only as a slight shimmer, stronger through more air.
//   kind 0 star:   white point, same size for all; brightness only. A very
//                  slight positional wobble (seeing), stronger through more air.
//   kind 2 deep-sky object: grey soft ellipse at its true angular size; the
//                  instance basis carries its axes.
// COLOR.rgb = colour; INSTANCE_CUSTOM = (brightness, kind, size px, 0).

uniform float visibility = 0.0;        // 0 by day, 1 once the sun is well below the horizon
uniform float pixel_angle = 0.0012;    // radians per screen pixel
uniform float wobble_px = 0.12;        // seeing at the zenith, in pixels

varying vec3 colour;
varying vec2 quad;
varying flat int kind;

void vertex() {
	kind = int(INSTANCE_CUSTOM.g + 0.5);
	vec3 dir = normalize((MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz - CAMERA_POSITION_WORLD);
	if (kind == 2) {
		POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX.xy, 0.0, 1.0));
	} else {
		vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec2 offset = VERTEX.xy * INSTANCE_CUSTOM.b;
		if (kind == 0) {
			float id = float(INSTANCE_ID);
			float air = inversesqrt(clamp(dir.y, 0.05, 1.0));   // ~sqrt(airmass)
			offset += vec2(sin(TIME * 9.0 + id * 1.7) + 0.6 * sin(TIME * 23.0 + id * 4.1),
					cos(TIME * 11.0 + id * 2.3) + 0.6 * cos(TIME * 19.0 + id * 3.3)) * wobble_px * air;
		}
		POSITION = PROJECTION_MATRIX * vec4(centre + vec3(offset * pixel_angle * length(centre), 0.0), 1.0);
	}
	colour = COLOR.rgb * INSTANCE_CUSTOM.r * visibility * step(0.0, dir.y);   // hidden only below the horizon
	quad = VERTEX.xy;
	POSITION.z = POSITION.w * 1e-6;   // at the far plane: anything in the world draws in front of the sky
}

void fragment() {
	float r = length(quad) * 2.0;    // 0 at the centre, 1 at the quad's edge
	float a;
	if (kind == 2)
		a = exp(-r * r * 4.8);                // soft glow, object edge at r = 0.5
	else
		a = exp(-r * r * 5.0);                // a point
	ALBEDO = colour;
	ALPHA = a;
}
