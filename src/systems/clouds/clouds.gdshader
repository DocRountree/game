shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// Puffy dot clouds. One camera-facing disc per puff, shaded as a sphere.
// INSTANCE_CUSTOM = (cloud site x, site z, cloud seed, formation order 0..1);
// COLOR.r = height within the cloud; the instance basis scale is the puff radius.
// Puffs appear and vanish by growing and shrinking (never fading), so they can
// stay crisp, opaque dots with correct overlap.

uniform float area = 30000.0;
// The layer curves down with distance like clouds over a round planet, until
// the horizon cuts it off. Real curvature would only do that ~130 km out, far
// past the simulated patch, so it is exaggerated: with this radius the cloud
// base sinks below the horizon ~10 km away, while puffs are still clearly
// visible, instead of shrinking into dots. The wrap edge lies beyond it.
uniform float curvature_radius = 38000.0;
uniform float fill = 0.0;                // overcast: fuller, longer-lived, bigger clouds
uniform float grey = 0.0;                // overcast: darker, greyer cloud colour
uniform vec3 flash_pos = vec3(0.0);      // lightning: where the current flash is
uniform float flash = 0.0;               // and how bright
uniform float altitude = 1300.0;
uniform vec2 wind = vec2(7.0, 2.5);
uniform float life_seconds = 150.0;
uniform float coverage = 0.6;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_colour = vec3(1.0);   // sunlight as it reaches the clouds
uniform vec3 ambient = vec3(0.2, 0.27, 0.4);
uniform float brightness = 1.5;
uniform float depth_squeeze = 2200.0;   // puffs end up within this distance (stars sit at 2500 m)
uniform float planet_radius = 6400000.0;
uniform float dim_start = 0.12;          // sun height (sine) at which cloud light starts to wane

varying float lit;
varying float flash_glow;

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
	water = mix(water, max(water, 0.85 + 0.15 * roll), fill * step(roll, coverage));   // overcast: clouds stay formed
	// base puffs condense first; the tower builds last and evaporates first
	float grow = clamp((water * 1.15 - order * 0.9) / 0.18, 0.0, 1.0);
	// shrink away near the wrap edge instead of popping
	vec2 rel = abs(site - cam);
	float edge = 1.0 - smoothstep(area * 0.42, area * 0.49, max(rel.x, rel.y));

	// overcast: puffs swell until neighbouring clouds merge into a deck
	float radius = length(MODEL_MATRIX[0].xyz) * grow * edge * (1.0 + 2.2 * fill);
	vec3 centre = vec3(site.x, altitude, site.y) + MODEL_MATRIX[3].xyz;
	float lift = centre.y;   // height above the ground, for lighting
	vec2 off = centre.xz - cam;
	centre.y -= dot(off, off) / (2.0 * curvature_radius);   // the layer curves away over the horizon
	vec3 fd = centre - flash_pos;
	flash_glow = flash * exp(-dot(fd, fd) / (2500.0 * 2500.0));
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
	// Light fades smoothly from a sun ~7 degrees up (longer, redder, dimmer path)
	// until the planet's shadow passes this puff: a puff h metres up still sees
	// the sun until it is sqrt(2h/R) below the horizon, so bases go dark first
	// and tops glow last.
	float dip = sqrt(2.0 * max(lift, 1.0) / planet_radius);
	float sun_y = normalize(sun_direction).y;
	float x = clamp((sun_y + dip) / (dim_start + dip), 0.0, 1.0);
	lit = x * x * (3.0 - 2.0 * x);
	height = COLOR.r;
}

void fragment() {
	float r2 = dot(q, q);
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(q, sqrt(max(1.0 - r2, 0.0)), 0.0)).xyz);
	// stylised: soft wrap lighting quantised into three bands
	float wrap = clamp(dot(n, normalize(sun_direction)) * 0.55 + 0.45, 0.0, 1.0);
	float band = wrap < 0.35 ? 0.3 : (wrap < 0.7 ? 0.65 : 1.0);
	float self_shadow = mix(mix(0.5, 0.3, grey), 1.0, height);   // cloud bottoms sit in the cloud's own shadow
	vec3 colour = sun_colour * band * self_shadow * lit + ambient * (0.6 + 0.4 * n.y);
	colour = mix(colour, vec3(dot(colour, vec3(0.3, 0.55, 0.15))) * mix(0.75, 0.5, height), grey);
	colour += vec3(0.8, 0.85, 1.0) * flash_glow * mix(1.0, 0.6, height) * 2.0;   // lit from within
	ALBEDO = colour * brightness;
	ALPHA = 1.0 - smoothstep(0.9, 1.0, r2);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
