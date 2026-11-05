class_name CategoryPicker
extends Window
## Okienko wyboru kategorii w konsoli admina (gracz, runda rozstrzygająca, szybki pojedynek).
##
## Lista jest od razu widoczna w całości; wyszukiwarka i filtry są opcjonalne i tylko ją
## zawężają. Szukanie ignoruje wielkość liter i polskie znaki. Klawiatura: pisanie = szukanie,
## strzałki = ruch po siatce (góra/dół o wiersz, lewo/prawo o kolumnę), Enter = wybór, Esc = anuluj. Filtry zostają między otwarciami.
##
## Wpis listy ([method open]): [code]{ key, text, tooltip, icon, type, played, taken, pinned }[/code].
## [code]taken[/code] – kategoria zajęta (nie do wybrania), [code]pinned[/code] – wpis zawsze
## widoczny na początku listy, gdy pole szukania jest puste (np. "losowa kategoria").

signal picked(key: String)

const TYPE_ALL := ""
const TYPE_LABELS: Array[Array] = [
	["Wszystkie typy", TYPE_ALL],
	["Zdjęcia", CategoryManager.KIND_IMAGE],
	["Muzyka", CategoryManager.KIND_MUSIC],
	["Wideo", CategoryManager.KIND_VIDEO],
	["Tekst", CategoryManager.KIND_TEXT],
]
const CURRENT_COLOR := Color("ffd166")
const PLAYED_COLOR := Color(0.62, 0.64, 0.74)
const TAKEN_COLOR := Color(0.42, 0.43, 0.52)

var _items: Array[Dictionary] = []
## Wpisy aktualnie pokazane – indeksy odpowiadają wierszom ItemList.
var _shown_items: Array[Dictionary] = []
var _current_key := ""

@onready var _search_edit: LineEdit = %SearchEdit
@onready var _fresh_check: CheckBox = %FreshCheck
@onready var _free_check: CheckBox = %FreeCheck
@onready var _type_option: OptionButton = %TypeOption
@onready var _count_label: Label = %CountLabel
@onready var _list: ItemList = %CategoryItems
@onready var _empty_label: Label = %EmptyLabel
@onready var _cancel_button: Button = %CancelButton


func _ready() -> void:
	hide()
	for entry in TYPE_LABELS:
		_type_option.add_item(entry[0])
	close_requested.connect(hide)
	_cancel_button.pressed.connect(hide)
	_search_edit.text_changed.connect(_refresh.unbind(1))
	_search_edit.text_submitted.connect(_on_search_submitted)
	_fresh_check.toggled.connect(_refresh.unbind(1))
	_free_check.toggled.connect(_refresh.unbind(1))
	_type_option.item_selected.connect(_refresh.unbind(1))
	_list.item_clicked.connect(_on_item_clicked)


## Pokazuje okienko. [param show_free_filter] – filtr "Tylko wolne" ma sens przy graczach.
func open(window_title: String, items: Array[Dictionary], current_key: String, show_free_filter: bool) -> void:
	title = window_title
	_items = items
	_current_key = current_key
	_free_check.visible = show_free_filter
	_search_edit.clear()
	_refresh()
	popup_centered(size)
	_search_edit.grab_focus.call_deferred()
	_search_edit.edit.call_deferred()


func _refresh() -> void:
	var query := TextUtils.to_search_key(_search_edit.text.strip_edges())
	_shown_items.clear()
	for item in _items:
		if _matches(item, query):
			_shown_items.append(item)

	_list.clear()
	var selected_index := -1
	for i in _shown_items.size():
		var item := _shown_items[i]
		var index := _list.add_item(item["text"], item["icon"])
		_list.set_item_tooltip(index, item.get("tooltip", item["text"]))
		_list.set_item_disabled(index, item.get("taken", false))
		if item.get("taken", false):
			_list.set_item_custom_fg_color(index, TAKEN_COLOR)
		elif item.get("played", false):
			_list.set_item_custom_fg_color(index, PLAYED_COLOR)
		if item["key"] == _current_key:
			selected_index = index
			if not item.get("taken", false):
				_list.set_item_custom_fg_color(index, CURRENT_COLOR)

	if not query.is_empty():
		selected_index = _next_enabled(-1, 1) # Enter wybierze pierwszy pasujący wpis.
	if selected_index >= 0:
		_list.select(selected_index)
		_list.ensure_current_is_visible()

	var category_count := _items.filter(func(item: Dictionary) -> bool: return not item.get("pinned", false)).size()
	var shown_count := _shown_items.filter(func(item: Dictionary) -> bool: return not item.get("pinned", false)).size()
	_count_label.text = "Widoczne: %d / %d" % [shown_count, category_count]
	_empty_label.visible = _shown_items.is_empty()


func _matches(item: Dictionary, query: String) -> bool:
	if item.get("pinned", false):
		return query.is_empty()
	if _fresh_check.button_pressed and item.get("played", false):
		return false
	if _free_check.visible and _free_check.button_pressed and item.get("taken", false):
		return false
	var type: String = TYPE_LABELS[_type_option.selected][1]
	if type != TYPE_ALL and item.get("type", "") != type:
		return false
	return query.is_empty() or TextUtils.to_search_key(item["text"]).contains(query)


func _on_item_clicked(index: int, _position: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_LEFT:
		_pick(index)


func _on_search_submitted(_text: String) -> void:
	var selected := _list.get_selected_items()
	if not selected.is_empty():
		_pick(selected[0])


func _pick(index: int) -> void:
	if index < 0 or index >= _shown_items.size() or _shown_items[index].get("taken", false):
		return
	hide()
	picked.emit(_shown_items[index]["key"])


## W _input, a nie w sygnale window_input – klawisze mają działać też przy fokusie w polu szukania.
func _input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed:
		return
	match (event as InputEventKey).keycode:
		KEY_ESCAPE:
			hide()
		KEY_DOWN:
			_move_selection(_get_column_count())
		KEY_UP:
			_move_selection(-_get_column_count())
		KEY_RIGHT:
			_move_selection(1)
		KEY_LEFT:
			_move_selection(-1)
		_:
			return
	set_input_as_handled()


## [param step]: +-1 = sąsiednia kolumna, +-liczba kolumn = sąsiedni wiersz.
func _move_selection(step: int) -> void:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		_select_row(_next_enabled(-1, 1))
		return
	var current: int = selected[0]
	var next := _next_enabled(current, step)
	# W dół z kolumny, której brakuje w niepełnym ostatnim wierszu: ostatni wpis listy.
	if next < 0 and step > 1:
		var last := _next_enabled(_shown_items.size(), -1)
		if _get_row(last) > _get_row(current):
			next = last
	_select_row(next)


func _select_row(index: int) -> void:
	if index >= 0:
		_list.select(index)
		_list.ensure_current_is_visible()


## Liczba kolumn wynika z szerokości okna – odczyt z układu listy (pierwszy wiersz).
func _get_column_count() -> int:
	var columns := 0
	while columns < _list.item_count and _get_row(columns) == 0:
		columns += 1
	return maxi(columns, 1)


## Numer wiersza listy (po pozycji Y wpisu, -1 dla braku wpisu).
func _get_row(index: int) -> int:
	if index < 0 or index >= _list.item_count:
		return -1
	var row := 0
	for i in index:
		if _list.get_item_rect(i + 1).position.y > _list.get_item_rect(i).position.y:
			row += 1
	return row


## Najbliższy dostępny wiersz w danym kierunku (-1, gdy brak).
func _next_enabled(from_index: int, direction: int) -> int:
	var index := from_index + direction
	while index >= 0 and index < _shown_items.size():
		if not _shown_items[index].get("taken", false):
			return index
		index += direction
	return -1
