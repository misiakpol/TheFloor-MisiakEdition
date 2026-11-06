class_name LobbyScreen
extends Control
## Ekran TV przed grą – zamiast podłogi ([member GameManager.tv_view]):
## [br]- PLAYERS: gracze z listy w konsoli admina (w kolorach, które dostaną na podłodze)
##   z przypisaną kategorią albo "kategoria losowa",
## [br]- CATEGORIES: tablica kategorii do wyboru – zajęte przez gracza z listy mają jego kolor
##   i imię, zagrane w tej sesji są przygaszone, wykluczone z losowania – ukryte.
## Czysty widok: odświeża się po sygnałach GameManagera / CategoryManagera, a widok
## przełącza Main ([method set_view]). Rozmiar kart i czcionek dopasowuje się do ich liczby.

const ACCENT_COLOR := Color("ffd166")
const MUTED_COLOR := Color(0.62, 0.64, 0.8)
const CARD_GAP := 14.0
const CARD_MAX_HEIGHT := 190.0
## Karta nie jest wyższa niż szerokość / tyle (napisy potrzebują szerokości).
const CARD_MIN_ASPECT := 2.0
## Docelowe proporcje karty – przy wyborze liczby kolumn.
const CARD_IDEAL_ASPECT := 3.2
const CARD_PADDING := 12.0
const PLAYED_ALPHA := 0.4
const FADE_DURATION := 0.25
## Opóźnienie kolejnych kart przy wejściu (łącznie najwyżej CARD_STAGGER_MAX).
const CARD_STAGGER := 0.03
const CARD_STAGGER_MAX := 0.6
const TYPE_NAMES := {
	CategoryManager.KIND_MUSIC: "MUZYKA",
	CategoryManager.KIND_TEXT: "TEKST",
	CategoryManager.KIND_VIDEO: "WIDEO",
}

var _view: GameManager.TvView = GameManager.TvView.FLOOR
## Imiona pokazane ostatnio na liście graczy – nowe wpisy "wskakują" pojedynczo.
var _shown_names: Dictionary = {}
var _fade_tween: Tween

var _heading: Label
var _subtitle: Label
var _card_area: Control
var _grid: GridContainer
var _empty_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()
	_build()
	GameManager.roster_changed.connect(_refresh.bind(false))
	GameManager.played_categories_changed.connect(_refresh.bind(false))
	GameManager.excluded_categories_changed.connect(_refresh.bind(false))
	CategoryManager.categories_loaded.connect(_refresh.bind(false).unbind(1))


## Pokazuje listę graczy / kategorie (z animacją wejścia) albo chowa ekran (FLOOR).
func set_view(view: GameManager.TvView) -> void:
	if view == _view:
		return
	_view = view
	_kill(_fade_tween)
	if view == GameManager.TvView.FLOOR:
		_fade_tween = create_tween()
		_fade_tween.tween_property(self, "modulate:a", 0.0, FADE_DURATION)
		_fade_tween.tween_callback(hide)
		return
	if not visible:
		modulate.a = 0.0
		show()
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 1.0, FADE_DURATION)
	_shown_names.clear()
	_refresh(true)


#region Budowa i odświeżanie

func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 32)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	margin.add_child(vbox)

	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 72
	header.add_theme_constant_override("separation", 28)
	vbox.add_child(header)
	var title := _make_label(52, ACCENT_COLOR, HORIZONTAL_ALIGNMENT_LEFT)
	title.text = "THE FLOOR"
	title.add_theme_color_override("font_outline_color", Color(0.45, 0.2, 0, 1))
	title.add_theme_constant_override("outline_size", 10)
	header.add_child(title)
	var heading_box := VBoxContainer.new()
	heading_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_box.add_theme_constant_override("separation", 0)
	header.add_child(heading_box)
	_heading = _make_label(46, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	heading_box.add_child(_heading)
	_subtitle = _make_label(24, MUTED_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	heading_box.add_child(_subtitle)
	# Równowaga dla tytułu po lewej – nagłówek stoi na środku ekranu.
	var spacer := Control.new()
	spacer.custom_minimum_size.x = title.get_minimum_size().x
	header.add_child(spacer)

	_card_area = Control.new()
	_card_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_card_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_area.resized.connect(_layout_cards)
	vbox.add_child(_card_area)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_area.add_child(center)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", int(CARD_GAP))
	_grid.add_theme_constant_override("v_separation", int(CARD_GAP))
	center.add_child(_grid)
	_empty_label = _make_label(48, MUTED_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_area.add_child(_empty_label)


## [param animate_all] – wszystkie karty wchodzą po kolei (zmiana widoku); inaczej
## animują się tylko nowi gracze.
func _refresh(animate_all: bool) -> void:
	if _view == GameManager.TvView.FLOOR:
		return
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	if _view == GameManager.TvView.PLAYERS:
		_build_player_cards(animate_all)
	else:
		_build_category_cards(animate_all)
	_empty_label.visible = _grid.get_child_count() == 0
	_layout_cards()


func _build_player_cards(animate_all: bool) -> void:
	var roster := GameManager.roster
	var random_count := 0
	var names: Dictionary = {}
	for i in roster.size():
		var entry: Dictionary = roster[i]
		var category: String = entry["category"]
		var category_text := "kategoria losowa"
		if category.is_empty():
			random_count += 1
		else:
			category_text = CategoryManager.get_display_name(category)
		var color := GameManager.get_roster_color(i)
		var card := _make_card(entry["name"], category_text, _make_style(color.darkened(0.55), color.lightened(0.2), 4))
		card.get_meta("info_label").add_theme_color_override("font_color",
				MUTED_COLOR if category.is_empty() else color.lightened(0.55))
		names[entry["name"]] = true
		if animate_all or not _shown_names.has(entry["name"]):
			_animate_card(card, i if animate_all else 0)
	_shown_names = names

	_heading.text = "GRACZE" if roster.is_empty() else "GRACZE  •  %d" % roster.size()
	_subtitle.text = ""
	if random_count > 0:
		_subtitle.text = "Bez wybranej kategorii: %d – wylosuje ją gra" % random_count
	_empty_label.text = "Czekamy na graczy…"


func _build_category_cards(animate_all: bool) -> void:
	var total := 0
	var free := 0
	var any_played := false
	for category in CategoryManager.categories:
		var key: String = category["name"]
		if category["questions"].is_empty():
			continue
		# Zajęta: ta sama kategoria (kolor i imię gracza) albo inny wariant tej samej nazwy
		# (np. "Loga [Marki]" przy wybranym "Loga [Auta]") – ten tylko przygaszony.
		var owner_index := GameManager.get_roster_category_conflict(key, -1)
		var is_owner: bool = owner_index >= 0 and GameManager.roster[owner_index]["category"] == key
		if GameManager.is_category_excluded(key) and not is_owner:
			continue # Wykluczona przez prowadzącego – gracze jej nie widzą.
		total += 1
		var info: PackedStringArray = []
		var type := _get_category_type(category)
		if TYPE_NAMES.has(type):
			info.append(TYPE_NAMES[type])
		var style := _make_style(Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.18), 2)
		var owner_color := Color.WHITE
		if is_owner:
			owner_color = GameManager.get_roster_color(owner_index)
			style = _make_style(owner_color.darkened(0.6), owner_color.lightened(0.2), 4)
			info.append(GameManager.roster[owner_index]["name"])
		elif owner_index >= 0:
			info.append("niedostępna")
		else:
			free += 1
		var played := GameManager.is_category_played(key)
		if played:
			info.append("była grana")
			any_played = true
		var card := _make_card(CategoryManager.get_admin_name(key), "  •  ".join(info), style)
		if is_owner:
			card.get_meta("info_label").add_theme_color_override("font_color", owner_color.lightened(0.55))
		if played or (owner_index >= 0 and not is_owner):
			card.self_modulate.a = PLAYED_ALPHA
			card.get_meta("name_label").modulate.a = PLAYED_ALPHA + 0.15
		if animate_all:
			_animate_card(card, total - 1)

	_heading.text = "WYBIERZCIE KATEGORIĘ"
	_subtitle.text = "Wolne: %d z %d" % [free, total]
	if any_played:
		_subtitle.text += "  •  przygaszone = już grane lub niedostępne"
	_empty_label.text = "Brak kategorii – dodaj foldery lub pliki .txt w „kategorie”."


## Typ do podpisu: muzyka / tekst / wideo (kategoria z choćby jednym wideo) / zdjęcia ("").
func _get_category_type(category: Dictionary) -> String:
	if category["kind"] != CategoryManager.KIND_IMAGE:
		return category["kind"]
	for question: Dictionary in category["questions"]:
		if question["kind"] == CategoryManager.KIND_VIDEO:
			return CategoryManager.KIND_VIDEO
	return CategoryManager.KIND_IMAGE

#endregion


#region Karty i układ

func _make_card(title: String, info: String, style: StyleBoxFlat) -> PanelContainer:
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", style)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 0)
	card.add_child(vbox)
	var name_label := _make_label(32, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	name_label.text = title
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	name_label.add_theme_constant_override("outline_size", 6)
	vbox.add_child(name_label)
	var info_label := _make_label(20, MUTED_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	info_label.text = info
	info_label.visible = not info.is_empty()
	info_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info_label.clip_text = true
	vbox.add_child(info_label)
	card.set_meta("name_label", name_label)
	card.set_meta("info_label", info_label)
	_grid.add_child(card)
	return card


## Liczba kolumn i rozmiar kart: jak największe karty o rozsądnych proporcjach,
## mieszczące się w całości na ekranie. Czcionki podążają za wysokością karty.
func _layout_cards() -> void:
	var count := _grid.get_child_count()
	var area := _card_area.size
	if count == 0 or area.x <= 0.0 or area.y <= 0.0:
		return
	var best_columns := 1
	var best_size := Vector2.ZERO
	var best_score := -1.0
	for columns in range(1, count + 1):
		var rows := ceili(float(count) / columns)
		var width := (area.x - CARD_GAP * (columns - 1)) / columns
		var height := (area.y - CARD_GAP * (rows - 1)) / rows
		if width <= 0.0 or height <= 0.0:
			break
		height = minf(height, minf(CARD_MAX_HEIGHT, width / CARD_MIN_ASPECT))
		width = minf(width, height * CARD_IDEAL_ASPECT * 1.25)
		var score := minf(height, width / CARD_IDEAL_ASPECT)
		if score > best_score:
			best_score = score
			best_columns = columns
			best_size = Vector2(floorf(width), floorf(height))
	_grid.columns = best_columns

	var inner := best_size - Vector2.ONE * CARD_PADDING * 2.0
	var info_size := clampi(roundi(best_size.y * 0.16), 12, 30)
	for card: PanelContainer in _grid.get_children():
		card.custom_minimum_size = best_size
		card.pivot_offset = best_size * 0.5
		var name_label: Label = card.get_meta("name_label")
		var info_label: Label = card.get_meta("info_label")
		info_label.add_theme_font_size_override("font_size", info_size)
		var name_area := Vector2(inner.x, inner.y - (info_size * 1.4 if info_label.visible else 0.0))
		name_label.add_theme_font_size_override("font_size", TextUtils.fit_font_size(
				name_label.get_theme_font("font"), name_label.text, name_area,
				clampi(roundi(best_size.y * 0.34), 16, 64), 12))


func _animate_card(card: Control, order: int) -> void:
	card.modulate.a = 0.0
	card.scale = Vector2.ONE * 0.85
	var tween := card.create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var delay := minf(order * CARD_STAGGER, CARD_STAGGER_MAX)
	tween.tween_property(card, "modulate:a", 1.0, 0.2).set_delay(delay)
	tween.tween_property(card, "scale", Vector2.ONE, 0.35).set_delay(delay)


func _make_style(background: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(16)
	style.set_content_margin_all(CARD_PADDING)
	return style


func _make_label(font_size: int, color: Color, alignment: HorizontalAlignment) -> Label:
	var label := Label.new()
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _kill(tween: Tween) -> void:
	if tween and tween.is_valid():
		tween.kill()

#endregion
