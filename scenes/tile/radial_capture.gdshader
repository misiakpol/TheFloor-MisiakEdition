// Radialne przejęcie strefy.
// Nakładany (jako JEDEN wspólny ShaderMaterial) na CaptureLayer wszystkich przejmowanych pól.
// Każde pole rysuje swój kształt w kolorze zwycięzcy, a shader zostawia tylko piksele
// wewnątrz koła o środku `center` i promieniu `radius` – liczonych we współrzędnych świata
// (canvas), więc koło jest ciągłe na wszystkich polach naraz. Main animuje `radius`.
shader_type canvas_item;

// Środek fali: środek pola zwycięzcy (Control.get_global_rect().get_center()).
uniform vec2 center = vec2(0.0);
// Aktualny promień fali w pikselach świata.
uniform float radius = 0.0;
// Szerokość jasnej krawędzi fali.
uniform float edge_width = 36.0;
uniform vec4 edge_color : source_color = vec4(1.0, 1.0, 1.0, 0.75);

varying vec2 world_position;

void vertex() {
	// MODEL_MATRIX: przestrzeń lokalna węzła -> świat (canvas).
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float dist = distance(world_position, center);
	if (dist > radius) {
		discard;
	}
	// Rozjaśnienie przy czole fali (0 w środku koła, 1 na samej krawędzi).
	float edge = smoothstep(radius - edge_width, radius, dist);
	COLOR.rgb = mix(COLOR.rgb, edge_color.rgb, edge * edge_color.a);
}
