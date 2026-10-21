class_name DuelScreen
extends Control
## Ekran pojedynku na oknie gry (TV) – przykrywa podłogę na czas pojedynku.
##
## Czysty widok: zegary, odliczanie, kara za pas, talia zdjęć i to, kto odpowiada,
## liczone są w GameManagerze (sterowanym z konsoli admina). Ten ekran je pokazuje,
## animuje i udźwiękawia (przez AudioManager):
## [br]- START: duże "3" / "2" (click) -> "1" (beep) -> pierwsze zdjęcie i zegar,
## [br]- każda sekunda aktywnego zegara: click; poprawna odpowiedź: correct,
## [br]- PAS: fahh, zegar gracza na czerwono, zdjęcie przyciemnione, licznik kary
##   3 -> 2 -> 1 -> 0 (każda sekunda: click i -1 s z zegara) z poprawną odpowiedzią
##   pod licznikiem, potem nowe zdjęcie,
## [br]- muzyka: bg_duel na czas pojedynku, potem powrót do bg_main,
## [br]- kategoria muzyczna: bg_duel milczy, na środku stoi obrazek tła kategorii,
##   a pytaniem jest automatycznie odtwarzany utwór .ogg (nazwa pliku = odpowiedź).

const FADE_DURATION := 0.35
const LOW_TIME := 10.0
const FEEDBACK_DURATION := 1.4
const INACTIVE_ALPHA := 0.4
const DIMMED_IMAGE := Color(0.25, 0.25, 0.25)
const ACCENT_COLOR := Color("ffd166")
const CORRECT_COLOR := Color("06d6a0")
const PASS_COLOR := Color("f8961e")
const DANGER_COLOR := Color("ef476f")

var _visibility_tween: Tween
var _image_tween: Tween
var _dim_tween: Tween
var _feedback_tween: Tween
var _pop_tween: Tween
var _side_tweens: Array[Tween] = [null, null]

@onready var _category_label: Label = %CategoryLabel
@onready var _image_rect: TextureRect = %ImageRect
@onready var _placeholder_label: Label = %PlaceholderLabel
@onready var _countdown_label: Label = %CountdownLabel
@onready var _penalty_box: Control = %PenaltyBox
@onready var _penalty_label: Label = %PenaltyLabel
@onready var _penalty_answer_label: Label = %PenaltyAnswerLabel
@onready var _feedback_label: Label = %FeedbackLabel
@onready var _pause_label: Label = %PauseLabel
@onready var _side_panels: Array[PanelContainer] = [%LeftPanel, %RightPanel]
@onready var _name_labels: Array[Label] = [%LeftName, %RightName]
@onready var _time_labels: Array[Label] = [%LeftTime, %RightTime]
@onready var _status_labels: Array[Label] = [%LeftStatus, %RightStatus]


func _ready() -> void:
	hide()
	modulate.a = 0.0
	_feedback_label.modulate.a = 0.0
	# Animacje skali od środka.
	for control: Control in [_image_rect, _countdown_label, _penalty_label]:
		control.resized.connect(func() -> void: control.pivot_offset = control.size * 0.5)

	GameManager.duel_started.connect(_on_duel_started)
	GameManager.duel_countdown_changed.connect(_on_countdown_changed)
	GameManager.duel_image_changed.connect(_on_duel_image_changed)
	GameManager.duel_turn_changed.connect(_set_active_side)
	GameManager.duel_time_updated.connect(_update_times)
	GameManager.duel_clock_ticked.connect(_on_clock_ticked)
	GameManager.duel_penalty_started.connect(_on_penalty_started)
	GameManager.duel_penalty_ticked.connect(_on_penalty_ticked)
	GameManager.duel_timeout.connect(_on_duel_timeout)
	GameManager.duel_ended.connect(_on_duel_ended)
	GameManager.state_changed.connect(_on_state_changed)


#region Sygnały GameManagera

func _on_duel_started(attacker_id: int, defender_id: int) -> void:
	_category_label.text = GameManager.get_duel_category_name().to_upper()
	for side in 2:
		var player_id := attacker_id if side == GameManager.ATTACKER_SIDE else defender_id
		_name_labels[side].text = GameManager.get_player_name(player_id)
		_side_panels[side].add_theme_stylebox_override("panel",
				_make_side_style(GameManager.get_player_color(player_id)))

	_kill(_image_tween)
	_kill(_feedback_tween)
	_image_rect.texture = null
	_feedback_label.modulate.a = 0.0
	_pause_label.hide()
	_countdown_label.hide()
	_hide_penalty(true)
	_placeholder_label.text = "PRZYGOTUJCIE SIĘ!"
	_placeholder_label.show()

	_update_times(GameManager.duel_times)
	_set_active_side(GameManager.duel_active_side)
	_set_status(GameManager.duel_active_side, "ZACZYNA", ACCENT_COLOR)
	AudioManager.stop_question()
	if GameManager.is_duel_music():
		# Pytaniami są utwory – muzyka tła milczy do końca pojedynku.
		AudioManager.stop_music(0.6)
		_category_label.text += "  •  JAKI TO UTWÓR?"
	else:
		AudioManager.play_music(AudioManager.MUSIC_DUEL)
	_fade_in()


## 3, 2 -> click, 1 -> beep. Zdjęcie pojawi się dopiero po "1".
func _on_countdown_changed(value: int) -> void:
	_placeholder_label.hide()
	_countdown_label.text = str(value)
	_countdown_label.show()
	_pop(_countdown_label)
	AudioManager.play_sfx(AudioManager.SFX_BEEP if value == 1 else AudioManager.SFX_CLICK)


func _on_duel_image_changed(image: Dictionary, previous_answer: String, action: int) -> void:
	_countdown_label.hide()
	_hide_penalty(false)

	var texture: Texture2D
	if image.get("kind") == CategoryManager.KIND_MUSIC:
		# Pytanie = utwór; na środku stały obrazek tła kategorii.
		texture = CategoryManager.load_texture(CategoryManager.get_background(GameManager.get_duel_category_name()))
		var stream := CategoryManager.load_audio(image.get("path", ""))
		AudioManager.play_question(stream)
		_placeholder_label.text = "JAKI TO UTWÓR?" if stream != null else "Nie udało się wczytać utworu"
	else:
		texture = CategoryManager.load_texture(image.get("path", ""))
		_placeholder_label.text = "Nie udało się wczytać zdjęcia"
	_image_rect.texture = texture
	_placeholder_label.visible = texture == null

	# Szybkie "wskoczenie" nowego zdjęcia.
	_kill(_image_tween)
	_image_rect.scale = Vector2.ONE * 0.94
	_image_rect.modulate.a = 0.0
	_image_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_image_tween.tween_property(_image_rect, "scale", Vector2.ONE, 0.18)
	_image_tween.tween_property(_image_rect, "modulate:a", 1.0, 0.12)

	# Po pasie odpowiedź była już widoczna w trakcie kary – tu tylko przy poprawnej.
	if action == GameManager.DuelAction.CORRECT:
		AudioManager.play_sfx(AudioManager.SFX_CORRECT)
		_show_feedback(previous_answer, CORRECT_COLOR, FEEDBACK_DURATION)


func _on_clock_ticked(_side: int, _seconds_left: int) -> void:
	AudioManager.play_sfx(AudioManager.SFX_CLICK)


## PAS: fahh, przyciemnione zdjęcie, licznik kary i poprawna odpowiedź pod nim.
## (W kategorii muzycznej utwór gra dalej – publiczność słyszy, czego nie odgadnięto.)
func _on_penalty_started(_side: int) -> void:
	AudioManager.play_sfx(AudioManager.SFX_PASS)
	_penalty_label.text = str(GameManager.PASS_PENALTY)
	_penalty_answer_label.text = GameManager.duel_image.get("answer", "?")
	_feedback_label.modulate.a = 0.0 # Nie dubluj odpowiedzi z poprzedniego "dobrze".
	_placeholder_label.hide() # Np. "JAKI TO UTWÓR?" w kategorii muzycznej bez tła.
	_penalty_box.show()
	_pop(_penalty_label)
	_tween_image_dim(DIMMED_IMAGE)
	_update_times(GameManager.duel_times) # Zegar gracza na czerwono.


## Każda sekunda kary: click i nowa liczba (2, 1, 0). Po zerze GameManager daje nowe zdjęcie.
func _on_penalty_ticked(_side: int, penalty_left: int) -> void:
	AudioManager.play_sfx(AudioManager.SFX_CLICK)
	_penalty_label.text = str(penalty_left)
	_pop(_penalty_label)


func _on_duel_timeout(loser_side: int) -> void:
	AudioManager.stop_question()
	_countdown_label.hide()
	_hide_penalty(true)
	var winner_side := 1 - loser_side
	_set_status(loser_side, "KONIEC CZASU!", DANGER_COLOR)
	_set_status(winner_side, "WYGRYWA!", CORRECT_COLOR)
	_tween_side(loser_side, INACTIVE_ALPHA)
	_tween_side(winner_side, 1.0)
	_update_times(GameManager.duel_times)
	var answer: String = GameManager.duel_image.get("answer", "")
	if not answer.is_empty():
		_show_feedback("Odpowiedź: %s" % answer, DANGER_COLOR, 0.0)


func _on_duel_ended() -> void:
	AudioManager.stop_question()
	AudioManager.play_music(AudioManager.MUSIC_MAIN)
	_fade_out()


func _on_state_changed() -> void:
	if GameManager.phase != GameManager.Phase.DUEL:
		return
	var paused := GameManager.duel_state == GameManager.DuelState.PAUSED
	_pause_label.visible = paused
	AudioManager.set_question_paused(paused)
	_update_times(GameManager.duel_times) # Kolor zegara po zakończeniu kary.

#endregion


#region Zegary i strony

func _update_times(times: PackedFloat32Array) -> void:
	var in_penalty := GameManager.duel_state == GameManager.DuelState.PENALTY
	for side in 2:
		var time := times[side]
		var is_active := side == GameManager.duel_active_side
		_time_labels[side].text = _format_time(time)
		var red := time <= 0.0 or (is_active and (in_penalty or time < LOW_TIME))
		_time_labels[side].add_theme_color_override("font_color", DANGER_COLOR if red else Color.WHITE)


## Powyżej 10 s pełne sekundy (zaokrąglone w górę), poniżej – z dziesiątymi częściami.
func _format_time(time: float) -> String:
	if time >= LOW_TIME:
		return str(ceili(time))
	return "%.1f" % time


func _set_active_side(active_side: int) -> void:
	for side in 2:
		var is_active := side == active_side
		_set_status(side, "ODPOWIADA" if is_active else "", ACCENT_COLOR)
		_tween_side(side, 1.0 if is_active else INACTIVE_ALPHA)
	_update_times(GameManager.duel_times)


func _set_status(side: int, text: String, color: Color) -> void:
	_status_labels[side].text = text
	_status_labels[side].add_theme_color_override("font_color", color)


func _tween_side(side: int, alpha: float) -> void:
	_kill(_side_tweens[side])
	_side_tweens[side] = create_tween()
	_side_tweens[side].tween_property(_side_panels[side], "modulate:a", alpha, 0.2)


func _make_side_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.darkened(0.55), 0.92)
	style.border_color = color.lightened(0.2)
	style.set_border_width_all(6)
	style.set_corner_radius_all(28)
	style.set_content_margin_all(24)
	return style

#endregion


#region Animacje

func _hide_penalty(instant: bool) -> void:
	_penalty_box.hide()
	if instant:
		_kill(_dim_tween)
		_image_rect.self_modulate = Color.WHITE
	else:
		_tween_image_dim(Color.WHITE)


## Przyciemnianie przez self_modulate – modulate:a jest zajęte przez "wskoczenie" zdjęcia.
func _tween_image_dim(target: Color) -> void:
	_kill(_dim_tween)
	_dim_tween = create_tween()
	_dim_tween.tween_property(_image_rect, "self_modulate", target, 0.2)


## Duża liczba "uderza" w ekran: skala 1.5 -> 1 i pojawienie się.
func _pop(label: Label) -> void:
	_kill(_pop_tween)
	label.scale = Vector2.ONE * 1.5
	label.modulate.a = 0.0
	_pop_tween = create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop_tween.tween_property(label, "scale", Vector2.ONE, 0.3)
	_pop_tween.tween_property(label, "modulate:a", 1.0, 0.12)


## [param hold] = 0 -> komunikat zostaje do końca pojedynku.
func _show_feedback(text: String, color: Color, hold: float) -> void:
	_kill(_feedback_tween)
	_feedback_label.text = text
	_feedback_label.add_theme_color_override("font_color", color)
	_feedback_tween = create_tween()
	_feedback_tween.tween_property(_feedback_label, "modulate:a", 1.0, 0.1)
	if hold > 0.0:
		_feedback_tween.tween_interval(hold)
		_feedback_tween.tween_property(_feedback_label, "modulate:a", 0.0, 0.3)


func _fade_in() -> void:
	_kill(_visibility_tween)
	show()
	_visibility_tween = create_tween()
	_visibility_tween.tween_property(self, "modulate:a", 1.0, FADE_DURATION)


func _fade_out() -> void:
	_kill(_visibility_tween)
	_visibility_tween = create_tween()
	_visibility_tween.tween_property(self, "modulate:a", 0.0, FADE_DURATION)
	_visibility_tween.tween_callback(hide)


func _kill(tween: Tween) -> void:
	if tween and tween.is_valid():
		tween.kill()

#endregion
