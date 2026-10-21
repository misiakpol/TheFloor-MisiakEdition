class_name WinnerScreen
extends Control
## Pełnoekranowe ogłoszenie zwycięzcy całej gry.
##
## Main pokazuje go chwilę po zakończeniu fali przejęcia ostatniego terytorium:
## ekran przyciemnia się, "ZWYCIĘZCA" zjeżdża z góry, a imię (w kolorze gracza)
## wskakuje z dużym "odbiciem" i dalej delikatnie pulsuje. Znika przy nowej podłodze.

var _tween: Tween
var _pulse_tween: Tween

@onready var _dim: ColorRect = $Dim
@onready var _caption_label: Label = %CaptionLabel
@onready var _name_label: Label = %NameLabel
@onready var _detail_label: Label = %DetailLabel


func _ready() -> void:
	hide()
	for label: Label in [_caption_label, _name_label]:
		label.resized.connect(func() -> void: label.pivot_offset = label.size * 0.5)


func show_winner(winner_name: String, color: Color, detail: String) -> void:
	_kill_tweens()
	_name_label.text = winner_name
	_name_label.add_theme_color_override("font_color", color.lightened(0.35))
	_name_label.add_theme_color_override("font_outline_color", color.darkened(0.65))
	_detail_label.text = detail
	show()

	_dim.modulate.a = 0.0
	_caption_label.modulate.a = 0.0
	_caption_label.scale = Vector2.ONE * 2.0
	_name_label.modulate.a = 0.0
	_name_label.scale = Vector2.ONE * 0.2
	_detail_label.modulate.a = 0.0

	_tween = create_tween()
	_tween.tween_property(_dim, "modulate:a", 1.0, 0.4)
	# "ZWYCIĘZCA" uderza w ekran z dużej skali.
	_tween.tween_property(_caption_label, "modulate:a", 1.0, 0.2)
	_tween.parallel().tween_property(_caption_label, "scale", Vector2.ONE, 0.35) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	# Imię wskakuje z odbiciem.
	_tween.tween_callback(AudioManager.play_sfx.bind(AudioManager.SFX_CORRECT, 4.0, 1.0))
	_tween.tween_property(_name_label, "modulate:a", 1.0, 0.2)
	_tween.parallel().tween_property(_name_label, "scale", Vector2.ONE, 0.8) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_detail_label, "modulate:a", 1.0, 0.4)
	_tween.tween_callback(_start_pulse)


func hide_now() -> void:
	_kill_tweens()
	hide()


func _start_pulse() -> void:
	_pulse_tween = create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulse_tween.tween_property(_name_label, "scale", Vector2.ONE * 1.06, 0.9)
	_pulse_tween.tween_property(_name_label, "scale", Vector2.ONE, 0.9)


func _kill_tweens() -> void:
	for tween: Tween in [_tween, _pulse_tween]:
		if tween and tween.is_valid():
			tween.kill()
