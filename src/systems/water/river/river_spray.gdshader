shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, specular_disabled;

// Splash and mist at a riser's foot (RiverSpray): each instance a quad that
// faces the camera and flies through its own cycle, over and over, each time a
// little differently. INSTANCE_CUSTOM: a random seed, the riser's height (m),
// the kind (0 spray, 1 mist) and a size factor. Its transform's origin is
// where it starts (on the water at the foot), its z axis downstream.
//   spray: a clump of droplets thrown up and out, falling back under gravity,
//          breaking up as it goes (higher below a taller riser);
//   mist:  a soft puff rising and drifting away downstream, growing as it
//          thins out.
// Lit as a translucent white: from all round, brighter seen against the sun.
// Soft where it meets the ground, gone below the water it rose from, and
// fading out far off.

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying float alpha_k;
varying float kind;
varying float age;
varying vec2 seed2;
varying float water_y;
varying float world_y;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	float seed = c.x;
	float h = min(c.y, 14.0);
	kind = c.z;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 side = normalize(MODEL_MATRIX[0].xyz);
	vec3 fwd = normalize(MODEL_MATRIX[2].xyz);
	float life = kind < 0.5 ? mix(0.7, 1.1, fract(seed * 7.3)) : mix(4.0, 6.5, fract(seed * 3.1));
	float cyc = TIME / life + seed;
	age = fract(cyc);
	float n = floor(cyc);   // (which burst: each a little different)
	float r1 = hash12(vec2(n, seed * 91.0));
	float r2 = hash12(vec2(seed * 37.0, n));
	float t = age * life;
	vec3 pos;
	float size;
	if (kind < 0.5) {
		float up = (1.8 + 0.4 * h) * mix(0.7, 1.2, r1);
		float out_ = mix(0.5, 2.0, r2);
		pos = origin + fwd * out_ * t + side * (r1 - 0.5) * 1.2 * t + vec3(0.0, up * t - 4.9 * t * t, 0.0);
		pos.y = max(pos.y, origin.y - 0.2);
		size = mix(0.6, 1.6 + 0.12 * h, age) * c.w;
		alpha_k = smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.45, 1.0, age)) * 0.7;
	} else {
		pos = origin + fwd * 0.9 * t + side * (r1 - 0.5) * 0.6 * t + vec3(0.0, 0.4 + 0.35 * t, 0.0);
		size = mix(2.0, 4.0 + 0.7 * h, age) * c.w;
		alpha_k = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.4, 1.0, age)) * clamp(h / 6.0, 0.3, 1.0) * 0.35;
	}
	alpha_k *= 1.0 - smoothstep(350.0, 700.0, distance(pos, INV_VIEW_MATRIX[3].xyz));
	vec3 world = pos + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
	water_y = origin.y;
	world_y = world.y;
	seed2 = vec2(seed * 17.0 + n * 0.37, r2 * 5.0);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r = length(q);
	float blob;
	if (kind < 0.5) {
		// a clump of droplets, breaking up as it flies: grainy, a soft veil
		// of fine spray round a denser core
		float nz = vnoise(q * 3.0 + seed2 * 7.0) * 0.45 + vnoise(q * 8.0 + seed2 * 3.0) * 0.3 + vnoise(q * 19.0 + seed2) * 0.25;
		float core = smoothstep(0.25 + 0.35 * age, 0.8, nz + 0.4 * (1.0 - r));
		blob = smoothstep(1.0, 0.0, r) * mix(0.25 * smoothstep(0.3, 0.7, nz), 1.0, core);
	} else {
		float nz = vnoise(q * 2.0 + seed2 * 5.0 + TIME * 0.1) * 0.6 + vnoise(q * 4.5 + seed2) * 0.4;
		blob = smoothstep(1.0, 0.0, r) * (0.5 + 0.7 * nz);
	}
	// soft where it meets the ground; gone below the water it rose from
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	float scene = -sp.z / sp.w;
	float soft = clamp((scene + VERTEX.z) / (kind < 0.5 ? 0.4 : 1.5), 0.0, 1.0);
	ALBEDO = vec3(0.95);
	ROUGHNESS = 1.0;
	ALPHA = clamp(blob * alpha_k * soft * smoothstep(water_y - 0.2, water_y + 0.5, world_y), 0.0, 1.0);
}

void light() {
	// translucent: lit from all round, brighter looking toward the light
	float wrap = 0.55 + 0.45 * max(dot(NORMAL, LIGHT), 0.0);
	float forward = pow(max(dot(-VIEW, LIGHT), 0.0), 6.0);
	DIFFUSE_LIGHT += (wrap + 1.2 * forward) * ATTENUATION * LIGHT_COLOR / PI;
}
