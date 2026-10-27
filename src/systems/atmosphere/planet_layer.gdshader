shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// Planets: small coloured discs a few pixels across, added over the sky like
// the stars, but steady (an extended disc doesn't twinkle) and drawn on the
// moon's layer. COLOR.rgb = colour; INSTANCE_CUSTOM = (brightness, size px, 0, 0).

uniform float visibility = 0.0;        // 0 by day, 1 once the sun is well below the horizon
uniform float pixel_angle = 0.0012;    // radians per screen pixel

varying vec3 colour;
varying vec2 quad;

void vertex() {
	vec3 dir = normalize((MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz - CAMERA_POSITION_WORLD);
	vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec2 offset = VERTEX.xy * INSTANCE_CUSTOM.g;
	POSITION = PROJECTION_MATRIX * vec4(centre + vec3(offset * pixel_angle * length(centre), 0.0), 1.0);
	colour = COLOR.rgb * INSTANCE_CUSTOM.r * visibility * step(0.0, dir.y);   // hidden below the horizon
	quad = VERTEX.xy;
	POSITION.z = POSITION.w * 1e-6;   // at the far plane: anything in the world draws in front of the sky
}

void fragment() {
	float r = length(quad) * 2.0;   // 0 at the centre, 1 at the quad's edge
	ALBEDO = colour;
	ALPHA = 1.0 - smoothstep(0.6, 1.0, r);
}
