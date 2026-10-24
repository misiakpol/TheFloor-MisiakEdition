extends Control
## Ekran gry (TV). Wyświetla podłogę, a na czas pojedynku – DuelScreen (osobna scena,
## sama reaguje na sygnały pojedynku i przykrywa podłogę).
##
## Nie posiada logiki zasad – reaguje tylko na sygnały GameManagera.
## Trzyma własną kopię właścicieli pól ([member _displayed_owners]), która nadąża za
## animacją przejęcia.
## Przejęcie jest RADIALNE: cała przejmowana strefa maluje się jednocześnie kołem, które
## rośnie (3 s) ze środka pola zwycięzcy – jeden wspólny ShaderMaterial
## (radial_capture.gdshader) na wszystkich przejmowanych polach, animowany promień.
## Siatka ma dowolną liczbę graczy: puste komórki (EMPTY_CELL) to niewidoczne wypełniacze,
## dzięki którym niepełny ostatni rząd jest wyśrodkowany.
## Losowanie gracza to ruletka: podświetlenie skacze po graczach, zwalniając (ease out).
## Dodatkowo ustawia okna: siebie na drugim monitorze (fullscreen),
## a dziecko-okno AdminWindow na pierwszym monitorze.
## Audio planszy: bg_main, woosh przy łączeniu terytorium, losowa muzyka zwycięstwa
## (gaszona przez AudioManager po 60 s albo przy nowej podłodze).

const TILE_SCENE: PackedScene = preload("res://scenes/tile/Tile.tscn")
const RADIAL_CAPTURE_SHADER: Shader = preload("res://scenes/tile/radial_capture.gdshader")

const APPEAR_WAVE_DELAY := 0.07 ## Opóźnienie fali wejścia na jednostkę odległości od środka.
const CAPTURE_DURATION := 3.0 ## Czas radialnego malowania całej przejmowanej strefy.
const WINNER_REVEAL_DELAY := 1.5 ## Pauza po zapełnieniu podłogi, zanim pojawi się ekran zwycięzcy.
const CAPTURE_EDGE_WIDTH := 36.0 ## Jasne czoło fali (piksele) – patrz radial_capture.gdshader.
const ROLL_HOPS := 18 ## Liczba przeskoków podświetlenia w ruletce.
const ROLL_LANDING_PAUSE := 0.3 ## Ostatni przeskok tyle przed ogłoszeniem wyniku (pauza przed "beep").
const MAX_TILE_ASPECT := 1.6 ## Maks. stosunek szerokość/wysokość kafelka.
const ACCENT_COLOR := Color("ffd166")
const DANGER_COLOR := Color("ef476f")
const SUCCESS_COLOR := Color("06d6a0")
## Kierunek do sąsiada -> bit maski w Tile.
const NEIGHBOR_BITS := {
	Vector2i(0, -1): Tile.N,
	Vector2i(1, 0): Tile.E,
	Vector2i(0, 1): Tile.S,
	Vector2i(-1, 0): Tile.W,
	Vector2i(1, -1): Tile.NE,
	Vector2i(1, 1): Tile.SE,
	Vector2i(-1, 1): Tile.SW,
	Vector2i(-1, -1): Tile.NW,
}

## Monitor dla ekranu gry (0 = główny, 1 = drugi / TV).
@export var game_screen := 1
## Fullscreen tylko, gdy wykryto więcej niż jeden monitor (wygodne przy developmencie).
@export var fullscreen_on_multi_monitor := true

## Indeks komórki -> kafelek (null dla pustej komórki).
var _tiles: Array[Tile] = []
## Właściciele pól tak, jak są aktualnie NARYSOWANI (nadąża za animacją przejęcia).
var _displayed_owners := PackedInt32Array()
## Id gracza -> Tile.HighlightStyle (podświetlenie całego terytorium).
var _highlights: Dictionary = {}
## Zwiększany przy każdej nowej podłodze – unieważnia opóźnione callbacki starej.
var _floor_generation := 0
var _banner_tween: Tween
var _roll_tween: Tween
## Kolejni gracze, po których skacze podświetlenie ruletki (ostatni = wylosowany).
var _roll_sequence: Array[int] = []
var _roll_step := -1
var _capture_tween: Tween
## Pola z aktywną nakładką przejęcia: wszystkie pola zwycięzcy + przejmowane
## (dokańczane w [method _finish_radial_capture]).
var _capturing_tiles: Array[int] = []
## Pola, które po fali przejdą do zwycięzcy, i sam zwycięzca (-1 = brak fali).
var _capture_new_tiles := PackedInt32Array()
var _capture_winner := -1

@onready var _layout: VBoxContainer = %Layout
@onready var _top_bar: HBoxContainer = %TopBar
@onready var _banner: PanelContainer = %Banner
@onready var _banner_label: Label = %BannerLabel
@onready var _grid: GridContainer = %Grid
@onready var _admin_window: Window = $AdminWindow
@onready var _winner_screen: WinnerScreen = $WinnerScreen
## Konfetti na koniec gry – rysowane nad podłogą i ekranem pojedynku.
@onready var _confetti: Confetti = _create_confetti()


func _ready() -> void:
	_setup_windows()
	_connect_game_signals()
	resized.connect(_fit_tiles)
	_show_banner("Czekamy na wygenerowanie podłogi...", Color.WHITE)
	AudioManager.play_music(AudioManager.MUSIC_MAIN)


#region Okna / monitory

func _setup_windows() -> void:
	var screen_count := DisplayServer.get_screen_count()
	var main_window := get_window()
	var target_game_screen := clampi(game_screen, 0, screen_count - 1)
	var admin_screen := 0 if target_game_screen != 0 else mini(1, screen_count - 1)

	main_window.title = "The Floor"
	main_window.current_screen = target_game_screen
	if fullscreen_on_multi_monitor and screen_count > 1:
		main_window.mode = Window.MODE_FULLSCREEN

	# Admin na środku swojego monitora. Przy jednym monitorze – zawsze na wierzchu,
	# żeby nie schował się za oknem gry.
	var usable := DisplayServer.screen_get_usable_rect(admin_screen)
	_admin_window.position = usable.position + (usable.size - _admin_window.size) / 2
	_admin_window.always_on_top = screen_count == 1
	_admin_window.show()

#endregion


#region Sygnały GameManagera

func _connect_game_signals() -> void:
	GameManager.floor_generated.connect(_on_floor_generated)
	GameManager.player_roll_started.connect(_on_player_roll_started)
	GameManager.player_selected.connect(_on_player_selected)
	GameManager.duel_started.connect(_on_duel_started)
	GameManager.territory_captured.connect(_on_territory_captured)
	GameManager.selection_cleared.connect(_on_selection_cleared)
	GameManager.game_over.connect(_on_game_over)


func _on_floor_generated(columns: int, rows: int) -> void:
	_stop_roll()
	_confetti.stop()
	_winner_screen.hide_now()
	_clear_floor()
	_floor_generation += 1
	_grid.columns = columns
	_displayed_owners = GameManager.tile_owners.duplicate()
	_highlights.clear()
	# Nowa podłoga = reset gry: gasi ew. muzykę zwycięstwa i wraca do bg_main.
	AudioManager.play_music(AudioManager.MUSIC_MAIN)

	var gap := float(_grid.get_theme_constant("h_separation"))
	var player_count := 0
	for i in columns * rows:
		var owner_id := _displayed_owners[i]
		if owner_id == GameManager.EMPTY_CELL:
			# Niewidoczny wypełniacz: trzyma miejsce, by ostatni rząd był wyśrodkowany.
			var filler := Control.new()
			filler.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_grid.add_child(filler)
			_tiles.append(null)
			continue
		var tile: Tile = TILE_SCENE.instantiate()
		_grid.add_child(tile)
		tile.setup(i, gap)
		tile.set_territory(GameManager.get_player_name(owner_id),
				GameManager.get_player_category_display(owner_id), GameManager.get_player_color(owner_id))
		_tiles.append(tile)
		player_count += 1

	_fit_tiles()
	_refresh_territories()

	# Fala wejścia rozchodząca się od środka siatki.
	var center := Vector2(columns - 1, rows - 1) * 0.5
	for tile in _tiles:
		if tile:
			var cell := Vector2(GameManager.index_to_cell(tile.tile_index))
			tile.play_appear(cell.distance_to(center) * APPEAR_WAVE_DELAY)

	_show_banner("Podłoga gotowa! %d graczy" % player_count, ACCENT_COLOR)


## Ruletka: podświetlenie skacze po kandydatach coraz wolniej (tween z ease out),
## każdy przeskok = click. Wynik ogłasza dopiero [signal GameManager.player_selected].
func _on_player_roll_started(candidate_ids: Array, winner_id: int, duration: float) -> void:
	_stop_roll()
	_roll_sequence = _make_roll_sequence(candidate_ids, winner_id)
	_roll_step = -1
	_show_banner("Losowanie...", Color.WHITE)

	_roll_tween = create_tween()
	_roll_tween.tween_method(_on_roll_progress, 0.0, float(_roll_sequence.size() - 1),
			maxf(duration - ROLL_LANDING_PAUSE, 0.1)) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _on_roll_progress(value: float) -> void:
	var step := mini(floori(value + 0.001), _roll_sequence.size() - 1)
	if step == _roll_step:
		return
	_roll_step = step
	_set_highlights({ _roll_sequence[step]: Tile.HighlightStyle.ROLL })
	AudioManager.play_sfx(AudioManager.SFX_CLICK, -3.0, randf_range(0.95, 1.05))


## Losowe przeskoki bez powtórzeń pod rząd; ostatni zawsze na wylosowanym graczu.
func _make_roll_sequence(candidate_ids: Array, winner_id: int) -> Array[int]:
	var sequence: Array[int] = []
	if candidate_ids.size() > 1:
		var previous := -1
		for i in ROLL_HOPS - 1:
			var options := candidate_ids.filter(func(id: int) -> bool: return id != previous)
			if i == ROLL_HOPS - 2: # Przedostatni przeskok nie może trafić już w zwycięzcę.
				options = candidate_ids.filter(func(id: int) -> bool: return id != winner_id)
			previous = options.pick_random()
			sequence.append(previous)
	sequence.append(winner_id)
	return sequence


func _stop_roll() -> void:
	if _roll_tween and _roll_tween.is_valid():
		_roll_tween.kill()
	_roll_sequence.clear()
	_roll_step = -1


func _on_player_selected(player_id: int) -> void:
	_stop_roll()
	_set_highlights({ player_id: Tile.HighlightStyle.SELECTED })
	# Zatrzymanie ruletki: głośny beep i mocne pulsowanie terytorium wylosowanego gracza.
	AudioManager.play_sfx(AudioManager.SFX_BEEP, 4.0)
	for i in _displayed_owners.size():
		if _displayed_owners[i] == player_id:
			_tiles[i].play_selection_burst()
	_show_banner("Wylosowano: %s  •  %s" % [
		GameManager.get_player_name(player_id), GameManager.get_player_category_display(player_id),
	], ACCENT_COLOR)


func _on_duel_started(attacker_id: int, defender_id: int) -> void:
	# Podłogę przykrywa DuelScreen – podświetlenie widać tuż po jego zniknięciu.
	_set_highlights({
		attacker_id: Tile.HighlightStyle.ATTACKER,
		defender_id: Tile.HighlightStyle.DEFENDER,
	})
	_show_banner("%s  VS  %s  •  Kategoria: %s" % [
		GameManager.get_player_name(attacker_id),
		GameManager.get_player_name(defender_id),
		GameManager.get_duel_category_name(),
	], DANGER_COLOR)


func _on_territory_captured(winner_id: int, loser_id: int, tile_indices: PackedInt32Array) -> void:
	var winner_name := GameManager.get_player_name(winner_id)
	_finish_radial_capture() # Poprzednie przejęcie (jeśli jeszcze trwa) kończymy od razu.

	# Środek fali = środek pola zwycięzcy, z którego "wychodzi" atak.
	var origin := _find_capture_origin(winner_id, tile_indices)
	var center := _tiles[origin].get_global_rect().get_center()
	# Promień końcowy: najdalszy narożnik przejmowanych pól (z mostkami) + czoło fali.
	var gap := float(_grid.get_theme_constant("h_separation"))
	var max_radius := 0.0
	for tile_index in tile_indices:
		var rect := _tiles[tile_index].get_global_rect().grow(gap)
		for corner: Vector2 in [rect.position, rect.end,
				Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.position.y)]:
			max_radius = maxf(max_radius, center.distance_to(corner))
	max_radius += CAPTURE_EDGE_WIDTH

	# JEDEN materiał dla całej strefy – wszystkie pola widzą to samo koło.
	var radial := ShaderMaterial.new()
	radial.shader = RADIAL_CAPTURE_SHADER
	radial.set_shader_parameter("center", center)
	radial.set_shader_parameter("radius", 0.0)
	radial.set_shader_parameter("edge_width", CAPTURE_EDGE_WIDTH)

	# Start, gdy ekran pojedynku już zniknie.
	_capture_tween = create_tween()
	_capture_tween.tween_interval(DuelScreen.FADE_DURATION)
	_capture_tween.tween_callback(_begin_radial_capture.bind(winner_id, tile_indices, radial))
	_capture_tween.tween_method(
			func(radius: float) -> void: radial.set_shader_parameter("radius", radius),
			0.0, max_radius, CAPTURE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_capture_tween.tween_callback(_finish_radial_capture)

	# Zwycięzca pozostaje aktywny – obrys obejmie nową strefę od startu fali.
	_set_highlights({ winner_id: Tile.HighlightStyle.SELECTED })
	_show_banner("%s przejmuje terytorium gracza %s!" % [
		winner_name, GameManager.get_player_name(loser_id),
	], SUCCESS_COLOR)


func _on_selection_cleared() -> void:
	_set_highlights({})
	_show_banner("Kto następny?", Color.WHITE)


## Koniec gry: najpierw widać, jak fala zalewa ostatnie terytorium, chwilę później
## (WINNER_REVEAL_DELAY) pełnoekranowe ogłoszenie zwycięzcy + konfetti + muzyka zwycięstwa.
func _on_game_over(winner_id: int) -> void:
	_set_highlights({ winner_id: Tile.HighlightStyle.WINNER })
	_show_banner("ZWYCIĘZCA: %s!" % GameManager.get_player_name(winner_id), SUCCESS_COLOR)
	var reveal_delay := DuelScreen.FADE_DURATION + CAPTURE_DURATION + WINNER_REVEAL_DELAY
	get_tree().create_timer(reveal_delay).timeout.connect(
			_reveal_winner.bind(_floor_generation, winner_id))


func _reveal_winner(generation: int, winner_id: int) -> void:
	if generation != _floor_generation:
		return # W międzyczasie wygenerowano nową podłogę.
	var tiles := GameManager.players.size()
	var few := tiles % 10 in [2, 3, 4] and tiles % 100 not in [12, 13, 14]
	_winner_screen.show_winner(GameManager.get_player_name(winner_id),
			GameManager.get_player_color(winner_id),
			"Zdobyta cała podłoga – %d %s" % [tiles, "pola" if few else "pól"])
	AudioManager.play_win_music()
	_play_confetti(generation, winner_id)


func _create_confetti() -> Confetti:
	var confetti := Confetti.new()
	confetti.name = "Confetti"
	confetti.z_index = 100
	add_child(confetti)
	return confetti


func _play_confetti(generation: int, winner_id: int) -> void:
	if generation != _floor_generation:
		return
	# Kolor zwycięzcy pojawia się najczęściej, reszta to barwy akcentowe gry.
	var winner_color := GameManager.get_player_color(winner_id)
	var colors: Array[Color] = [winner_color, winner_color, winner_color.lightened(0.35),
			ACCENT_COLOR, SUCCESS_COLOR, DANGER_COLOR, Color("118ab2"), Color.WHITE]
	_confetti.play(size, colors)

#endregion


#region Siatka i terytoria

func _clear_floor() -> void:
	_kill_tween(_capture_tween)
	_capturing_tiles.clear()
	_capture_new_tiles = PackedInt32Array()
	_capture_winner = -1
	for child in _grid.get_children():
		_grid.remove_child(child) # Natychmiast z layoutu, zwolnienie na końcu klatki.
		child.queue_free()
	_tiles.clear()
	_displayed_owners.clear()


## Dopasowuje rozmiar kafelków tak, by cała siatka zmieściła się na ekranie.
## Liczone z rozmiaru roota (nie kontenerów), by uniknąć sprzężenia z min. rozmiarem siatki.
func _fit_tiles() -> void:
	if _tiles.is_empty():
		return

	var columns := GameManager.columns
	var rows := GameManager.rows
	var h_gap := _grid.get_theme_constant("h_separation")
	var v_gap := _grid.get_theme_constant("v_separation")
	var available := Vector2(
		size.x - _layout.offset_left + _layout.offset_right,
		size.y - _layout.offset_top + _layout.offset_bottom
				- _top_bar.size.y - _layout.get_theme_constant("separation")
	)

	var tile_h := floorf((available.y - v_gap * (rows - 1)) / rows)
	var tile_w := floorf((available.x - h_gap * (columns - 1)) / columns)
	tile_w = minf(tile_w, tile_h * MAX_TILE_ASPECT)
	var tile_size := Vector2(maxf(tile_w, 16.0), maxf(tile_h, 16.0))

	# Także niewidoczne wypełniacze – trzymają kształt siatki.
	for cell in _grid.get_children():
		(cell as Control).custom_minimum_size = tile_size


## Start fali. Podłoga pod spodem zostaje NIETKNIĘTA (stare kolory, kształty i szczeliny),
## a nad nią cały przyszły kształt zwycięzcy – jego dotychczasowe pola + przejmowane, już
## połączone mostkami – jest odsłaniany kołem. Dzięki temu granica zwycięzcy dosłownie
## rozlewa się razem z falą: szczeliny znikają i narożniki prostują się tam, gdzie dotarła.
func _begin_radial_capture(winner_id: int, tile_indices: PackedInt32Array, radial: ShaderMaterial) -> void:
	var winner_name := GameManager.get_player_name(winner_id)
	var winner_category := GameManager.get_player_category_display(winner_id)
	var winner_color := GameManager.get_player_color(winner_id)
	AudioManager.play_sfx(AudioManager.SFX_WOOSH)

	var merged_owners := _displayed_owners.duplicate()
	for tile_index in tile_indices:
		merged_owners[tile_index] = winner_id
	_capture_winner = winner_id
	_capture_new_tiles = tile_indices

	for i in merged_owners.size():
		if merged_owners[i] != winner_id:
			continue
		var is_new_tile := i in tile_indices
		if not is_new_tile:
			# Zwycięzca gra teraz kategorią atakującego – także na dotychczasowych polach.
			_tiles[i].set_category(winner_category)
		_tiles[i].begin_capture(winner_name, winner_category, winner_color, radial,
				_neighbor_mask_in(merged_owners, i), is_new_tile)
		_capturing_tiles.append(i)
	_refresh_territories() # Wycisza obrys zwycięzcy na czas fali.


## Koniec fali (lub przerwanie): pola przechodzą do zwycięzcy, nowy kolor i kształt zostają
## na stałe, a obrys pojawia się już wokół całego, powiększonego terytorium.
func _finish_radial_capture() -> void:
	_kill_tween(_capture_tween)
	if _capture_winner >= 0:
		for tile_index in _capture_new_tiles:
			_displayed_owners[tile_index] = _capture_winner
	for tile_index in _capturing_tiles:
		_tiles[tile_index].finish_capture()
	_capturing_tiles.clear()
	_capture_new_tiles = PackedInt32Array()
	_capture_winner = -1
	_refresh_territories()


## Pole zwycięzcy, z którego startuje fala: preferujemy pola stykające się z przejmowaną
## strefą, a spośród nich – najbliższe jej środka.
func _find_capture_origin(winner_id: int, tile_indices: PackedInt32Array) -> int:
	var captured_center := Vector2.ZERO
	for tile_index in tile_indices:
		captured_center += Vector2(GameManager.index_to_cell(tile_index))
	captured_center /= maxi(tile_indices.size(), 1)

	var best := tile_indices[0]
	var best_score := INF
	for i in _displayed_owners.size():
		if _displayed_owners[i] != winner_id:
			continue
		var touches := GameManager.get_neighbor_tiles(i).any(
			func(neighbor: int) -> bool: return neighbor in tile_indices
		)
		var score := Vector2(GameManager.index_to_cell(i)).distance_squared_to(captured_center) \
				+ (0.0 if touches else 1000.0)
		if score < best_score:
			best = i
			best_score = score
	return best


func _set_highlights(highlights: Dictionary) -> void:
	_highlights = highlights
	_refresh_territories()


## Przelicza maski sąsiadów (łączenie kształtów), podświetlenia i pola z podpisami.
func _refresh_territories() -> void:
	if _tiles.is_empty():
		return
	var label_anchors := _find_label_anchors()
	for i in _tiles.size():
		var tile := _tiles[i]
		if tile == null:
			continue # Pusta komórka.
		tile.set_neighbors(_neighbor_mask_in(_displayed_owners, i))
		# W trakcie fali obrys zwycięzcy jest wyciszony (stary kształt przecinałby nowy).
		var owner_id := _displayed_owners[i]
		var style: Tile.HighlightStyle = Tile.HighlightStyle.NONE
		if owner_id != _capture_winner:
			style = _highlights.get(owner_id, Tile.HighlightStyle.NONE)
		tile.set_highlight(style)
		tile.set_labels_visible(label_anchors.has(i))


## Maska sąsiadów pola [param tile_index] względem podanego układu właścicieli
## (aktualnego albo "po przejęciu").
func _neighbor_mask_in(owners: PackedInt32Array, tile_index: int) -> int:
	var owner_id := owners[tile_index]
	var cell := GameManager.index_to_cell(tile_index)
	var mask := 0
	for offset: Vector2i in NEIGHBOR_BITS:
		var neighbor := cell + offset
		if GameManager.is_cell_inside(neighbor) and owners[GameManager.cell_to_index(neighbor)] == owner_id:
			mask |= NEIGHBOR_BITS[offset]
	return mask


## Dla każdego terytorium: pole najbliżej jego środka ciężkości -> tam stoją podpisy.
## Zwraca zbiór indeksów pól (klucze słownika).
func _find_label_anchors() -> Dictionary:
	var tiles_by_owner: Dictionary = {}
	for i in _displayed_owners.size():
		var owner_id := _displayed_owners[i]
		if owner_id == GameManager.EMPTY_CELL:
			continue
		if not tiles_by_owner.has(owner_id):
			tiles_by_owner[owner_id] = []
		tiles_by_owner[owner_id].append(i)

	var anchors: Dictionary = {}
	for owner_id: int in tiles_by_owner:
		var indices: Array = tiles_by_owner[owner_id]
		var center := Vector2.ZERO
		for i: int in indices:
			center += Vector2(GameManager.index_to_cell(i))
		center /= indices.size()

		var best: int = indices[0]
		var best_distance := INF
		for i: int in indices:
			var distance := Vector2(GameManager.index_to_cell(i)).distance_squared_to(center)
			if distance < best_distance:
				best = i
				best_distance = distance
		anchors[best] = true
	return anchors

#endregion


#region Baner

## Baner z efektem "maszyny do pisania" (visible_ratio).
func _show_banner(text: String, color: Color) -> void:
	_kill_tween(_banner_tween)
	_banner_label.text = text
	_banner_label.visible_ratio = 0.0
	_banner_label.add_theme_color_override("font_color", color)

	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.15)
	_banner_tween.tween_property(_banner_label, "visible_ratio", 1.0,
			clampf(text.length() * 0.02, 0.2, 0.7))


func _kill_tween(tween: Tween) -> void:
	if tween and tween.is_valid():
		tween.kill()

#endregion
