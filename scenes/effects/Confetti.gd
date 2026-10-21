class_name Confetti
extends Node2D
## Konfetti na koniec gry: dwa wystrzały z dolnych rogów ekranu + deszcz z góry.
##
## Zbudowane z CPUParticles2D (działa w rendererze GL Compatibility). Kolory konfetti
## to kolory graczy (zwycięzca częściej). Każdy "papierek" to mały prostokąt, który
## obraca się, lekko kołysze na boki i znika pod koniec życia.

## Jak długo pada deszcz konfetti z góry (s).
@export var rain_duration := 8.0
@export var rain_amount := 320
@export var burst_amount := 160

var _rain: CPUParticles2D
var _bursts: Array[CPUParticles2D] = []
var _rain_timer: SceneTreeTimer


func _ready() -> void:
	var texture := _make_paper_texture()
	_rain = _make_emitter(texture, rain_amount)
	_rain.lifetime = 6.0
	_rain.direction = Vector2.DOWN
	_rain.spread = 20.0
	_rain.initial_velocity_min = 80.0
	_rain.initial_velocity_max = 220.0
	_rain.gravity = Vector2(0.0, 180.0)
	_rain.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE

	for side in [-1.0, 1.0]:
		var burst := _make_emitter(texture, burst_amount)
		burst.one_shot = true
		burst.explosiveness = 0.95
		burst.lifetime = 4.5
		# Z rogu w górę i do środka ekranu.
		burst.direction = Vector2(-side * 0.45, -1.0).normalized()
		burst.spread = 18.0
		burst.initial_velocity_min = 900.0
		burst.initial_velocity_max = 1500.0
		burst.gravity = Vector2(0.0, 900.0)
		burst.damping_min = 120.0
		burst.damping_max = 220.0
		_bursts.append(burst)


## Odpala konfetti na obszarze [param area] (rozmiar ekranu) w podanych kolorach.
func play(area: Vector2, colors: Array[Color]) -> void:
	show()
	var ramp := _make_color_ramp(colors)
	_rain.color_initial_ramp = ramp
	_rain.position = Vector2(area.x * 0.5, -40.0)
	_rain.emission_rect_extents = Vector2(area.x * 0.5, 10.0)
	_rain.restart()
	_rain.emitting = true

	for i in _bursts.size():
		var burst := _bursts[i]
		burst.color_initial_ramp = ramp
		burst.position = Vector2(0.0 if i == 0 else area.x, area.y + 20.0)
		burst.restart()
		burst.emitting = true

	# Deszcz przestaje się sypać po rain_duration; spadające papierki dolatują do końca.
	_rain_timer = get_tree().create_timer(rain_duration)
	_rain_timer.timeout.connect(func() -> void: _rain.emitting = false)


## Natychmiast usuwa wszystkie konfetti (np. nowa podłoga = nowa gra).
## Bez restart() – ten od razu wystrzeliwuje nową porcję cząstek.
func stop() -> void:
	for emitter: CPUParticles2D in [_rain] + _bursts:
		emitter.emitting = false
	hide() # Lecące jeszcze cząstki znikają; play() pokazuje węzeł i restartuje emitery.


func _make_emitter(texture: Texture2D, amount: int) -> CPUParticles2D:
	var emitter := CPUParticles2D.new()
	emitter.emitting = false
	emitter.amount = amount
	emitter.texture = texture
	emitter.local_coords = false
	# Losowy rozmiar, obrót i wirowanie "papierka".
	emitter.scale_amount_min = 0.7
	emitter.scale_amount_max = 1.4
	emitter.angle_min = 0.0
	emitter.angle_max = 360.0
	emitter.angular_velocity_min = -540.0
	emitter.angular_velocity_max = 540.0
	# Kołysanie na boki w trakcie opadania.
	emitter.tangential_accel_min = -40.0
	emitter.tangential_accel_max = 40.0
	emitter.damping_min = 10.0
	emitter.damping_max = 40.0
	# Zanikanie pod koniec życia.
	var fade := Gradient.new()
	fade.set_color(0, Color.WHITE)
	fade.set_color(1, Color(1, 1, 1, 0))
	fade.add_point(0.8, Color.WHITE)
	emitter.color_ramp = fade
	add_child(emitter)
	return emitter


## Każdy papierek dostaje losowy kolor z listy (gradient "schodkowy").
func _make_color_ramp(colors: Array[Color]) -> Gradient:
	var palette := colors.duplicate()
	if palette.is_empty():
		palette = [Color("ffd166"), Color("ef476f"), Color("06d6a0"), Color("118ab2")]
	var ramp := Gradient.new()
	ramp.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	ramp.offsets = PackedFloat32Array()
	ramp.colors = PackedColorArray()
	for i in palette.size():
		ramp.add_point(float(i) / palette.size(), palette[i])
	return ramp


## Mały biały prostokąt 10x16 px – barwiony kolorem cząstki.
func _make_paper_texture() -> Texture2D:
	var image := Image.create(10, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)
