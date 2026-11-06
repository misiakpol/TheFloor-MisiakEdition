class_name CategoryManagerWindow
extends Window
## Menedżer kategorii (konsola admina): wszystkie kategorie zwykłe albo finałowe jako kafelki.
##
## Kafelek: nazwa, liczba pytań i typ, stan w sesji (nowa / zagrana / zużyta / pusta), gracz
## z listy, który ją ma, oraz przełącznik "W losowaniu" (wykluczenie z losowania kategorii).
## Akcje: skanowanie folderów, odnowienie zagranych / puli finałowej, przywrócenie wszystkich
## do losowania, otwarcie folderu na dysku. Wyszukiwarka i filtry tylko zawężają widok.
## Czysty widok – zmiany idą przez metody GameManagera / CategoryManagera, a okno odświeża
## się po ich sygnałach. Zmiana samego stanu kafelków nie przebudowuje siatki (scroll zostaje).

enum Section { REGULAR, FINAL }
enum StatusFilter { ALL, FRESH, USED, EXCLUDED, EMPTY }

const STATUS_FILTER_LABELS: PackedStringArray = ["Każdy stan", "Nowe", "Zagrane / zużyte", "Wykluczone", "Puste"]
const TYPE_FILTERS: Array[Array] = [
	["Wszystkie typy", ""],
	["Zdjęcia", CategoryManager.KIND_IMAGE],
	["Muzyka", CategoryManager.KIND_MUSIC],
	["Wideo", CategoryManager.KIND_VIDEO],
	["Tekst", CategoryManager.KIND_TEXT],
]
const TYPE_NAMES := {
	CategoryManager.KIND_MUSIC: "MUZYKA",
	CategoryManager.KIND_TEXT: "TEKST",
	CategoryManager.KIND_VIDEO: "WIDEO",
}
const TILE_SIZE := Vector2(232, 122)
const BACKGROUND_COLOR := Color(0.06, 0.06, 0.1, 1)
const MUTED_COLOR := Color(0.6, 0.62, 0.8)
const FRESH_COLOR := Color("06d6a0")
const USED_COLOR := Color(0.55, 0.57, 0.68)
const EXCLUDED_COLOR := Color(0.9, 0.45, 0.52)
const WARNING_COLOR := Color(1.0, 0.62, 0.62)

var _section := Section.REGULAR
## Klucz kategorii -> kafelek (tylko pokazane).
var _tiles: Dictionary = {}

var _section_buttons: Array[Button] = []
var _search_edit: LineEdit
var _type_option: OptionButton
var _status_option: OptionButton
var _reload_button: Button
var _reset_used_button: Button
var _include_all_button: Button
var _summary_label: Label
var _flow: HFlowContainer
var _empty_label: Label


func _ready() -> void:
	title = "Menedżer kategorii"
	size = Vector2i(1120, 740)
	min_size = Vector2i(760, 460)
	transient = true
	wrap_controls = false
	hide()
	close_requested.connect(hide)
	_build()
	CategoryManager.categories_loaded.connect(_rebuild.unbind(1))
	GameManager.played_categories_changed.connect(_on_status_changed)
	GameManager.used_final_categories_changed.connect(_on_status_changed)
	GameManager.excluded_categories_changed.connect(_on_status_changed)
	GameManager.roster_changed.connect(_on_status_changed)
	GameManager.state_changed.connect(_refresh_actions)


func open() -> void:
	_rebuild()
	popup_centered(size)
	_search_edit.grab_focus.call_deferred()


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		hide()
		set_input_as_handled()


#region Budowa okna

func _build() -> void:
	var root := PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root_style := StyleBoxFlat.new()
	root_style.bg_color = BACKGROUND_COLOR
	root.add_theme_stylebox_override("panel", root_style)
	add_child(root)
	var margin := MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	root.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Rząd 1: sekcja + wyszukiwarka + filtry.
	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 8)
	vbox.add_child(filters)
	var group := ButtonGroup.new()
	for section: Section in [Section.REGULAR, Section.FINAL]:
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size.x = 150
		button.button_pressed = section == _section
		button.pressed.connect(_set_section.bind(section))
		filters.add_child(button)
		_section_buttons.append(button)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Szukaj kategorii…"
	_search_edit.clear_button_enabled = true
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.text_changed.connect(_rebuild.unbind(1))
	filters.add_child(_search_edit)
	_type_option = _make_option(TYPE_FILTERS.map(func(entry: Array) -> String: return entry[0]))
	filters.add_child(_type_option)
	_status_option = _make_option(Array(STATUS_FILTER_LABELS))
	filters.add_child(_status_option)

	# Rząd 2: akcje + podsumowanie.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	vbox.add_child(actions)
	_reload_button = _make_action("Skanuj foldery",
			"Ponownie skanuje foldery kategorii (np. po dodaniu zdjęć lub plików .txt). Niedostępne w trakcie pojedynku.",
			CategoryManager.reload)
	actions.add_child(_reload_button)
	_reset_used_button = _make_action("", "", _on_reset_used_pressed)
	actions.add_child(_reset_used_button)
	_include_all_button = _make_action("Wszystkie do losowania",
			"Przywraca do losowania wszystkie wykluczone kategorie z tej sekcji.", _on_include_all_pressed)
	actions.add_child(_include_all_button)
	actions.add_child(_make_action("Otwórz folder", "Otwiera folder tej sekcji w Eksploratorze.", _on_open_folder_pressed))
	_summary_label = Label.new()
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_summary_label.add_theme_color_override("font_color", MUTED_COLOR)
	_summary_label.add_theme_font_size_override("font_size", 13)
	actions.add_child(_summary_label)

	# Kafelki.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var scroll_content := VBoxContainer.new()
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_content)
	_flow = HFlowContainer.new()
	_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow.add_theme_constant_override("h_separation", 10)
	_flow.add_theme_constant_override("v_separation", 10)
	_flow.resized.connect(_fit_tile_width)
	scroll_content.add_child(_flow)
	_empty_label = Label.new()
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", WARNING_COLOR)
	_empty_label.text = "Żadna kategoria nie pasuje do wyszukiwania i filtrów."
	scroll_content.add_child(_empty_label)

	var legend := Label.new()
	legend.text = "„W losowaniu” wyłączone = gra nigdy sama nie przydzieli tej kategorii (ani do rundy 3), ale ręcznie nadal można ją wybrać. " \
			+ "Zmiana zapisuje się od razu. Najedź na kafelek, aby zobaczyć ścieżkę na dysku. Esc zamyka."
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend.add_theme_color_override("font_color", MUTED_COLOR)
	legend.add_theme_font_size_override("font_size", 12)
	vbox.add_child(legend)


func _make_option(labels: Array) -> OptionButton:
	var option := OptionButton.new()
	option.focus_mode = Control.FOCUS_NONE
	for label: String in labels:
		option.add_item(label)
	option.item_selected.connect(_rebuild.unbind(1))
	return option


func _make_action(text: String, tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	return button

#endregion


#region Kafelki

func _set_section(section: Section) -> void:
	_section = section
	_rebuild()


func _section_categories() -> Array[Dictionary]:
	return CategoryManager.final_categories if _section == Section.FINAL else CategoryManager.categories


## Buduje kafelki od nowa (zmiana sekcji, filtrów, wyszukiwania albo skan folderów).
func _rebuild() -> void:
	if not is_node_ready():
		return
	for child in _flow.get_children():
		_flow.remove_child(child)
		child.queue_free()
	_tiles.clear()
	var query := TextUtils.to_search_key(_search_edit.text.strip_edges())
	for category in _section_categories():
		var key: String = category["name"]
		if not query.is_empty() and not TextUtils.to_search_key(CategoryManager.get_admin_name(key)).contains(query):
			continue
		if not _matches_filters(category):
			continue
		var tile := _make_tile(category)
		_flow.add_child(tile)
		_tiles[key] = tile
		_update_tile(tile, category)
	_empty_label.visible = _tiles.is_empty()
	_fit_tile_width()
	_refresh_summary()
	_refresh_actions()


## Kafelki rozciągnięte tak, by rzędy wypełniały całą szerokość (min. TILE_SIZE.x).
func _fit_tile_width() -> void:
	var width := _flow.size.x
	if width <= 0.0:
		return
	var gap := float(_flow.get_theme_constant("h_separation"))
	var columns := maxi(1, floori((width + gap) / (TILE_SIZE.x + gap)))
	var tile_width := floorf((width - gap * (columns - 1)) / columns)
	for tile: Control in _flow.get_children():
		tile.custom_minimum_size.x = tile_width


## Zmiana stanu (zagrane, wykluczenia, lista graczy): kafelki aktualizują się w miejscu.
## Tylko przy filtrze stanu trzeba przebudować siatkę (kafelek może z niej wypaść).
func _on_status_changed() -> void:
	if not visible:
		return
	if _status_option.selected != StatusFilter.ALL:
		_rebuild()
		return
	for category in _section_categories():
		if _tiles.has(category["name"]):
			_update_tile(_tiles[category["name"]], category)
	_refresh_summary()
	_refresh_actions()


func _matches_filters(category: Dictionary) -> bool:
	var type: String = TYPE_FILTERS[_type_option.selected][1]
	if not type.is_empty() and _get_category_type(category) != type:
		return false
	var key: String = category["name"]
	match _status_option.selected:
		StatusFilter.FRESH:
			return not _is_used(key) and not category["questions"].is_empty()
		StatusFilter.USED:
			return _is_used(key)
		StatusFilter.EXCLUDED:
			return GameManager.is_category_excluded(key)
		StatusFilter.EMPTY:
			return category["questions"].is_empty()
	return true


func _make_tile(category: Dictionary) -> PanelContainer:
	var key: String = category["name"]
	var tile := PanelContainer.new()
	tile.custom_minimum_size = TILE_SIZE
	tile.tooltip_text = category["path"]
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	tile.add_child(vbox)
	var name_label := Label.new()
	name_label.text = CategoryManager.get_admin_name(key)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.max_lines_visible = 2
	name_label.custom_minimum_size.x = TILE_SIZE.x - 24
	name_label.add_theme_font_size_override("font_size", 17)
	vbox.add_child(name_label)
	var info_label := Label.new()
	info_label.add_theme_font_size_override("font_size", 12)
	info_label.add_theme_color_override("font_color", MUTED_COLOR)
	vbox.add_child(info_label)
	var status_label := Label.new()
	status_label.add_theme_font_size_override("font_size", 13)
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.clip_text = true
	vbox.add_child(status_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)
	var toggle := CheckButton.new()
	toggle.text = "W losowaniu"
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.flat = true # Bez żółtego tła "wciśniętego" przycisku z motywu konsoli.
	toggle.add_theme_font_size_override("font_size", 13)
	for color_name: String in ["font_color", "font_pressed_color", "font_hover_color", "font_hover_pressed_color", "font_focus_color"]:
		toggle.add_theme_color_override(color_name, Color(0.88, 0.9, 1.0))
	toggle.toggled.connect(func(pressed: bool) -> void: GameManager.set_category_excluded(key, not pressed))
	vbox.add_child(toggle)
	tile.set_meta("labels", [name_label, info_label, status_label])
	tile.set_meta("toggle", toggle)
	return tile


func _update_tile(tile: PanelContainer, category: Dictionary) -> void:
	var key: String = category["name"]
	var labels: Array = tile.get_meta("labels")
	var name_label: Label = labels[0]
	var info_label: Label = labels[1]
	var status_label: Label = labels[2]
	var toggle: CheckButton = tile.get_meta("toggle")
	var is_empty: bool = category["questions"].is_empty()
	var excluded := GameManager.is_category_excluded(key)
	var used := _is_used(key)

	var info: PackedStringArray = [CategoryManager.describe_question_count(key)]
	var type := _get_category_type(category)
	if TYPE_NAMES.has(type):
		info.append(TYPE_NAMES[type])
	if category["kind"] == CategoryManager.KIND_MUSIC and category["background"].is_empty():
		info.append("bez tła")
	info_label.text = "  ·  ".join(info)

	var status := "nowa"
	var status_color := FRESH_COLOR
	if is_empty:
		status = "pusta – brak pytań"
		status_color = WARNING_COLOR
	elif used:
		status = "zużyta w tej sesji" if _section == Section.FINAL else "zagrana w tej sesji"
		status_color = USED_COLOR
	var border := Color(1, 1, 1, 0.14)
	var border_width := 2
	var owner_index := -1 if _section == Section.FINAL else GameManager.get_roster_category_conflict(key, -1)
	if owner_index >= 0 and GameManager.roster[owner_index]["category"] == key:
		var owner_color := GameManager.get_roster_color(owner_index)
		status += "  ·  gracz: %s" % GameManager.roster[owner_index]["name"]
		border = owner_color.lightened(0.2)
		border_width = 3
	status_label.text = status
	status_label.add_theme_color_override("font_color", status_color)

	var background := Color(1, 1, 1, 0.05)
	if excluded:
		background = Color(EXCLUDED_COLOR, 0.12)
		if border_width == 2:
			border = Color(EXCLUDED_COLOR, 0.55)
	tile.add_theme_stylebox_override("panel", _make_style(background, border, border_width))
	name_label.add_theme_color_override("font_color",
			EXCLUDED_COLOR if excluded else (USED_COLOR if used else Color.WHITE))

	toggle.set_pressed_no_signal(not excluded)
	toggle.disabled = is_empty
	toggle.tooltip_text = "Wykluczona – losowanie ją pomija." if excluded else "Losowanie może ją wybrać."


func _make_style(background: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(10)
	return style


## Zwykła: zagrana w sesji; finałowa: zużyta w sesji.
func _is_used(key: String) -> bool:
	if CategoryManager.is_final_category(key):
		return GameManager.is_final_category_used(key)
	return GameManager.is_category_played(key)


## Muzyka / tekst / wideo (choć jedno wideo w kategorii) / zdjęcia.
func _get_category_type(category: Dictionary) -> String:
	if category["kind"] != CategoryManager.KIND_IMAGE:
		return category["kind"]
	for question: Dictionary in category["questions"]:
		if question["kind"] == CategoryManager.KIND_VIDEO:
			return CategoryManager.KIND_VIDEO
	return CategoryManager.KIND_IMAGE

#endregion


#region Akcje i podsumowanie

func _refresh_summary() -> void:
	_section_buttons[Section.REGULAR].text = "Zwykłe (%d)" % CategoryManager.categories.size()
	_section_buttons[Section.FINAL].text = "Finałowe (%d)" % CategoryManager.final_categories.size()
	var categories := _section_categories()
	var used := 0
	var excluded := 0
	for category in categories:
		used += 1 if _is_used(category["name"]) else 0
		excluded += 1 if GameManager.is_category_excluded(category["name"]) else 0
	if _section == Section.FINAL:
		_summary_label.text = "W puli rundy 3: %d / %d  ·  zużyte: %d  ·  wykluczone: %d" % [
			GameManager.get_unused_final_categories().size(), categories.size(), used, excluded,
		]
	else:
		_summary_label.text = "Nowe: %d  ·  zagrane: %d  ·  wykluczone: %d" % [categories.size() - used, used, excluded]
	if _tiles.size() != categories.size():
		_summary_label.text += "  ·  widoczne: %d" % _tiles.size()


func _refresh_actions() -> void:
	if not is_node_ready():
		return
	_reload_button.disabled = GameManager.phase == GameManager.Phase.DUEL
	var is_final := _section == Section.FINAL
	_reset_used_button.text = "Odnów pulę finałową" if is_final else "Odnów zagrane"
	_reset_used_button.tooltip_text = "Wszystkie kategorie finałowe wracają do puli rundy 3." if is_final \
			else "Oznacza wszystkie kategorie jako niezagrane (nowe) w tej sesji."
	_reset_used_button.disabled = (GameManager.used_final_categories if is_final else GameManager.played_categories).is_empty()
	_include_all_button.disabled = not _section_categories().any(
		func(category: Dictionary) -> bool: return GameManager.is_category_excluded(category["name"])
	)


func _on_reset_used_pressed() -> void:
	if _section == Section.FINAL:
		GameManager.reset_used_final_categories()
	else:
		GameManager.reset_played_categories()


func _on_include_all_pressed() -> void:
	for category in _section_categories():
		GameManager.set_category_excluded(category["name"], false)


func _on_open_folder_pressed() -> void:
	var path := CategoryManager.get_final_categories_dir() if _section == Section.FINAL \
			else CategoryManager.get_categories_dir()
	OS.shell_open(path)

#endregion
