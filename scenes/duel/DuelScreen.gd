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

## Imię zwycięzcy ostatnio rozstrzygniętej rundy finału (pokazywane przed kolejną rundą).
var _last_round_winner := ""

var _intro_tween: Tween

@onready var _final_intro: Control = %FinalIntro
@onready var _intro_band: ColorRect = %IntroBand
@onready var _intro_label: Label = %IntroLabel
@onready var _duel_caption: Label = %DuelCaption
@onready var _category_label: Label = %CategoryLabel
@onready var _image_rect: TextureRect = %ImageRect
## Pytanie-wideo: AspectRatioContainer (proporcje filmu) + VideoStreamPlayer na szynie Questions.
@onready var _video_box: AspectRatioContainer = %VideoBox
@onready var _video_rect: VideoStreamPlayer = %VideoRect
## Film, który "kończy się" szybciej niż to od startu, uznajemy za uszkodzony (bez pętli błędów).
const BROKEN_VIDEO_MS := 300
## Ile razy (co 0.1 s) czekamy na pierwszą klatkę, zanim uznamy plik za uszkodzony.
const VIDEO_FIRST_FRAME_CHECKS := 10
var _video_started_ms := 0
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
	_video_rect.finished.connect(_on_video_finished)
	GameManager.duel_countdown_changed.connect(_on_countdown_changed)
	GameManager.duel_image_changed.connect(_on_duel_image_changed)
	GameManager.duel_turn_changed.connect(_set_active_side)
	GameManager.duel_time_updated.connect(_update_times)
	GameManager.duel_clock_ticked.connect(_on_clock_ticked)
	GameManager.duel_penalty_started.connect(_on_penalty_started)
	GameManager.duel_penalty_ticked.connect(_on_penalty_ticked)
	GameManager.duel_timeout.connect(_on_duel_timeout)
	GameManager.duel_ended.connect(_on_duel_ended)
	GameManager.final_round_finished.connect(_on_final_round_finished)
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
	_stop_video()
	_image_rect.texture = null
	_feedback_label.modulate.a = 0.0
	_pause_label.hide()
	_countdown_label.hide()
	_hide_penalty(true)
	_placeholder_label.text = "PRZYGOTUJCIE SIĘ!"
	_duel_caption.text = "POJEDYNEK"
	if GameManager.is_final:
		# Np. "FINAŁ · DOGRYWKA  •  1 : 0" (wynik w rundach: lewy gracz : prawy gracz).
		_duel_caption.text = "%s  •  %d : %d" % [
			GameManager.get_final_round_title(),
			GameManager.final_score[GameManager.ATTACKER_SIDE],
			GameManager.final_score[GameManager.DEFENDER_SIDE],
		]
		if GameManager.final_round > 1:
			_placeholder_label.text = "Rundę %d wygrywa %s!\n%s\nPRZYGOTUJCIE SIĘ!" % [
				GameManager.final_round - 1, _last_round_winner,
				"DOGRYWKA" if GameManager.final_round == 2 else "REMIS – RUNDA ROZSTRZYGAJĄCA",
			]
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
	if GameManager.is_final and GameManager.final_round == 1:
		_play_final_intro()


## Finał: runda rozstrzygnięta – zaraz przyjdzie duel_started kolejnej rundy (albo koniec gry).
func _on_final_round_finished(round_winner_id: int, _round_number: int) -> void:
	_last_round_winner = GameManager.get_player_name(round_winner_id)
	AudioManager.play_sfx(AudioManager.SFX_CORRECT, 3.0)


## 3, 2, 1 -> click. "0" to moment pojawienia się pierwszego zdjęcia – wtedy gra start.wav
## (patrz _on_duel_image_changed, akcja START).
func _on_countdown_changed(value: int) -> void:
	_placeholder_label.hide()
	_countdown_label.text = str(value)
	_countdown_label.show()
	_pop(_countdown_label)
	AudioManager.play_sfx(AudioManager.SFX_CLICK)


func _on_duel_image_changed(image: Dictionary, previous_answer: String, action: int) -> void:
	_countdown_label.hide()
	_hide_penalty(false)

	var texture: Texture2D
	var media: Control = _image_rect # To, co "wskakuje" na ekran.
	if image.get("kind") == CategoryManager.KIND_VIDEO:
		# Pytanie = wideo w pętli; muzyka tła wyciszona na czas filmu.
		var video := CategoryManager.load_video(image.get("path", ""))
		_play_video(video)
		media = _video_box
		_placeholder_label.text = "Nie udało się wczytać wideo"
		_placeholder_label.visible = video == null
	else:
		_stop_video()
		if image.get("kind") == CategoryManager.KIND_MUSIC:
			# Pytanie = utwór; na środku stały obrazek tła kategorii.
			texture = CategoryManager.load_texture(CategoryManager.get_background(GameManager.get_duel_category_key()))
			var stream := CategoryManager.load_audio(image.get("path", ""))
			AudioManager.play_question(stream)
			_placeholder_label.text = "JAKI TO UTWÓR?" if stream != null else "Nie udało się wczytać utworu"
		else:
			texture = CategoryManager.load_texture(image.get("path", ""))
			_placeholder_label.text = "Nie udało się wczytać zdjęcia"
		_placeholder_label.visible = texture == null
	_image_rect.texture = texture

	# Szybkie "wskoczenie" nowego zdjęcia / wideo.
	_kill(_image_tween)
	media.scale = Vector2.ONE * 0.94
	media.modulate.a = 0.0
	_image_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_image_tween.tween_property(media, "scale", Vector2.ONE, 0.18)
	_image_tween.tween_property(media, "modulate:a", 1.0, 0.12)

	# Koniec odliczania ("0"): pierwsze zdjęcie + dźwięk startu.
	if action == GameManager.DuelAction.START:
		AudioManager.play_sfx(AudioManager.SFX_START)
	# Po pasie odpowiedź była już widoczna w trakcie kary – tu tylko przy poprawnej.
	elif action == GameManager.DuelAction.CORRECT:
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
	# Wideo zatrzymuje się na ostatniej klatce; wraca muzyka tła.
	_video_rect.paused = true
	AudioManager.set_music_ducked(false)
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
	_kill(_intro_tween)
	_final_intro.hide()
	AudioManager.stop_question()
	_stop_video()
	AudioManager.play_music(AudioManager.MUSIC_MAIN)
	_fade_out()


func _on_state_changed() -> void:
	if GameManager.phase != GameManager.Phase.DUEL:
		return
	var paused := GameManager.duel_state == GameManager.DuelState.PAUSED
	_pause_label.visible = paused
	AudioManager.set_question_paused(paused)
	if _video_box.visible and GameManager.duel_state != GameManager.DuelState.TIMEOUT:
		_video_rect.paused = paused
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

## Przed finałem: przez środek ekranu otwiera się ciemny pas ze złotymi liniami, wielki
## napis "FINAŁ" wjeżdża z prawej, chwilę stoi (beep) i wyjeżdża w lewo (ok. 2 s).
func _play_final_intro() -> void:
	_kill(_intro_tween)
	var width := size.x
	_final_intro.show()
	_intro_band.pivot_offset = _intro_band.size * 0.5
	_intro_band.scale = Vector2(1.0, 0.0)
	_intro_label.pivot_offset = _intro_label.size * 0.5
	_intro_label.position.x = width
	_intro_label.scale = Vector2.ONE * 1.4
	_intro_label.modulate.a = 0.0
	AudioManager.play_sfx(AudioManager.SFX_WOOSH, 2.0)

	_intro_tween = create_tween()
	_intro_tween.tween_interval(FADE_DURATION) # Najpierw ekran pojedynku się pojawia.
	# Wejście: pas się rozwiera, napis wjeżdża i "osiada" (zmniejsza się do 1).
	_intro_tween.tween_property(_intro_band, "scale:y", 1.0, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_intro_tween.parallel().tween_property(_intro_label, "position:x", 0.0, 0.55) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_intro_tween.parallel().tween_property(_intro_label, "modulate:a", 1.0, 0.25)
	_intro_tween.parallel().tween_property(_intro_label, "scale", Vector2.ONE, 0.55) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	# Pauza z delikatnym "oddechem" napisu.
	_intro_tween.tween_property(_intro_label, "scale", Vector2.ONE * 1.06, 0.45) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_intro_tween.tween_property(_intro_label, "scale", Vector2.ONE, 0.45) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Wyjście w lewo i zamknięcie pasa.
	_intro_tween.tween_property(_intro_label, "position:x", -width, 0.4) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_intro_tween.parallel().tween_property(_intro_band, "scale:y", 0.0, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN).set_delay(0.15)
	_intro_tween.tween_callback(_final_intro.hide)


func _hide_penalty(instant: bool) -> void:
	_penalty_box.hide()
	if instant:
		_kill(_dim_tween)
		_image_rect.self_modulate = Color.WHITE
		_video_rect.self_modulate = Color.WHITE
	else:
		_tween_image_dim(Color.WHITE)


## Wideo gra w pętli, dopóki pytanie się nie zmieni; muzyka tła jest w tym czasie wyciszona.
func _play_video(video: VideoStream) -> void:
	_video_rect.stop()
	_video_rect.stream = video
	_video_rect.paused = false
	_image_rect.hide()
	_video_box.visible = video != null
	if video == null:
		return
	if "loop" in _video_rect:
		_video_rect.set("loop", true)
	_video_rect.play()
	_video_started_ms = Time.get_ticks_msec()
	AudioManager.set_music_ducked(true)
	_fit_video_aspect()


func _stop_video() -> void:
	if not _video_box.visible and _video_rect.stream == null:
		return
	_video_rect.stop()
	_video_rect.stream = null
	_video_box.hide()
	_image_rect.show()
	AudioManager.set_music_ducked(false)


func _show_broken_video() -> void:
	_stop_video()
	_placeholder_label.text = "Nie udało się odtworzyć wideo"
	_placeholder_label.show()


## Proporcje kontenera = proporcje filmu (rozmiar tekstury znany po zdekodowaniu klatki).
## Brak klatki po BROKEN_VIDEO_MS = plik uszkodzony albo nie Ogg Theora (is_playing() wtedy kłamie).
func _fit_video_aspect() -> void:
	var stream := _video_rect.stream
	for attempt in VIDEO_FIRST_FRAME_CHECKS: # Do ~1 s na pierwszą klatkę (wolniejsze komputery).
		await get_tree().create_timer(0.1).timeout
		if _video_rect.stream != stream or not _video_box.visible:
			return # W międzyczasie zmieniło się pytanie.
		var texture := _video_rect.get_video_texture()
		if texture != null and texture.get_height() > 0:
			_video_box.ratio = float(texture.get_width()) / texture.get_height()
			return
	_show_broken_video()


## Zapętlenie dla wersji Godota bez właściwości VideoStreamPlayer.loop.
## "Koniec" tuż po starcie = plik uszkodzony / nie-Theora – nie restartujemy w kółko.
func _on_video_finished() -> void:
	if not _video_box.visible or _video_rect.stream == null:
		return
	if Time.get_ticks_msec() - _video_started_ms < BROKEN_VIDEO_MS:
		_show_broken_video()
		return
	_video_rect.play()
	_video_started_ms = Time.get_ticks_msec()


## Przyciemnianie przez self_modulate – modulate:a jest zajęte przez "wskoczenie" zdjęcia.
func _tween_image_dim(target: Color) -> void:
	_kill(_dim_tween)
	_dim_tween = create_tween().set_parallel()
	_dim_tween.tween_property(_image_rect, "self_modulate", target, 0.2)
	_dim_tween.tween_property(_video_rect, "self_modulate", target, 0.2)


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
