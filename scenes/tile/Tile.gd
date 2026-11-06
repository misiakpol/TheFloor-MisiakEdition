class_name Tile
extends Control
## Pojedyncze pole podłogi (jedno pole siatki).
##
## Kafelek sam rysuje swoje tło ([method _draw]), dzięki czemu pola jednego gracza
## zlewają się w jeden kształt bez wewnętrznych podziałów:
## [br]- w stronę sąsiada tego samego gracza tło "dolewa" połowę szczeliny siatki
##   (drugą połowę dolewa sąsiad), a skrzyżowania szczelin wypełniane są tylko
##   wewnątrz pełnego bloku 2x2,
## [br]- narożniki są zaokrąglone tylko na zewnątrz terytorium,
## [br]- obrys podświetlenia biegnie wyłącznie po zewnętrznej krawędzi terytorium.
## Main przekazuje maskę sąsiadów przez [method set_neighbors].
##
## Przejęcie pola jest RADIALNE i wspólne dla całej strefy: CaptureLayer rysuje kształt
## pola w kolorze zwycięzcy, a współdzielony ShaderMaterial (radial_capture.gdshader)
## odsłania go tylko wewnątrz koła rosnącego ze środka pola zwycięzcy. Main animuje promień
## jednego materiału, więc wszystkie przejmowane pola malują się jedną, ciągłą falą.
## Na dotychczasowych polach zwycięzcy CaptureCover (nad CaptureLayer) przykrywa ich stary
## kształt, więc falę z jasnym czołem widać tylko na zajmowanym terenie (i w szczelinach).
##
## [codeblock]
## Tile (Control)              – _draw(): tło w kolorze właściciela + "mostki" do sąsiadów
## ├─ CaptureLayer (Control)    – kształt pola w kolorze zwycięzcy, przycinany shaderem
## ├─ CaptureCover (Control)    – stary kształt pola zwycięzcy NAD falą (tylko jego pola)
## ├─ Content (MarginContainer) – podpisy (widoczne tylko na jednym polu terytorium)
## │  └─ VBox
## │     ├─ %CategoryLabel
## │     └─ %OwnerLabel
## ├─ Flash (Control)           – białe błyski po wylosowaniu (ten sam kształt co tło)
## └─ HighlightLayer (Control)  – pulsujący obrys zewnętrznej krawędzi terytorium
## [/codeblock]

## ROLL – podświetlenie ruletki: pełne od razu, bez pulsowania (szybkie przeskoki).
enum HighlightStyle { NONE, SELECTED, ATTACKER, DEFENDER, WINNER, ROLL }

## Bity maski sąsiadów należących do tego samego gracza.
const N := 1
const E := 2
const S := 4
const W := 8
const NE := 16
const SE := 32
const SW := 64
const NW := 128
## O ile mostek do sąsiada zachodzi pod krawędź pola (zakrywa antyaliasing StyleBoxa).
const SEAM_OVERLAP := 1.5

const HIGHLIGHT_COLORS := {
	HighlightStyle.SELECTED: Color("ffd166"),
	HighlightStyle.ATTACKER: Color("ffd166"),
	HighlightStyle.DEFENDER: Color("ef476f"),
	HighlightStyle.WINNER: Color("06d6a0"),
	HighlightStyle.ROLL: Color.WHITE,
}

@export_group("Shape")
@export var corner_radius := 12
@export_group("Appear")
@export var appear_duration := 0.9
@export_group("Highlight")
@export var pulse_period := 0.9
@export var pulse_min_alpha := 0.35
@export_group("Selection burst")
@export var burst_count := 3
@export var burst_strength := 0.75

var tile_index := -1
## Kolor tła (tweenowany przy przejęciu).
var fill_color := Color.GRAY:
	set(value):
		fill_color = value
		queue_redraw()

## Szerokość szczeliny siatki (GridContainer separation).
var _gap := 8.0
## Maska bitów N/E/S/W/NE/SE/SW/NW – sąsiedzi z tym samym właścicielem.
var _neighbors := 0
var _highlight_style := HighlightStyle.NONE
var _shape_style := StyleBoxFlat.new()

var _appear_tween: Tween
var _highlight_tween: Tween
var _burst_tween: Tween
var _capture_color := Color.WHITE
## Maska sąsiadów PO przejęciu – kształt rysowany przez CaptureLayer.
var _capture_neighbors := 0
## W trakcie przejęcia podpisy są ukryte (pole ma jeszcze stary kolor).
var _capturing := false
var _labels_wanted := false

@onready var _capture_layer: Control = $CaptureLayer
@onready var _capture_cover: Control = $CaptureCover
@onready var _content: Control = $Content
@onready var _category_label: Label = %CategoryLabel
@onready var _owner_label: Label = %OwnerLabel
@onready var _flash: Control = $Flash
@onready var _highlight_layer: Control = $HighlightLayer


func _ready() -> void:
	resized.connect(_on_resized)
	_flash.draw.connect(func() -> void: _draw_shape(_flash, Color.WHITE))
	_capture_layer.draw.connect(
			func() -> void: _draw_shape_with_mask(_capture_layer, _capture_color, _capture_neighbors))
	_capture_layer.hide()
	_capture_cover.draw.connect(func() -> void: _draw_shape(_capture_cover, fill_color))
	_capture_cover.hide()
	_highlight_layer.draw.connect(_draw_highlight)
	_flash.modulate.a = 0.0
	_highlight_layer.modulate.a = 0.0
	set_process(false)
	_on_resized()
	scale = Vector2.ZERO # Niewidoczny do czasu play_appear().


## Pulsowanie liczone z zegara globalnego – wszystkie pola terytorium (także
## świeżo przejęte) pulsują idealnie w tym samym rytmie.
func _process(_delta: float) -> void:
	var angle := Time.get_ticks_msec() / 1000.0 * TAU / pulse_period
	_highlight_layer.modulate.a = lerpf(pulse_min_alpha, 1.0, 0.5 + 0.5 * sin(angle))


func _draw() -> void:
	_draw_shape(self, fill_color)


## Wywołuj PO dodaniu kafelka do drzewa (potrzebne @onready).
func setup(index: int, gap: float) -> void:
	tile_index = index
	_gap = gap


func set_territory(owner_name: String, category_name: String, color: Color) -> void:
	_category_label.text = category_name
	_owner_label.text = owner_name
	fill_color = color


## Zmiana kategorii właściciela (po pojedynku zwycięzca gra kategorią atakującego).
func set_category(category_name: String) -> void:
	_category_label.text = category_name


## [param mask] – bity [constant N], [constant E], ... dla sąsiadów tego samego gracza.
func set_neighbors(mask: int) -> void:
	if mask == _neighbors:
		return
	_neighbors = mask
	queue_redraw()
	_flash.queue_redraw()
	_capture_layer.queue_redraw()
	_capture_cover.queue_redraw()
	_highlight_layer.queue_redraw()


## Podpisy pokazujemy tylko na jednym polu terytorium (Main wybiera pole najbliżej środka).
func set_labels_visible(labels_visible: bool) -> void:
	_labels_wanted = labels_visible
	_content.visible = labels_visible and not _capturing


## Wejście kafelka: skala 0 -> 1 z elastycznym "odbiciem".
func play_appear(delay: float = 0.0) -> void:
	_kill(_appear_tween)
	scale = Vector2.ZERO
	_appear_tween = create_tween()
	_appear_tween.tween_property(self, "scale", Vector2.ONE, appear_duration) \
		.set_delay(delay) \
		.set_trans(Tween.TRANS_ELASTIC) \
		.set_ease(Tween.EASE_OUT)


## Pulsujący obrys terytorium. [code]HighlightStyle.NONE[/code] wygasza efekt.
func set_highlight(style: HighlightStyle) -> void:
	if style == _highlight_style:
		return
	_highlight_style = style
	_kill(_highlight_tween)

	if style == HighlightStyle.NONE:
		set_process(false)
		_highlight_tween = create_tween()
		_highlight_tween.tween_property(_highlight_layer, "modulate:a", 0.0, 0.2)
		return

	# Obrys rysowany jest na biało i barwiony przez self_modulate.
	_highlight_layer.self_modulate = HIGHLIGHT_COLORS[style]
	if style == HighlightStyle.ROLL:
		set_process(false)
		_highlight_layer.modulate.a = 1.0
	else:
		set_process(true)


## Mocne pulsowanie po wylosowaniu: kilka białych błysków całego kształtu pola.
func play_selection_burst() -> void:
	_kill(_burst_tween)
	_burst_tween = create_tween().set_trans(Tween.TRANS_SINE)
	for i in burst_count:
		_burst_tween.tween_property(_flash, "modulate:a", burst_strength, 0.1).set_ease(Tween.EASE_OUT)
		_burst_tween.tween_property(_flash, "modulate:a", 0.0, 0.22).set_ease(Tween.EASE_IN)


## Start radialnego przejęcia. Tło pola (stary kolor, stara maska, stare szczeliny) zostaje
## bez zmian, a NAD nim CaptureLayer rysuje kształt pola po scaleniu ([param merged_mask])
## w kolorze zwycięzcy, odsłaniany przez [param radial_material] (wspólny dla całej strefy).
## Wywoływane też dla dotychczasowych pól zwycięzcy – ich nakładka zamyka szczeliny
## i prostuje narożniki dokładnie wtedy, gdy dociera do nich fala.
## [param is_new_tile] = pole przechodzi do zwycięzcy (ukrywamy stare podpisy).
func begin_capture(new_owner_name: String, new_category: String, new_color: Color,
		radial_material: ShaderMaterial, merged_mask: int, is_new_tile: bool) -> void:
	if is_new_tile:
		_owner_label.text = new_owner_name
		_category_label.text = new_category
		_content.visible = false
	_capture_color = new_color
	_capture_neighbors = merged_mask
	_capturing = is_new_tile
	_capture_layer.material = radial_material
	_capture_layer.queue_redraw()
	_capture_layer.show()
	# Dotychczasowe pole zwycięzcy: jego stary kształt zostaje NAD falą (fala odsłania tylko
	# to, co dochodzi – mostki i narożniki w stronę zajmowanego terenu).
	_capture_cover.queue_redraw()
	_capture_cover.visible = not is_new_tile


## Koniec przejęcia: kolor zostaje na stałe w tle pola, warstwa i shader znikają.
func finish_capture() -> void:
	if _capture_layer.material == null:
		return
	fill_color = _capture_color
	_capturing = false
	_capture_layer.hide()
	_capture_layer.material = null
	_capture_cover.hide()
	_content.visible = _labels_wanted


#region Rysowanie kształtu

## Kształt narysowany z INNĄ maską sąsiadów (warstwa przejęcia rysuje kształt "po scaleniu").
func _draw_shape_with_mask(canvas: CanvasItem, color: Color, mask: int) -> void:
	var current_mask := _neighbors
	_neighbors = mask
	_draw_shape(canvas, color)
	_neighbors = current_mask


## Tło pola + "mostki" do sąsiadów tego samego gracza. Używane przez tło i błysk.
func _draw_shape(canvas: CanvasItem, color: Color) -> void:
	var half_gap := _gap * 0.5
	_shape_style.bg_color = color
	_shape_style.corner_radius_top_left = _outer_corner_radius(N, W)
	_shape_style.corner_radius_top_right = _outer_corner_radius(N, E)
	_shape_style.corner_radius_bottom_right = _outer_corner_radius(S, E)
	_shape_style.corner_radius_bottom_left = _outer_corner_radius(S, W)
	canvas.draw_style_box(_shape_style, Rect2(Vector2.ZERO, size))

	# Połowa szczeliny w stronę sąsiada (drugą połowę rysuje sąsiad). Mostek wchodzi
	# SEAM_OVERLAP px pod krawędź pola, zakrywając wygładzoną (półprzezroczystą) krawędź
	# StyleBoxa – inaczej w scalonym terytorium widać cienką kreskę.
	if _is_linked(N):
		canvas.draw_rect(Rect2(0.0, -half_gap, size.x, half_gap + SEAM_OVERLAP), color)
	if _is_linked(S):
		canvas.draw_rect(Rect2(0.0, size.y - SEAM_OVERLAP, size.x, half_gap + SEAM_OVERLAP), color)
	if _is_linked(W):
		canvas.draw_rect(Rect2(-half_gap, 0.0, half_gap + SEAM_OVERLAP, size.y), color)
	if _is_linked(E):
		canvas.draw_rect(Rect2(size.x - SEAM_OVERLAP, 0.0, half_gap + SEAM_OVERLAP, size.y), color)

	# Ćwiartki skrzyżowań szczelin – tylko gdy cały blok 2x2 należy do jednego gracza,
	# inaczej w wklęsłym narożniku "L" powstałby wystający ząbek.
	var quarter := Vector2(half_gap, half_gap)
	if _is_linked(N | W | NW):
		canvas.draw_rect(Rect2(-quarter, quarter), color)
	if _is_linked(N | E | NE):
		canvas.draw_rect(Rect2(Vector2(size.x, -half_gap), quarter), color)
	if _is_linked(S | E | SE):
		canvas.draw_rect(Rect2(size, quarter), color)
	if _is_linked(S | W | SW):
		canvas.draw_rect(Rect2(Vector2(-half_gap, size.y), quarter), color)


## Obrys w połowie szczeliny na zewnątrz krawędzi, które graniczą z innym graczem.
## Pasy poziome w wklęsłych narożnikach przechodzą przez całą szczelinę, pionowe tylko
## przez połowę – razem domykają "kolanko" bez nakładania się (ważne przy półprzezroczystości).
func _draw_highlight() -> void:
	var width := _gap * 0.5
	var layer := _highlight_layer

	if not _is_linked(N):
		var x0 := -_stroke_extension(W, NW, true)
		var x1 := size.x + _stroke_extension(E, NE, true)
		layer.draw_rect(Rect2(x0, -width, x1 - x0, width), Color.WHITE)
	if not _is_linked(S):
		var x0 := -_stroke_extension(W, SW, true)
		var x1 := size.x + _stroke_extension(E, SE, true)
		layer.draw_rect(Rect2(x0, size.y, x1 - x0, width), Color.WHITE)
	if not _is_linked(W):
		var y0 := -_stroke_extension(N, NW, false)
		var y1 := size.y + _stroke_extension(S, SW, false)
		layer.draw_rect(Rect2(-width, y0, width, y1 - y0), Color.WHITE)
	if not _is_linked(E):
		var y0 := -_stroke_extension(N, NE, false)
		var y1 := size.y + _stroke_extension(S, SE, false)
		layer.draw_rect(Rect2(size.x, y0, width, y1 - y0), Color.WHITE)

	var r := float(corner_radius)
	_draw_outer_corner_arc(N, W, Vector2(r, r), PI)
	_draw_outer_corner_arc(N, E, Vector2(size.x - r, r), PI * 1.5)
	_draw_outer_corner_arc(S, E, Vector2(size.x - r, size.y - r), 0.0)
	_draw_outer_corner_arc(S, W, Vector2(r, size.y - r), PI * 0.5)


## Jak daleko pas obrysu wychodzi poza róg kafelka:
## narożnik wypukły -> cofa się o promień (resztę dorysowuje łuk),
## prosta kontynuacja -> do połowy szczeliny (drugą połowę rysuje sąsiad),
## narożnik wklęsły -> pas poziomy przez całą szczelinę.
func _stroke_extension(side: int, diagonal: int, horizontal: bool) -> float:
	if not _is_linked(side):
		return -float(corner_radius)
	if horizontal and _is_linked(diagonal):
		return _gap
	return _gap * 0.5


func _draw_outer_corner_arc(side_a: int, side_b: int, center: Vector2, start_angle: float) -> void:
	if (_neighbors & (side_a | side_b)) != 0:
		return
	var width := _gap * 0.5
	_highlight_layer.draw_arc(center, corner_radius + width * 0.5, start_angle,
			start_angle + PI * 0.5, 16, Color.WHITE, width, true)


func _outer_corner_radius(side_a: int, side_b: int) -> int:
	return corner_radius if (_neighbors & (side_a | side_b)) == 0 else 0


func _is_linked(bits: int) -> bool:
	return (_neighbors & bits) == bits

#endregion


func _on_resized() -> void:
	# Skalowanie od środka zamiast od lewego-górnego rogu.
	pivot_offset = size * 0.5
	# Czcionki proporcjonalne do rozmiaru kafelka (różne wymiary siatki).
	var base := minf(size.x, size.y)
	_category_label.add_theme_font_size_override("font_size", maxi(10, int(base * 0.14)))
	_owner_label.add_theme_font_size_override("font_size", maxi(8, int(base * 0.095)))


func _kill(tween: Tween) -> void:
	if tween and tween.is_valid():
		tween.kill()
