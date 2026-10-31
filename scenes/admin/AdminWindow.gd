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
const STATS_TAB := 2
const USED_COLOR := Color(0.5, 0.52, 0.62)
## Kategorie w sesji: zielona kropka = nowa (jeszcze nie grana), szara = już zagrana.
const FRESH_DOT_COLOR := Color("06d6a0")
const PLAYED_DOT_COLOR := Color(0.45, 0.47, 0.58)
const PLAYED_SUFFIX := "  · zagrana"
## Kolumny tabeli rankingu: [nagłówek, wyrównanie do prawej?].
const RANKING_COLUMNS := [
	["#", true], ["Gracz", false], ["Tytuły", true], ["Pojedynki W/P", true], ["% wygr.", true],
	["Pola", true], ["Seria", true], ["Poprawne", true], ["Pasy", true], ["Śr. czas", true],
	["Najszybsza", true], ["Finał (rundy)", true],
]
const LOG_TIME_COLOR := "#8a8fb0"
const ERROR_COLOR := "#ef476f"
const WARNING_COLOR := Color(1.0, 0.62, 0.62)
const ACTIVE_COLOR := Color("ffd166")
const INACTIVE_COLOR := Color(0.55, 0.57, 0.7)
const DANGER_COLOR := Color("ef476f")
const RANDOM_CATEGORY_TEXT := "(losowa kategoria)"

## Ostatnia liczba graczy ustawiona automatycznie z listy (do wykrycia ręcznej zmiany).
var _synced_player_count := GameManager.MIN_PLAYERS

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
@onready var _player_count_spin: SpinBox = %PlayerCountSpin
@onready var _grid_preview_label: Label = %GridPreviewLabel
@onready var _shuffle_check: CheckBox = %ShuffleCheck
@onready var _generate_button: Button = %GenerateButton
@onready var _category_count_label: Label = %CategoryCountLabel
@onready var _reload_button: Button = %ReloadButton
@onready var _category_list: ItemList = %CategoryList
@onready var _reset_played_button: Button = %ResetPlayedButton
## Ikonki statusu kategorii (tworzone w kodzie – bez plików graficznych).
@onready var _fresh_icon: Texture2D = _make_dot_icon(FRESH_DOT_COLOR)
@onready var _played_icon: Texture2D = _make_dot_icon(PLAYED_DOT_COLOR)
@onready var _final_title: Label = %FinalTitle
@onready var _final_category_list: ItemList = %FinalCategoryList
@onready var _final_category_option: OptionButton = %FinalCategoryOption
@onready var _reset_final_pool_button: Button = %ResetFinalPoolButton

# Statystyki
@onready var _ranking_tree: Tree = %RankingTree
@onready var _facts_label: RichTextLabel = %FactsLabel
@onready var _reset_stats_button: Button = %ResetStatsButton
## Szyna AudioManagera -> [suwak, etykieta z %].
@onready var _duel_time_spin: SpinBox = %DuelTimeSpin
@onready var _save_settings_button: Button = %SaveSettingsButton
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
## Podgląd pytania-wideo (wyciszony – dźwięk gra tylko na TV).
@onready var _answer_video_box: AspectRatioContainer = %AnswerVideoBox
@onready var _answer_video: VideoStreamPlayer = %AnswerVideo
var _answer_video_started_ms := 0
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
	_tabs.set_tab_title(STATS_TAB, "Statystyki")
	_setup_ranking_tree()
	_refresh_stats()
	_player_count_spin.min_value = GameManager.MIN_PLAYERS
	_player_count_spin.max_value = GameManager.MAX_PLAYERS

	var confirm_keys: Array[Key] = [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
	_start_duel_button.shortcut = _make_shortcut(confirm_keys)
	_correct_button.shortcut = _make_shortcut(confirm_keys)
	_pass_button.shortcut = _make_shortcut([KEY_P])

	_setup_volume_sliders()
	_setup_game_settings()
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

	_player_count_spin.value_changed.connect(_on_player_count_changed)
	_generate_button.pressed.connect(_on_generate_pressed)
	_reload_button.pressed.connect(CategoryManager.reload)
	_final_category_option.item_selected.connect(_on_final_category_selected)
	_reset_final_pool_button.pressed.connect(GameManager.reset_used_final_categories)
	_reset_played_button.pressed.connect(GameManager.reset_played_categories)
	_reset_stats_button.pressed.connect(_on_reset_stats_pressed)
	_random_player_button.pressed.connect(GameManager.select_random_player)
	_duel_button.pressed.connect(_on_duel_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)

	_start_duel_button.pressed.connect(GameManager.begin_duel)
	_pause_button.pressed.connect(GameManager.toggle_duel_pause)
	_correct_button.pressed.connect(GameManager.duel_correct)
	_pass_button.pressed.connect(GameManager.duel_pass)
	_finish_duel_button.pressed.connect(GameManager.finish_duel)
	_attacker_wins_button.pressed.connect(GameManager.resolve_duel.bind(true))
	_defender_wins_button.pressed.connect(GameManager.resolve_duel.bind(false))
	_abort_duel_button.pressed.connect(GameManager.cancel_selection)


func _connect_manager_signals() -> void:
	# Podgląd wideo: pętla (gdy brak VideoStreamPlayer.loop) i stop po pojedynku.
	_answer_video.finished.connect(func() -> void:
		if _answer_video.stream == null:
			return
		if Time.get_ticks_msec() - _answer_video_started_ms < 300:
			_show_answer_video(null) # Uszkodzony plik – bez pętli błędów.
			return
		_answer_video.play()
		_answer_video_started_ms = Time.get_ticks_msec()
	)
	GameManager.duel_ended.connect(_show_answer_video.bind(null))
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
	GameManager.used_final_categories_changed.connect(_populate_final_categories)
	GameManager.played_categories_changed.connect(_on_played_categories_changed)
	StatsManager.stats_changed.connect(_refresh_stats)


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


## Liczba graczy nie może spaść poniżej listy; podgląd pokazuje, jaka wyjdzie siatka.
func _on_player_count_changed(value: float) -> void:
	var minimum := maxi(GameManager.roster.size(), GameManager.MIN_PLAYERS)
	if value < minimum:
		_player_count_spin.set_value_no_signal(minimum)
	var count := int(_player_count_spin.value)
	var grid := GameManager.get_grid_size_for(count)
	_grid_preview_label.text = "siatka %d x %d" % [grid.x, grid.y]
	var empty := grid.x * grid.y - count
	if empty > 0:
		_grid_preview_label.text += " (%d pust%s)" % [empty, "e" if empty < 5 else "ych"]


func _on_generate_pressed() -> void:
	GameManager.generate_floor(int(_player_count_spin.value), _shuffle_check.button_pressed)


## Po wygranym pojedynku ten przycisk to "zejście z podłogi" (wyklucza z najbliższego losowania).
func _on_cancel_pressed() -> void:
	if GameManager.selected_is_duel_winner:
		GameManager.step_down()
	else:
		GameManager.cancel_selection()


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
	_show_answer_video(null)
	if question.get("kind") == CategoryManager.KIND_VIDEO:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ (WIDEO)"
		_show_answer_video(CategoryManager.load_video(question.get("path", "")))
	elif question.get("kind") == CategoryManager.KIND_MUSIC:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ (UTWÓR)"
		_answer_preview.texture = CategoryManager.load_texture(
				CategoryManager.get_background(GameManager.get_duel_category_key()))
	else:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ"
		_answer_preview.texture = CategoryManager.load_texture(question.get("path", ""))

#endregion


## Wyciszony podgląd wideo w pętli zamiast obrazka; null = powrót do podglądu obrazka.
func _show_answer_video(video: VideoStream) -> void:
	_answer_video.stop()
	_answer_video.stream = video
	_answer_video_box.visible = video != null
	_answer_preview.visible = video == null
	if video == null:
		return
	if "loop" in _answer_video:
		_answer_video.set("loop", true)
	_answer_video.play()
	_answer_video_started_ms = Time.get_ticks_msec()
	await get_tree().process_frame
	var texture := _answer_video.get_video_texture()
	if texture and texture.get_height() > 0:
		_answer_video_box.ratio = float(texture.get_width()) / texture.get_height()


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
	_cancel_button.text = "Zwycięzca schodzi z podłogi" if GameManager.selected_is_duel_winner else "Anuluj wybór"
	_status_label.text = _describe_state(phase)


func _describe_state(phase: int) -> String:
	if phase == GameManager.Phase.IDLE:
		return "Żywych graczy: %d. Wylosuj gracza.\n%s" % [
			GameManager.get_alive_player_ids().size(), _describe_roll_pool(),
		]
	if phase == GameManager.Phase.ROLLING:
		return "Trwa losowanie (ruletka na ekranie TV)..."
	if phase == GameManager.Phase.PLAYER_SELECTED:
		if GameManager.selected_is_duel_winner:
			return "Zwycięzca: %s\nWalczy dalej (wybierz sąsiada) albo schodzi z podłogi." % \
					GameManager.describe_player(GameManager.selected_player_id)
		return "Na ruchu: %s\nWybierz sąsiada do pojedynku." % \
				GameManager.describe_player(GameManager.selected_player_id)
	if phase == GameManager.Phase.GAME_OVER:
		return "Koniec gry! Wygeneruj nową podłogę (zakładka Konfiguracja)."
	return "Dodaj graczy, ustaw wymiary i wygeneruj podłogę (zakładka Konfiguracja)."


## Kto jest w puli ruletki (priorytet: gracze bez pojedynku; bez tego, kto zszedł z podłogi).
func _describe_roll_pool() -> String:
	var pool := GameManager.get_roll_pool()
	var fresh := pool.all(func(id: int) -> bool: return GameManager.get_player_duel_count(id) == 0)
	var text := "Pula losowania: %d (%s)" % [
		pool.size(), "jeszcze bez pojedynku" if fresh else "wszyscy już walczyli",
	]
	if GameManager.last_stepped_down_player >= 0:
		text += ", bez: %s" % GameManager.get_player_name(GameManager.last_stepped_down_player)
	return text


func _populate_opponents() -> void:
	_opponent_option.clear()
	if GameManager.phase != GameManager.Phase.PLAYER_SELECTED:
		return

	for player_id in GameManager.get_neighbor_player_ids(GameManager.selected_player_id):
		var category := GameManager.get_player_category(player_id)
		_opponent_option.add_icon_item(_category_icon(category), "%s — %s (%s)%s" % [
			GameManager.get_player_name(player_id), category, CategoryManager.describe_question_count(category),
			PLAYED_SUFFIX if GameManager.is_category_played(category) else "",
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
		slider.value_changed.connect(_mark_settings_dirty.unbind(1))


## Czas na odpowiedź + zapis ustawień (wartości wczytane przez SettingsManager przy starcie).
func _setup_game_settings() -> void:
	_duel_time_spin.min_value = GameManager.MIN_DUEL_TIME
	_duel_time_spin.max_value = GameManager.MAX_DUEL_TIME
	_duel_time_spin.value = GameManager.duel_time
	_duel_time_spin.value_changed.connect(func(value: float) -> void:
		GameManager.set_duel_time(value)
		_mark_settings_dirty()
	)
	_save_settings_button.pressed.connect(_on_save_settings_pressed)
	SettingsManager.settings_saved.connect(
			func(path: String) -> void: _append_log("Zapisano ustawienia: %s" % path))


func _mark_settings_dirty() -> void:
	_save_settings_button.text = "Zapisz ustawienia *"


func _on_save_settings_pressed() -> void:
	if SettingsManager.save_settings():
		_save_settings_button.text = "Zapisz ustawienia"
	else:
		_on_categories_load_failed("Nie udało się zapisać ustawień – szczegóły w konsoli Godota.")


func _populate_player_list() -> void:
	_player_list.clear()
	for i in GameManager.roster.size():
		var entry: Dictionary = GameManager.roster[i]
		var category: String = entry["category"]
		var index := _player_list.add_item("%d. %s — %s%s" % [
			i + 1, entry["name"], category if not category.is_empty() else RANDOM_CATEGORY_TEXT,
			PLAYED_SUFFIX if GameManager.is_category_played(category) else "",
		], _category_icon(category) if not category.is_empty() else null)
		if not category.is_empty() and not CategoryManager.has_category(category):
			_player_list.set_item_custom_fg_color(index, WARNING_COLOR)
			_player_list.set_item_tooltip(index, "Brak folderu tej kategorii – gracz dostanie losową.")

	_player_count_label.text = "Graczy na liście: %d" % GameManager.roster.size()
	# Liczba graczy na podłodze nadąża za listą, chyba że admin ręcznie ją zwiększył.
	var roster_count := maxi(GameManager.roster.size(), GameManager.MIN_PLAYERS)
	if int(_player_count_spin.value) == _synced_player_count or _player_count_spin.value < roster_count:
		_player_count_spin.value = roster_count
	_synced_player_count = roster_count
	_on_player_count_changed(_player_count_spin.value)
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
		var played := GameManager.is_category_played(category_name)
		var played_text := PLAYED_SUFFIX if played else ""
		_player_category_option.add_icon_item(_category_icon(category_name),
				"%s (%s)%s" % [category_name, count_text, played_text])
		_player_category_option.set_item_metadata(_player_category_option.item_count - 1, category_name)

		var index := _category_list.add_item("%s%s — %s%s" % [
			"[muz.] " if is_music else "", category_name, count_text, played_text,
		], _category_icon(category_name))
		_category_list.set_item_tooltip(index, category["path"])
		if played:
			_category_list.set_item_custom_fg_color(index, USED_COLOR)
			_category_list.set_item_tooltip(index, "Zagrana w tej sesji – losowanie wybierze ją dopiero, gdy zabraknie nowych.")
		if category["questions"].is_empty():
			_category_list.set_item_custom_fg_color(index, WARNING_COLOR)
			_category_list.set_item_tooltip(index, "Pusty folder: %s" % category["path"])
		elif is_music and category["background"].is_empty():
			_category_list.set_item_tooltip(index, "Kategoria muzyczna bez obrazka tła (dodaj np. tlo.jpg).")

	_select_category(previous_category)
	var played_count := CategoryManager.categories.filter(
		func(category: Dictionary) -> bool: return GameManager.is_category_played(category["name"])
	).size()
	_category_count_label.text = "Kategorie: %d  ·  nowe: %d  ·  zagrane: %d" % [
		CategoryManager.categories.size(), CategoryManager.categories.size() - played_count, played_count,
	]
	_reset_played_button.disabled = GameManager.played_categories.is_empty()
	_populate_final_categories()


func _on_played_categories_changed() -> void:
	_populate_category_views()
	_populate_player_list()
	_populate_opponents()


func _category_icon(category_name: String) -> Texture2D:
	return _played_icon if GameManager.is_category_played(category_name) else _fresh_icon


## Mała, wygładzona kropka (14x14) – ikonka statusu kategorii.
func _make_dot_icon(color: Color) -> Texture2D:
	var icon_size := 14
	var image := Image.create(icon_size, icon_size, false, Image.FORMAT_RGBA8)
	var center := Vector2(icon_size, icon_size) * 0.5
	for y in icon_size:
		for x in icon_size:
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(center)
			var alpha := clampf(icon_size * 0.38 - distance + 0.5, 0.0, 1.0)
			image.set_pixel(x, y, Color(color, alpha))
	return ImageTexture.create_from_image(image)


## Podgląd folderu "kategorie final" + ręczny wybór kategorii rundy rozstrzygającej.
## Lista wyboru: losowa (domyślnie), kategorie finałowe, a na końcu zwykłe – na wszelki wypadek.
func _populate_final_categories() -> void:
	_final_category_list.clear()
	for category in CategoryManager.final_categories:
		var key: String = category["name"]
		var index := _final_category_list.add_item("%s — %s" % [
			CategoryManager.get_admin_name(key), CategoryManager.describe_question_count(key),
		])
		_final_category_list.set_item_tooltip(index, category["path"])
		if category["questions"].is_empty():
			_final_category_list.set_item_custom_fg_color(index, WARNING_COLOR)
		elif GameManager.is_final_category_used(key):
			# Zagrana już w tej sesji – nie wejdzie do losowania.
			_final_category_list.set_item_text(index, "[zużyta] " + _final_category_list.get_item_text(index))
			_final_category_list.set_item_custom_fg_color(index, USED_COLOR)
			_final_category_list.set_item_tooltip(index, "Zagrana w tej sesji – pominięta w losowaniu.")
	var unused_count := GameManager.get_unused_final_categories().size()
	_final_title.text = "Finałowe (runda 3): %d / %d w puli" % [unused_count, CategoryManager.final_categories.size()]
	_reset_final_pool_button.disabled = GameManager.used_final_categories.is_empty()

	_final_category_option.clear()
	_final_category_option.add_item("(losowa z puli: %d niezużytych)" % unused_count)
	_final_category_option.set_item_metadata(0, "")
	for key in CategoryManager.get_final_category_keys():
		_final_category_option.add_item("[finał] %s" % CategoryManager.get_admin_name(key))
		_final_category_option.set_item_metadata(_final_category_option.item_count - 1, key)
	for category_name in CategoryManager.get_category_names():
		if not CategoryManager.get_questions(category_name).is_empty():
			_final_category_option.add_item(category_name)
			_final_category_option.set_item_metadata(_final_category_option.item_count - 1, category_name)

	# Zachowaj wybór admina (np. po "Skanuj foldery"), jeśli kategoria nadal istnieje.
	var selected_index := 0
	for i in _final_category_option.item_count:
		if str(_final_category_option.get_item_metadata(i)) == GameManager.final_category_override:
			selected_index = i
	_final_category_option.select(selected_index)
	if selected_index == 0 and not GameManager.final_category_override.is_empty():
		GameManager.set_final_category_override("")


func _on_final_category_selected(index: int) -> void:
	GameManager.set_final_category_override(str(_final_category_option.get_item_metadata(index)))


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
	if GameManager.is_final:
		_duel_title_label.text = "%s\n%s  %d : %d  %s" % [
			GameManager.get_final_round_title(), attacker_name,
			GameManager.final_score[GameManager.ATTACKER_SIDE],
			GameManager.final_score[GameManager.DEFENDER_SIDE], defender_name,
		]
	_duel_category_label.text = "Kategoria: %s%s%s" % [
		GameManager.get_duel_category_name(),
		"  (muzyczna)" if GameManager.is_duel_music() else "",
		"  [kategoria finałowa]" if CategoryManager.is_final_category(GameManager.get_duel_category_key()) else "",
	]
	# W finale przycisk zamyka RUNDĘ (do 2 wygranych), a nie cały pojedynek.
	var finish_what := "Koniec rundy" if GameManager.is_final else "Koniec pojedynku"
	var wins_what := "wygrywa rundę" if GameManager.is_final else "wygrywa"

	_start_duel_button.visible = is_ready
	# Pauza działa też w trakcie odliczania 3-2-1 i kary za pas.
	_pause_button.visible = not is_ready and not is_timeout
	_pause_button.text = "Wznów" if is_paused else "Pauza"
	_correct_button.disabled = not is_running
	_pass_button.disabled = not is_running
	_finish_duel_button.disabled = not is_timeout
	if is_timeout:
		_finish_duel_button.text = "%s — %s %s" % [
			finish_what, GameManager.get_player_name(GameManager.get_duel_winner_id()), wins_what,
		]
	else:
		_finish_duel_button.text = "%s (gdy czyjś czas spadnie do zera)" % finish_what
	_attacker_wins_button.text = "%s %s" % [attacker_name, wins_what]
	_defender_wins_button.text = "%s %s" % [defender_name, wins_what]

	if is_ready:
		_answer_caption.text = "POPRAWNA ODPOWIEDŹ"
		_answer_label.text = "Naciśnij START, gdy gracze są gotowi"
		_answer_preview.texture = null
		_show_answer_video(null)
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


#region Statystyki

func _setup_ranking_tree() -> void:
	_ranking_tree.columns = RANKING_COLUMNS.size()
	for i in RANKING_COLUMNS.size():
		_ranking_tree.set_column_title(i, RANKING_COLUMNS[i][0])
		_ranking_tree.set_column_expand(i, i == 1) # Rozszerza się tylko kolumna z imieniem.
		_ranking_tree.set_column_clip_content(i, i == 1)
		if i == 0:
			_ranking_tree.set_column_custom_minimum_width(i, 44) # Bez tego "#" ma szerokość 0.
		if RANKING_COLUMNS[i][1]:
			_ranking_tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT)


func _refresh_stats() -> void:
	_ranking_tree.clear()
	var root := _ranking_tree.create_item()
	for entry in StatsManager.get_ranking():
		var item := _ranking_tree.create_item(root)
		var values := [
			str(entry["rank"]),
			entry["name"],
			str(entry["titles"]),
			"%d / %d" % [entry["duels_won"], entry["duels_lost"]],
			"%d%%" % roundi(entry["win_rate"] * 100.0) if entry["duels"] > 0 else "-",
			str(entry["tiles_captured"]),
			str(entry["best_streak"]),
			str(entry["correct"]),
			str(entry["passes"]),
			_format_seconds(entry["avg_answer"]),
			_format_seconds(entry["fastest"]),
			str(entry["final_rounds_won"]),
		]
		for i in values.size():
			item.set_text(i, values[i])
			if RANKING_COLUMNS[i][1]:
				item.set_text_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT)
		# Podium: złoto / srebro / brąz.
		if entry["rank"] <= 3 and (entry["titles"] > 0 or entry["duels_won"] > 0):
			var medal: Color = [Color("ffd166"), Color("d9dbe8"), Color("e09f6b")][entry["rank"] - 1]
			for i in values.size():
				item.set_custom_color(i, medal)
	_facts_label.text = _build_facts_text()


func _build_facts_text() -> String:
	var s := StatsManager.session
	if s["games_started"] == 0:
		return "[color=#8a8fb0]Brak danych – statystyki pojawią się po wygenerowaniu podłogi.[/color]"

	var answers: int = s["correct"] + s["passes"]
	var lines: PackedStringArray = [
		"Gry: [b]%d[/b] rozpoczętych, [b]%d[/b] zakończonych  •  Pojedynki: [b]%d[/b]  •  Finały: [b]%d[/b] (rund: %d)" % [
			s["games_started"], s["games_finished"], s["duels"], s["finals"], s["final_rounds"],
		],
		"Odpowiedzi: [b]%d[/b] poprawnych, [b]%d[/b] pasów (%s pasów)  •  Przegrane czasem: [b]%d[/b]" % [
			s["correct"], s["passes"],
			"%d%%" % roundi(100.0 * s["passes"] / answers) if answers > 0 else "0%", s["timeouts"],
		],
	]
	var fastest := StatsManager.fastest_answer
	if not fastest.is_empty():
		lines.append("Najszybsza odpowiedź: [b]%s[/b] – „%s” w %s (%s)" % [
			fastest["player"], fastest["answer"], _format_seconds(fastest["seconds"]), fastest["category"],
		])
	var slowest := StatsManager.slowest_answer
	if not slowest.is_empty() and slowest != fastest:
		lines.append("Najdłuższe zgadywanie: [b]%s[/b] – „%s” po %s (%s)" % [
			slowest["player"], slowest["answer"], _format_seconds(slowest["seconds"]), slowest["category"],
		])
	var category := StatsManager.get_most_played_category()
	if not category.is_empty():
		lines.append("Najczęściej grana kategoria: [b]%s[/b] (%d×)" % [category["name"], category["plays"]])
	var passed := StatsManager.get_most_passed_answer()
	if not passed.is_empty():
		lines.append("Najtrudniejsza zagadka (najwięcej pasów): [b]„%s”[/b] (%d×)" % [passed["name"], passed["plays"]])
	var ranking := StatsManager.get_ranking()
	if not ranking.is_empty() and (ranking[0]["titles"] > 0 or ranking[0]["duels_won"] > 0):
		lines.append("[color=#ffd166]Lider sesji: [b]%s[/b][/color]" % ranking[0]["name"])
	return "\n".join(lines)


## "4.2 s" albo "-" dla braku danych (wartość ujemna).
func _format_seconds(seconds: float) -> String:
	return "-" if seconds < 0.0 else "%.1f s" % seconds


## Statystyk nie da się odtworzyć – wymagamy dwóch kliknięć w ciągu 3 s.
func _on_reset_stats_pressed() -> void:
	if _reset_stats_button.text != "Na pewno? Kliknij ponownie":
		_reset_stats_button.text = "Na pewno? Kliknij ponownie"
		get_tree().create_timer(3.0).timeout.connect(
				func() -> void: _reset_stats_button.text = "Wyczyść statystyki")
		return
	_reset_stats_button.text = "Wyczyść statystyki"
	StatsManager.reset()
	_append_log("Wyczyszczono statystyki sesji.")

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
