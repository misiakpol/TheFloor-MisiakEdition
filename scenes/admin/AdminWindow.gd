extends Window
## Konsola mistrza gry (osobne okno systemowe).
##
## Dwie zakładki, bez przewijania:
## [br]- [b]Konfiguracja[/b]: gracze (ręczne dodawanie / usuwanie + kategoria), podłoga,
##   kategorie z folderów, suwaki głośności,
## [br]- [b]Rozgrywka / Pojedynek[/b]: losowanie (ruletka) i wybór przeciwnika – a w fazie
##   DUEL w tym samym miejscu panel sterowania pojedynkiem.
## Konsola sama przełącza się na drugą zakładkę po wygenerowaniu podłogi i przy pojedynku.
## Okno zawiera wyłącznie UI – wywołuje metody GameManagera i reaguje na jego sygnały.
## Skróty w pojedynku: Enter / Spacja = START lub poprawna odpowiedź, P = pas.
## Dźwięki gra ekran TV (Main, DuelScreen) – konsola tylko wywołuje akcje.

const SETUP_TAB := 0
const GAME_TAB := 1
const LOG_TIME_COLOR := "#8a8fb0"
const ERROR_COLOR := "#ef476f"
const WARNING_COLOR := Color(1.0, 0.62, 0.62)
const ACTIVE_COLOR := Color("ffd166")
const INACTIVE_COLOR := Color(0.55, 0.57, 0.7)
const DANGER_COLOR := Color("ef476f")
const RANDOM_CATEGORY_TEXT := "(losowa kategoria)"

@onready var _tabs: TabContainer = %Tabs
@onready var _game_view: Control = %GameView
@onready var _duel_view: Control = %DuelView
@onready var _log: RichTextLabel = %Log

# Gracze
@onready var _player_name_edit: LineEdit = %PlayerNameEdit
@onready var _player_category_option: OptionButton = %PlayerCategoryOption
@onready var _add_player_button: Button = %AddPlayerButton
@onready var _player_list: ItemList = %PlayerList
@onready var _player_count_label: Label = %PlayerCountLabel
@onready var _update_player_button: Button = %UpdatePlayerButton
@onready var _remove_player_button: Button = %RemovePlayerButton
@onready var _clear_players_button: Button = %ClearPlayersButton

# Podłoga, kategorie, głośność
@onready var _columns_spin: SpinBox = %ColumnsSpin
@onready var _rows_spin: SpinBox = %RowsSpin
@onready var _fit_grid_button: Button = %FitGridButton
@onready var _shuffle_check: CheckBox = %ShuffleCheck
@onready var _generate_button: Button = %GenerateButton
@onready var _category_count_label: Label = %CategoryCountLabel
@onready var _reload_button: Button = %ReloadButton
@onready var _category_list: ItemList = %CategoryList
## Szyna AudioManagera -> [suwak, etykieta z %].
@onready var _volume_controls: Dictionary = {
	AudioManager.MUSIC_BUS: [%MusicVolumeSlider, %MusicVolumeValue],
	AudioManager.SFX_BUS: [%SfxVolumeSlider, %SfxVolumeValue],
	AudioManager.QUESTION_BUS: [%QuestionVolumeSlider, %QuestionVolumeValue],
}

# Rozgrywka
@onready var _status_label: Label = %StatusLabel
@onready var _random_player_button: Button = %RandomPlayerButton
@onready var _opponent_option: OptionButton = %OpponentOption
@onready var _duel_button: Button = %DuelButton
@onready var _cancel_button: Button = %CancelButton

# Pojedynek
@onready var _duel_title_label: Label = %DuelTitleLabel
@onready var _duel_category_label: Label = %DuelCategoryLabel
@onready var _duel_phase_label: Label = %DuelPhaseLabel
@onready var _side_name_labels: Array[Label] = [%AttackerNameLabel, %DefenderNameLabel]
@onready var _side_time_labels: Array[Label] = [%AttackerTimeLabel, %DefenderTimeLabel]
@onready var _answer_caption: Label = %AnswerCaption
@onready var _answer_label: Label = %AnswerLabel
@onready var _answer_preview: TextureRect = %AnswerPreview
@onready var _start_duel_button: Button = %StartDuelButton
@onready var _pause_button: Button = %PauseButton
@onready var _correct_button: Button = %CorrectButton
@onready var _pass_button: Button = %PassButton
@onready var _finish_duel_button: Button = %FinishDuelButton
@onready var _attacker_wins_button: Button = %AttackerWinsButton
@onready var _defender_wins_button: Button = %DefenderWinsButton
@onready var _abort_duel_button: Button = %AbortDuelButton


func _ready() -> void:
	_tabs.set_tab_title(SETUP_TAB, "Konfiguracja")
	_tabs.set_tab_title(GAME_TAB, "Rozgrywka / Pojedynek")
	for spin: SpinBox in [_columns_spin, _rows_spin]:
		spin.min_value = GameManager.MIN_GRID_SIZE
		spin.max_value = GameManager.MAX_GRID_SIZE

	var confirm_keys: Array[Key] = [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
	_start_duel_button.shortcut = _make_shortcut(confirm_keys)
	_correct_button.shortcut = _make_shortcut(confirm_keys)
	_pass_button.shortcut = _make_shortcut([KEY_P])

	_setup_volume_sliders()
	_connect_ui_signals()
	_connect_manager_signals()
	_populate_category_views()
	_populate_player_list()
	_refresh_ui()
	_append_log("Konsola gotowa. Folder kategorii: %s" % CategoryManager.get_categories_dir())
	if CategoryManager.categories.is_empty():
		_on_categories_load_failed("Brak kategorii – dodaj podfoldery ze zdjęciami i kliknij \"Skanuj foldery\".")
	_focus_player_name_edit.call_deferred()


func _connect_ui_signals() -> void:
	# Zamknięcie konsoli admina kończy całą grę.
	close_requested.connect(get_tree().quit)

	_player_name_edit.text_submitted.connect(func(_text: String) -> void: _on_add_player_pressed())
	_add_player_button.pressed.connect(_on_add_player_pressed)
	_update_player_button.pressed.connect(_on_update_player_pressed)
	_remove_player_button.pressed.connect(_on_remove_player_pressed)
	_clear_players_button.pressed.connect(GameManager.clear_roster)
	_player_list.item_selected.connect(_on_player_list_item_selected)

	_fit_grid_button.pressed.connect(_on_fit_grid_pressed)
	_generate_button.pressed.connect(_on_generate_pressed)
	_reload_button.pressed.connect(CategoryManager.reload)
	_random_player_button.pressed.connect(GameManager.select_random_player)
	_duel_button.pressed.connect(_on_duel_pressed)
	_cancel_button.pressed.connect(GameManager.cancel_selection)

	_start_duel_button.pressed.connect(GameManager.begin_duel)
	_pause_button.pressed.connect(GameManager.toggle_duel_pause)
	_correct_button.pressed.connect(GameManager.duel_correct)
	_pass_button.pressed.connect(GameManager.duel_pass)
	_finish_duel_button.pressed.connect(GameManager.finish_duel)
	_attacker_wins_button.pressed.connect(GameManager.resolve_duel.bind(true))
	_defender_wins_button.pressed.connect(GameManager.resolve_duel.bind(false))
	_abort_duel_button.pressed.connect(GameManager.cancel_selection)


func _connect_manager_signals() -> void:
	GameManager.state_changed.connect(_refresh_ui)
	GameManager.roster_changed.connect(_populate_player_list)
	GameManager.log_message.connect(_append_log)
	GameManager.floor_generated.connect(func(_columns: int, _rows: int) -> void: _tabs.current_tab = GAME_TAB)
	GameManager.duel_started.connect(func(_attacker: int, _defender: int) -> void: _tabs.current_tab = GAME_TAB)
	GameManager.duel_image_changed.connect(_on_duel_image_changed)
	GameManager.duel_turn_changed.connect(_update_turn_markers.unbind(1))
	GameManager.duel_time_updated.connect(_update_duel_times)
	GameManager.duel_countdown_changed.connect(_update_duel_phase_label.unbind(1))
	GameManager.duel_penalty_started.connect(_update_duel_phase_label.unbind(1))
	GameManager.duel_penalty_ticked.connect(_update_duel_phase_label.unbind(2))
	CategoryManager.categories_loaded.connect(_on_categories_loaded)
	CategoryManager.load_failed.connect(_on_categories_load_failed)


#region Handlery UI

## Enter w polu imienia = dodaj gracza; pole od razu czyste i gotowe na kolejne imię.
func _on_add_player_pressed() -> void:
	if GameManager.add_roster_player(_player_name_edit.text, _get_selected_category()):
		_player_name_edit.clear()
	_focus_player_name_edit.call_deferred()


## Deferred: LineEdit kończy obsługę Entera (i ew. wychodzi z trybu edycji) dopiero
## po sygnale text_submitted – focus i edycję przywracamy po nim.
func _focus_player_name_edit() -> void:
	if not _player_name_edit.is_visible_in_tree():
		return
	_player_name_edit.grab_focus()
	_player_name_edit.edit()


func _on_update_player_pressed() -> void:
	var index := _get_selected_player_index()
	if index >= 0 and GameManager.update_roster_player(index, _player_name_edit.text, _get_selected_category()):
		_player_list.select(index)
		_refresh_player_buttons()


func _on_remove_player_pressed() -> void:
	var index := _get_selected_player_index()
	if index >= 0:
		GameManager.remove_roster_player(index)
		_player_name_edit.clear()
		_focus_player_name_edit.call_deferred()


func _on_player_list_item_selected(index: int) -> void:
	var entry: Dictionary = GameManager.roster[index]
	_player_name_edit.text = entry["name"]
	_select_category(entry["category"])
	_refresh_player_buttons()


func _on_fit_grid_pressed() -> void:
	var grid_size := GameManager.suggest_grid_size(maxi(GameManager.roster.size(), 4))
	_columns_spin.value = grid_size.x
	_rows_spin.value = grid_size.y


func _on_generate_pressed() -> void:
	GameManager.generate_floor(int(_columns_spin.value), int(_rows_spin.value), _shuffle_check.button_pressed)


func _on_duel_pressed() -> void:
	var defender_id := _opponent_option.get_selected_id()
	if defender_id >= 0:
		GameManager.start_duel(defender_id)


func _on_volume_changed(value: float, bus: StringName) -> void:
	AudioManager.set_bus_volume_linear(bus, value)
	var value_label: Label = _volume_controls[bus][1]
	value_label.text = "%d%%" % roundi(value * 100.0)

#endregion


#region Handlery managerów

func _on_categories_loaded(count: int) -> void:
	_populate_category_views()
	_populate_player_list() # Odświeża ostrzeżenia o nieistniejących kategoriach.
	_append_log("Wczytano kategorie: %d" % count)


func _on_categories_load_failed(message: String) -> void:
	_append_log("[color=%s]%s[/color]" % [ERROR_COLOR, message])


func _on_duel_image_changed(question: Dictionary, _previous_answer: String, _action: int) -> void:
	_answer_label.text = question.get("answer", "?")
	# Ta sama tekstura co na TV – CategoryManager zwraca ją z cache.
	if question.get("kind") == CategoryManager.KIND_MUSIC:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ (UTWÓR)"
		_answer_preview.texture = CategoryManager.load_texture(
				CategoryManager.get_background(GameManager.get_duel_category_name()))
	else:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ"
		_answer_preview.texture = CategoryManager.load_texture(question.get("path", ""))

#endregion


#region Odświeżanie widoku – rozgrywka

func _refresh_ui() -> void:
	var phase: int = GameManager.phase
	var is_duel := phase == GameManager.Phase.DUEL
	_game_view.visible = not is_duel
	_duel_view.visible = is_duel
	# Konfiguracji nie zmieniamy w trakcie pojedynku.
	_generate_button.disabled = is_duel
	if is_duel:
		_refresh_duel_view()
		return

	var is_selected := phase == GameManager.Phase.PLAYER_SELECTED
	_populate_opponents()
	_random_player_button.disabled = phase not in [GameManager.Phase.IDLE, GameManager.Phase.PLAYER_SELECTED]
	_random_player_button.text = "Losowanie..." if phase == GameManager.Phase.ROLLING else "Losuj gracza"
	_opponent_option.disabled = not is_selected or _opponent_option.item_count == 0
	_duel_button.disabled = _opponent_option.disabled
	_cancel_button.disabled = not is_selected
	_status_label.text = _describe_state(phase)


func _describe_state(phase: int) -> String:
	if phase == GameManager.Phase.IDLE:
		return "Żywych graczy: %d. Wylosuj gracza." % GameManager.get_alive_player_ids().size()
	if phase == GameManager.Phase.ROLLING:
		return "Trwa losowanie (ruletka na ekranie TV)..."
	if phase == GameManager.Phase.PLAYER_SELECTED:
		return "Na ruchu: %s\nWybierz sąsiada do pojedynku." % \
				GameManager.describe_player(GameManager.selected_player_id)
	if phase == GameManager.Phase.GAME_OVER:
		return "Koniec gry! Wygeneruj nową podłogę (zakładka Konfiguracja)."
	return "Dodaj graczy, ustaw wymiary i wygeneruj podłogę (zakładka Konfiguracja)."


func _populate_opponents() -> void:
	_opponent_option.clear()
	if GameManager.phase != GameManager.Phase.PLAYER_SELECTED:
		return

	for player_id in GameManager.get_neighbor_player_ids(GameManager.selected_player_id):
		var category := GameManager.get_player_category(player_id)
		_opponent_option.add_item("%s — %s (%s)" % [
			GameManager.get_player_name(player_id), category, CategoryManager.describe_question_count(category),
		], player_id)

	if _opponent_option.item_count > 0:
		_opponent_option.select(0)

#endregion


#region Odświeżanie widoku – konfiguracja

func _setup_volume_sliders() -> void:
	for bus: StringName in _volume_controls:
		var slider: HSlider = _volume_controls[bus][0]
		slider.value = AudioManager.get_bus_volume_linear(bus)
		_on_volume_changed(slider.value, bus)
		slider.value_changed.connect(_on_volume_changed.bind(bus))


func _populate_player_list() -> void:
	_player_list.clear()
	for i in GameManager.roster.size():
		var entry: Dictionary = GameManager.roster[i]
		var category: String = entry["category"]
		var index := _player_list.add_item("%d. %s — %s" % [
			i + 1, entry["name"], category if not category.is_empty() else RANDOM_CATEGORY_TEXT,
		])
		if not category.is_empty() and not CategoryManager.has_category(category):
			_player_list.set_item_custom_fg_color(index, WARNING_COLOR)
			_player_list.set_item_tooltip(index, "Brak folderu tej kategorii – gracz dostanie losową.")

	_player_count_label.text = "Graczy na liście: %d" % GameManager.roster.size()
	_refresh_player_buttons()


func _refresh_player_buttons() -> void:
	var has_selection := _get_selected_player_index() >= 0
	_update_player_button.disabled = not has_selection
	_remove_player_button.disabled = not has_selection
	_clear_players_button.disabled = GameManager.roster.is_empty()


## Wypełnia listę kategorii (podgląd) i listę wyboru kategorii gracza.
func _populate_category_views() -> void:
	var previous_category := _get_selected_category()
	_player_category_option.clear()
	_player_category_option.add_item(RANDOM_CATEGORY_TEXT)
	_player_category_option.set_item_metadata(0, "")
	_category_list.clear()

	for category in CategoryManager.categories:
		var category_name: String = category["name"]
		var count_text := CategoryManager.describe_question_count(category_name)
		var is_music: bool = category["kind"] == CategoryManager.KIND_MUSIC
		_player_category_option.add_item("%s (%s)" % [category_name, count_text])
		_player_category_option.set_item_metadata(_player_category_option.item_count - 1, category_name)

		var index := _category_list.add_item("%s%s — %s" % ["[muz.] " if is_music else "", category_name, count_text])
		_category_list.set_item_tooltip(index, category["path"])
		if category["questions"].is_empty():
			_category_list.set_item_custom_fg_color(index, WARNING_COLOR)
			_category_list.set_item_tooltip(index, "Pusty folder: %s" % category["path"])
		elif is_music and category["background"].is_empty():
			_category_list.set_item_tooltip(index, "Kategoria muzyczna bez obrazka tła (dodaj np. tlo.jpg).")

	_select_category(previous_category)
	_category_count_label.text = "Kategorie: %d  (folder %s/)" % [
		CategoryManager.categories.size(), CategoryManager.CATEGORIES_DIR,
	]


func _get_selected_player_index() -> int:
	var selected := _player_list.get_selected_items()
	return selected[0] if not selected.is_empty() else -1


func _get_selected_category() -> String:
	var index := _player_category_option.selected
	if index <= 0:
		return ""
	return str(_player_category_option.get_item_metadata(index))


func _select_category(category_name: String) -> void:
	for i in _player_category_option.item_count:
		if str(_player_category_option.get_item_metadata(i)) == category_name:
			_player_category_option.select(i)
			return
	_player_category_option.select(0)

#endregion


#region Odświeżanie widoku – pojedynek

func _refresh_duel_view() -> void:
	var state: int = GameManager.duel_state
	var attacker_name := GameManager.get_player_name(GameManager.selected_player_id)
	var defender_name := GameManager.get_player_name(GameManager.defender_id)
	var is_ready := state == GameManager.DuelState.READY
	var is_running := state == GameManager.DuelState.RUNNING
	var is_paused := state == GameManager.DuelState.PAUSED
	var is_timeout := state == GameManager.DuelState.TIMEOUT

	_duel_title_label.text = "%s  vs  %s" % [attacker_name, defender_name]
	_duel_category_label.text = "Kategoria: %s%s" % [
		GameManager.get_duel_category_name(), "  (muzyczna)" if GameManager.is_duel_music() else "",
	]

	_start_duel_button.visible = is_ready
	# Pauza działa też w trakcie odliczania 3-2-1 i kary za pas.
	_pause_button.visible = not is_ready and not is_timeout
	_pause_button.text = "Wznów" if is_paused else "Pauza"
	_correct_button.disabled = not is_running
	_pass_button.disabled = not is_running
	_finish_duel_button.disabled = not is_timeout
	if is_timeout:
		_finish_duel_button.text = "Koniec pojedynku — %s wygrywa" % \
				GameManager.get_player_name(GameManager.get_duel_winner_id())
	else:
		_finish_duel_button.text = "Koniec pojedynku (gdy czyjś czas spadnie do zera)"
	_attacker_wins_button.text = "%s wygrywa" % attacker_name
	_defender_wins_button.text = "%s wygrywa" % defender_name

	if is_ready:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ"
		_answer_label.text = "Naciśnij START, gdy gracze są gotowi"
		_answer_preview.texture = null
	elif state == GameManager.DuelState.COUNTDOWN:
		_answer_label.text = "Odliczanie..."

	_update_duel_phase_label()
	_update_turn_markers()
	_update_duel_times(GameManager.duel_times)


func _update_duel_phase_label() -> void:
	var state: int = GameManager.duel_state
	var text := ""
	var color := Color(0.92, 0.93, 1)
	if state == GameManager.DuelState.READY:
		text = "Czeka na START"
	elif state == GameManager.DuelState.COUNTDOWN:
		text = "Odliczanie: %d" % GameManager.duel_countdown
		color = ACTIVE_COLOR
	elif state == GameManager.DuelState.RUNNING:
		text = "Zegar chodzi"
	elif state == GameManager.DuelState.PENALTY:
		text = "PAS – kara: jeszcze %d s (odpowiedź widoczna na TV)" % GameManager.duel_penalty_left
		color = DANGER_COLOR
	elif state == GameManager.DuelState.PAUSED:
		text = "PAUZA"
		color = ACTIVE_COLOR
	elif state == GameManager.DuelState.TIMEOUT:
		text = "Koniec czasu – zatwierdź wynik"
		color = DANGER_COLOR
	_duel_phase_label.text = text
	_duel_phase_label.add_theme_color_override("font_color", color)


func _update_turn_markers() -> void:
	for side in 2:
		var is_active := side == GameManager.duel_active_side
		var player_name := GameManager.get_player_name(GameManager.get_duel_player_id(side))
		_side_name_labels[side].text = ("» %s «" % player_name) if is_active else player_name
		_side_name_labels[side].add_theme_color_override("font_color", ACTIVE_COLOR if is_active else INACTIVE_COLOR)


func _update_duel_times(times: PackedFloat32Array) -> void:
	for side in 2:
		_side_time_labels[side].text = "%.1f s" % times[side]
		var is_active := side == GameManager.duel_active_side
		var in_penalty := is_active and GameManager.duel_state == GameManager.DuelState.PENALTY
		var color := DANGER_COLOR if times[side] <= 0.0 or in_penalty else (ACTIVE_COLOR if is_active else INACTIVE_COLOR)
		_side_time_labels[side].add_theme_color_override("font_color", color)

#endregion


func _make_shortcut(keys: Array[Key]) -> Shortcut:
	var events: Array = []
	for key in keys:
		var event := InputEventKey.new()
		event.keycode = key
		events.append(event)
	var shortcut := Shortcut.new()
	shortcut.events = events
	return shortcut


func _append_log(text: String) -> void:
	_log.append_text("[color=%s]%s[/color]  %s\n" % [
		LOG_TIME_COLOR, Time.get_time_string_from_system(), text,
	])
