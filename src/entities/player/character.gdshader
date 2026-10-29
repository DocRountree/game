shader_type spatial;

// The character's one material: every vertex names its colour by an index in
// COLOR.r (a slot of the palette uniform, set from CharacterTraits.palette()),
// so recolouring the character is a uniform change (no meshes rebuilt) and the
// whole body, hair, beard and accessories are drawn with one material.
// COLOR.g is how far a vertex sways with the head's motion (hair tips 1, the
// roots 0); `sway` is that motion in the head's frame, set by CharacterRig.
// Hair is a little glossier than cloth, and darker and flatter when wet.

uniform vec3 palette[20];
uniform float wet = 0.0;
uniform vec3 sway = vec3(0.0);

varying flat int slot;

void vertex() {
	slot = int(COLOR.r * 255.0 + 0.5);
	VERTEX += sway * COLOR.g;
}

void fragment() {
	vec3 c = palette[slot];
	bool is_hair = slot == 3 || slot == 8;
	ALBEDO = c * (1.0 - (is_hair ? 0.4 : 0.15) * wet);
	ROUGHNESS = is_hair ? mix(0.55, 0.3, wet) : 0.85;
	SPECULAR = is_hair ? 0.4 : 0.5;
}
