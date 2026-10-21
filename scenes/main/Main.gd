extends Control
## Ekran gry (TV). Wyświetla podłogę, a na czas pojedynku – DuelScreen (osobna scena,
## sama reaguje na sygnały pojedynku i przykrywa podłogę).
##
## Nie posiada logiki zasad – reaguje tylko na sygnały GameManagera.
## Trzyma własną kopię właścicieli pól ([member _displayed_owners]), która nadąża za
## animacją przejęcia – pole dołącza do terytorium zwycięzcy, gdy zaczyna się jego
## "zalewanie". Zalewanie idzie pierścieniami od strony zwycięzcy w głąb terytorium
## przegranego (każde pole od boku sąsiada, z którego przyszło).
## Losowanie gracza to ruletka: podświetlenie skacze po graczach, zwalniając (ease out).
## Dodatkowo ustawia okna: siebie na drugim monitorze (fullscreen),
## a dziecko-okno AdminWindow na pierwszym monitorze.
## Audio planszy: bg_main, woosh przy łączeniu terytorium, losowa muzyka zwycięstwa
## (gaszona przez AudioManager po 60 s albo przy nowej podłodze).

const TILE_SCENE: PackedScene = preload("res://scenes/tile/Tile.tscn")

const APPEAR_WAVE_DELAY := 0.07 ## Opóźnienie fali wejścia na jednostkę odległości od środka.
const CAPTURE_FILL_DURATION := 3.0 ## Czas "zalewania" jednego pola nowym kolorem.
const CAPTURE_MAX_TOTAL := 6.0 ## Głębokie terytoria: pierścienie skracają się, by całość trwała maks. tyle.
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

@onready var _layout: VBoxContainer = %Layout
@onready var _top_bar: HBoxContainer = %TopBar
@onready var _banner: PanelContainer = %Banner
@onready var _banner_label: Label = %BannerLabel
@onready var _grid: GridContainer = %Grid
@onready var _admin_window: Window = $AdminWindow


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
	_clear_floor()
	_floor_generation += 1
	_grid.columns = columns
	_displayed_owners = GameManager.tile_owners.duplicate()
	_highlights.clear()
	# Nowa podłoga = reset gry: gasi ew. muzykę zwycięstwa i wraca do bg_main.
	AudioManager.play_music(AudioManager.MUSIC_MAIN)

	var gap := float(_grid.get_theme_constant("h_separation"))
	for i in columns * rows:
		var tile: Tile = TILE_SCENE.instantiate()
		_grid.add_child(tile)
		tile.setup(i, gap)
		var owner_id := _displayed_owners[i]
		tile.set_territory(GameManager.get_player_name(owner_id),
				GameManager.get_player_category(owner_id), GameManager.get_player_color(owner_id))
		_tiles.append(tile)

	_fit_tiles()
	_refresh_territories()

	# Fala wejścia rozchodząca się od środka siatki.
	var center := Vector2(columns - 1, rows - 1) * 0.5
	for tile in _tiles:
		var cell := Vector2(GameManager.index_to_cell(tile.tile_index))
		tile.play_appear(cell.distance_to(center) * APPEAR_WAVE_DELAY)

	_show_banner("Podłoga gotowa! %d graczy" % (columns * rows), ACCENT_COLOR)


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
		GameManager.get_player_name(player_id), GameManager.get_player_category(player_id),
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
	var winner_category := GameManager.get_player_category(winner_id)
	var winner_color := GameManager.get_player_color(winner_id)

	# Zalewanie startuje, gdy ekran pojedynku już zniknie. Każdy pierścień = "woosh".
	var plan := _plan_capture_flow(winner_id, tile_indices)
	var ring_duration: float = plan["ring_duration"]
	for ring in plan["ring_count"]:
		get_tree().create_timer(DuelScreen.FADE_DURATION + ring * ring_duration).timeout.connect(
				_play_capture_sound.bind(_floor_generation))
	for tile_index: int in plan["depth"]:
		var depth: int = plan["depth"][tile_index]
		var delay := DuelScreen.FADE_DURATION + (depth - 1) * ring_duration
		_tiles[tile_index].capture(winner_name, winner_category, winner_color,
				delay, plan["direction"][tile_index], ring_duration)
		get_tree().create_timer(delay).timeout.connect(
				_show_tile_owner.bind(_floor_generation, tile_index, winner_id))

	# Zwycięzca pozostaje aktywny – przejmowane pola dołączają do obrysu w trakcie fali.
	_set_highlights({ winner_id: Tile.HighlightStyle.SELECTED })
	_show_banner("%s przejmuje terytorium gracza %s!" % [
		winner_name, GameManager.get_player_name(loser_id),
	], SUCCESS_COLOR)


func _on_selection_cleared() -> void:
	_set_highlights({})
	_show_banner("Kto następny?", Color.WHITE)


func _on_game_over(winner_id: int) -> void:
	_set_highlights({ winner_id: Tile.HighlightStyle.WINNER })
	AudioManager.play_win_music()
	_show_banner("ZWYCIĘZCA: %s!" % GameManager.get_player_name(winner_id), SUCCESS_COLOR)

#endregion


#region Siatka i terytoria

func _clear_floor() -> void:
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

	for tile in _tiles:
		tile.custom_minimum_size = tile_size


## Callback fali przejęcia: pole wizualnie przechodzi do zwycięzcy.
func _show_tile_owner(generation: int, tile_index: int, owner_id: int) -> void:
	if generation != _floor_generation or tile_index >= _displayed_owners.size():
		return # Podłoga została w międzyczasie wygenerowana od nowa.
	_displayed_owners[tile_index] = owner_id
	_refresh_territories()


## Kolejność i kierunek zalewania przejmowanych pól (BFS od terytorium zwycięzcy):
## pierścień 1 = pola stykające się z pierwotnym terytorium zwycięzcy, pierścień 2 = ich
## sąsiedzi itd. Kierunek = od pola-rodzica do pola przejmowanego.
## Zwraca [code]{ depth: {indeks: int}, direction: {indeks: Vector2i}, ring_count, ring_duration }[/code].
func _plan_capture_flow(winner_id: int, tile_indices: PackedInt32Array) -> Dictionary:
	var captured: Dictionary = {}
	for tile_index in tile_indices:
		captured[tile_index] = true

	var depth: Dictionary = {}
	var direction: Dictionary = {}
	var frontier: Array[int] = []
	for tile_index in tile_indices:
		for neighbor in GameManager.get_neighbor_tiles(tile_index):
			if not captured.has(neighbor) and GameManager.get_tile_owner(neighbor) == winner_id:
				depth[tile_index] = 1
				direction[tile_index] = _cell_step(neighbor, tile_index)
				frontier.append(tile_index)
				break

	while not frontier.is_empty():
		var next: Array[int] = []
		for tile_index in frontier:
			for neighbor in GameManager.get_neighbor_tiles(tile_index):
				if captured.has(neighbor) and not depth.has(neighbor):
					depth[neighbor] = depth[tile_index] + 1
					direction[neighbor] = _cell_step(tile_index, neighbor)
					next.append(neighbor)
		frontier = next

	# Zabezpieczenie: pola nieosiągalne (nie powinno się zdarzyć) zalewają się w 1. pierścieniu.
	var ring_count := 1
	for tile_index in tile_indices:
		if not depth.has(tile_index):
			depth[tile_index] = 1
			direction[tile_index] = Vector2i.RIGHT
		ring_count = maxi(ring_count, depth[tile_index])

	return {
		"depth": depth,
		"direction": direction,
		"ring_count": ring_count,
		"ring_duration": minf(CAPTURE_FILL_DURATION, CAPTURE_MAX_TOTAL / ring_count),
	}


func _cell_step(from_index: int, to_index: int) -> Vector2i:
	return GameManager.index_to_cell(to_index) - GameManager.index_to_cell(from_index)


func _play_capture_sound(generation: int) -> void:
	if generation == _floor_generation:
		AudioManager.play_sfx(AudioManager.SFX_WOOSH)


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
		tile.set_neighbors(_neighbor_mask(i))
		tile.set_highlight(_highlights.get(_displayed_owners[i], Tile.HighlightStyle.NONE))
		tile.set_labels_visible(label_anchors.has(i))


func _neighbor_mask(tile_index: int) -> int:
	var owner_id := _displayed_owners[tile_index]
	var cell := GameManager.index_to_cell(tile_index)
	var mask := 0
	for offset: Vector2i in NEIGHBOR_BITS:
		var neighbor := cell + offset
		if GameManager.is_cell_inside(neighbor) \
				and _displayed_owners[GameManager.cell_to_index(neighbor)] == owner_id:
			mask |= NEIGHBOR_BITS[offset]
	return mask


## Dla każdego terytorium: pole najbliżej jego środka ciężkości -> tam stoją podpisy.
## Zwraca zbiór indeksów pól (klucze słownika).
func _find_label_anchors() -> Dictionary:
	var tiles_by_owner: Dictionary = {}
	for i in _displayed_owners.size():
		var owner_id := _displayed_owners[i]
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
