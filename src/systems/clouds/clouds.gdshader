shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// Puffy dot clouds. One camera-facing disc per puff, shaded as a sphere.
// INSTANCE_CUSTOM = (cloud site x, site z, cloud seed, formation order 0..1);
// COLOR.r = height within the cloud; the instance basis scale is the puff radius.
// Puffs appear and vanish by growing and shrinking (never fading), so they can
// stay crisp, opaque dots with correct overlap.

uniform float area = 24000.0;
uniform float altitude = 1300.0;
uniform vec2 wind = vec2(7.0, 2.5);
uniform float life_seconds = 150.0;
uniform float coverage = 0.6;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_colour = vec3(1.0);   // sunlight as it reaches the clouds
uniform vec3 ambient = vec3(0.2, 0.27, 0.4);
uniform float brightness = 1.5;
uniform float depth_squeeze = 2200.0;   // puffs end up within this distance (stars sit at 2500 m)

varying vec2 q;
varying float height;

float hash(float x) {
	return fract(sin(x * 12.9898) * 43758.5453);
}

void vertex() {
	vec2 site0 = INSTANCE_CUSTOM.xy;
	float seed = INSTANCE_CUSTOM.z;
	float order = INSTANCE_CUSTOM.w;
	vec2 cam = CAMERA_POSITION_WORLD.xz;
	// drift with the wind; the layer wraps around the camera
	vec2 site = mod(site0 + wind * TIME - cam + area * 0.5, area) - area * 0.5 + cam;

	// life cycle: condense, mature, evaporate; each cycle gets a fresh strength,
	// and some cycles never form at all
	float cycle = TIME / life_seconds + seed * 13.0;
	float phase = fract(cycle);
	float roll = hash(floor(cycle) + seed * 97.0);
	float strength = roll < coverage ? mix(0.55, 1.0, roll / coverage) : 0.0;
	float water = smoothstep(0.0, 0.4, phase) * (1.0 - smoothstep(0.6, 1.0, phase)) * strength;
	// base puffs condense first; the tower builds last and evaporates first
	float grow = clamp((water * 1.15 - order * 0.9) / 0.18, 0.0, 1.0);
	// shrink away near the wrap edge instead of popping
	vec2 rel = abs(site - cam);
	float edge = 1.0 - smoothstep(area * 0.36, area * 0.48, max(rel.x, rel.y));

	float radius = length(MODEL_MATRIX[0].xyz) * grow * edge;
	vec3 centre = vec3(site.x, altitude, site.y) + MODEL_MATRIX[3].xyz;
	vec3 view = (VIEW_MATRIX * vec4(centre, 1.0)).xyz;
	// Most clouds lie beyond the camera's far plane (and behind the star and
	// moon spheres). Pull each puff in along its line of sight, scaling it to
	// match, so it looks identical but its depth fits: a monotonic squeeze
	// that keeps puffs in the right order and in front of the night sky.
	float d = length(view);
	float k = depth_squeeze * d / (d + depth_squeeze) / d;
	view *= k;
	radius *= k;
	POSITION = PROJECTION_MATRIX * vec4(view + vec3(VERTEX.xy * 2.0 * radius, 0.0), 1.0);
	q = VERTEX.xy * 2.0;
	height = COLOR.r;
}

void fragment() {
	float r2 = dot(q, q);
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(q, sqrt(max(1.0 - r2, 0.0)), 0.0)).xyz);
	// stylised: soft wrap lighting quantised into three bands
	float wrap = clamp(dot(n, normalize(sun_direction)) * 0.55 + 0.45, 0.0, 1.0);
	float band = wrap < 0.35 ? 0.3 : (wrap < 0.7 ? 0.65 : 1.0);
	float self_shadow = mix(0.5, 1.0, height);   // cloud bottoms sit in the cloud's own shadow
	vec3 colour = sun_colour * band * self_shadow + ambient * (0.6 + 0.4 * n.y);
	ALBEDO = colour * brightness;
	ALPHA = 1.0 - smoothstep(0.9, 1.0, r2);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
