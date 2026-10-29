// The optics every body of water shares (water.gdshader for the sea,
// river.gdshader for the rivers): light coming up through the water is what
// lies behind it (the screen, refracted by the surface's slope, never pulling
// in things in front of the water), dimmed by Beer-Lambert absorption over
// the water it crosses and filled in by the water's own body colour; light
// off the surface is Godot's (sky reflection and sun glints) by Schlick's
// Fresnel. Each body supplies its own colours, absorption and normals.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

// Linear view depth (m) of the depth buffer at a screen point.
float water_view_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 p = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -p.z / p.w;
}

// Whether there is a depth buffer to read (with MSAA there isn't).
bool water_has_depth(vec2 uv) {
	return texture(depth_tex, uv).r > 0.0;
}

// The background seen through the water at screen_uv, its screen offset
// (from the surface's horizontal slope) and the thickness of water crossed
// (m, along the view) written to `thickness`.
vec3 water_background(vec2 screen_uv, vec2 slope, float strength, float surface_depth, mat4 inv_proj, out float thickness) {
	thickness = max(water_view_depth(screen_uv, inv_proj) - surface_depth, 0.0);
	vec2 offset = slope * strength * clamp(thickness * 0.5, 0.0, 1.0);
	float behind = water_view_depth(screen_uv + offset, inv_proj);
	if (behind < surface_depth)
		offset = vec2(0.0);   // (nothing in front of the water refracted into it)
	else
		thickness = behind - surface_depth;
	return texture(screen_tex, screen_uv + offset).rgb;
}

// Schlick's Fresnel for water (F0 = 0.02).
float water_fresnel(vec3 normal, vec3 view) {
	return 0.02 + 0.98 * pow(1.0 - clamp(dot(normal, view), 0.0, 1.0), 5.0);
}
