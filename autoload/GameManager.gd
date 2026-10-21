extends Node
## GameManager (Autoload)
##
## Jedyne źródło prawdy o stanie gry. Przepływ danych jest jednokierunkowy:
## [br]  AdminWindow --(wywołuje metody)--> GameManager --(emituje sygnały)--> Main / DuelScreen / AdminWindow
## [br]Okna nic o sobie nie wiedzą – komunikują się wyłącznie przez ten singleton.
##
## Model danych:
## - [member roster]: gracze wpisani ręcznie w konsoli admina (imię + kategoria),
## - [member players]: gracze bieżącej podłogi (id == indeks), każdy z kolorem i kategorią,
## - [member tile_owners]: dla każdej komórki siatki – id gracza, który ją posiada,
##   albo [constant EMPTY_CELL] (puste miejsca w ostatnim, wyśrodkowanym rzędzie).
## Siatka dopasowuje się do liczby graczy: kolumny = ceil(sqrt(n)), niepełny ostatni rząd
## jest wyśrodkowany.
##
## FINAŁ (na podłodze zostało 2 graczy) to rundy do dwóch wygranych:
## [br]1. kategoria zaatakowanego, [br]2. dogrywka – kategoria atakującego (jeszcze niezagrana),
## [br]3. przy remisie 1:1 – losowa kategoria z folderu [code]kategorie final[/code].
##
## Ruletka losuje w pierwszej kolejności graczy bez żadnego pojedynku na koncie i nigdy
## nie losuje gracza, który przed chwilą zszedł z podłogi ([member last_stepped_down_player]).
## Wygrany pojedynek przenosi WSZYSTKIE pola przegranego na zwycięzcę, a przegrany odpada.
##
## Pojedynek (faza DUEL) też jest liczony tutaj – zegary, talia zdjęć i to, kto odpowiada –
## dzięki czemu ekran TV (DuelScreen) i konsola admina zawsze pokazują ten sam stan.

signal roster_changed
signal floor_generated(columns: int, rows: int)
## Start animacji ruletki: [param candidate_ids] – gracze, po których skacze podświetlenie,
## [param winner_id] – na kim się zatrzyma. Po [param duration] s przychodzi [signal player_selected].
signal player_roll_started(candidate_ids: Array, winner_id: int, duration: float)
signal player_selected(player_id: int)
signal duel_started(attacker_id: int, defender_id: int)
## Nowe zdjęcie w pojedynku. [param previous_answer] – odpowiedź do poprzedniego zdjęcia
## (pusta przy pierwszym), [param action] – [enum DuelAction], który spowodował zmianę.
signal duel_image_changed(image: Dictionary, previous_answer: String, action: int)
signal duel_turn_changed(active_side: int)
## Odliczanie przed startem: 3, 2, 1 (po "1" pojawia się pierwsze zdjęcie).
signal duel_countdown_changed(value: int)
## Emitowany co klatkę, gdy zegar chodzi (oraz po każdej sekundzie kary).
signal duel_time_updated(times: PackedFloat32Array)
## Zegar aktywnego gracza przekroczył pełną sekundę (tykanie).
signal duel_clock_ticked(side: int, seconds_left: int)
## Pas: zaczyna się kara [constant PASS_PENALTY] s, zdjęcie czeka.
signal duel_penalty_started(side: int)
## Minęła sekunda kary (zdjęta z zegara gracza). [param penalty_left] = 2, 1, 0.
signal duel_penalty_ticked(side: int, penalty_left: int)
signal duel_timeout(loser_side: int)
## Pojedynek zakończony (rozstrzygnięty lub przerwany) – ekran pojedynku może zniknąć.
signal duel_ended
## Finał: runda [param round_number] rozstrzygnięta (za chwilę przyjdzie duel_started kolejnej
## rundy albo – gdy ktoś ma 2 wygrane – territory_captured i game_over).
signal final_round_finished(round_winner_id: int, round_number: int)
## Po przejęciu zwycięzca pozostaje aktywnym graczem (może walczyć dalej).
signal territory_captured(winner_id: int, loser_id: int, tile_indices: PackedInt32Array)
signal selection_cleared
signal game_over(winner_id: int)
## Ogólny sygnał "coś się zmieniło" – wygodny do odświeżania UI admina.
signal state_changed
signal log_message(text: String)

## ROLLING – trwa animacja ruletki (wynik jest już znany, ale jeszcze nie ogłoszony).
enum Phase { NO_FLOOR, IDLE, ROLLING, PLAYER_SELECTED, DUEL, GAME_OVER }
## READY – ekran pojedynku widoczny, czeka na START; COUNTDOWN – odliczanie 3-2-1;
## RUNNING – zegar aktywnego gracza chodzi; PENALTY – kara za pas (co sekundę -1 s);
## PAUSED – wstrzymane (dowolny z trzech powyższych); TIMEOUT – komuś skończył się czas.
enum DuelState { READY, COUNTDOWN, RUNNING, PENALTY, PAUSED, TIMEOUT }
enum DuelAction { START, CORRECT, PASS }

const MIN_PLAYERS := 2
const MAX_PLAYERS := 100
## Wartość w [member tile_owners] dla komórki bez pola (puste miejsce w ostatnim rzędzie).
const EMPTY_CELL := -1
const NEIGHBOR_OFFSETS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const ATTACKER_SIDE := 0 ## Lewa strona ekranu pojedynku.
const DEFENDER_SIDE := 1 ## Prawa strona ekranu pojedynku.
const DUEL_TIME := 45.0
const COUNTDOWN_FROM := 3
## Kara za pas w pełnych sekundach (zdejmowana po 1 s na sekundę).
const PASS_PENALTY := 3
const NO_CATEGORY := "Brak kategorii"
const ROLL_DURATION := 2.0
const FINAL_ROUNDS_TO_WIN := 2

var phase: Phase = Phase.NO_FLOOR
var columns := 0
var rows := 0

## Gracze przygotowani przed wygenerowaniem podłogi: [code]{ name, category }[/code].
## Pusta kategoria = losowa.
var roster: Array[Dictionary] = []
## Każdy gracz: [code]{ id, name, color, category: String, alive, duels: int }[/code]
## ([code]duels[/code] – w ilu rozstrzygniętych pojedynkach brał udział).
var players: Array[Dictionary] = []
## Indeks komórki -> id właściciela (lub [constant EMPTY_CELL]).
var tile_owners: PackedInt32Array = PackedInt32Array()

var selected_player_id := -1
var defender_id := -1
## Zwycięzca, który zszedł z podłogi – wykluczony z najbliższego losowania (-1 = nikt).
var last_stepped_down_player := -1
## Czy gracz "na ruchu" właśnie wygrał pojedynek (może walczyć dalej albo zejść z podłogi).
var selected_is_duel_winner := false
## Unieważnia opóźnione zakończenie starej ruletki (np. po wygenerowaniu nowej podłogi).
var _roll_id := 0

var duel_state: DuelState = DuelState.READY
var duel_active_side := ATTACKER_SIDE
## Pozostały czas: [ATTACKER_SIDE, DEFENDER_SIDE].
var duel_times := PackedFloat32Array([DUEL_TIME, DUEL_TIME])
## Aktualne zdjęcie: [code]{ answer, path }[/code] (puste przed STARTEM).
var duel_image: Dictionary = {}
## Aktualna liczba odliczania (3, 2, 1) w stanie COUNTDOWN.
var duel_countdown := 0
## Pozostałe sekundy kary w stanie PENALTY.
var duel_penalty_left := 0
var _duel_deck: Array[Dictionary] = []
## Kategoria aktualnie granej rundy (nazwa lub klucz "final:..." – patrz CategoryManager).
var duel_category := ""
## Finał: true, gdy pojedynek toczy się między dwoma ostatnimi graczami.
var is_final := false
## Numer rundy finału (1 = kategoria obrońcy, 2 = dogrywka, 3 = rozstrzygająca).
var final_round := 0
## Wygrane rundy finału: [ATTACKER_SIDE, DEFENDER_SIDE].
var final_score := PackedInt32Array([0, 0])
## Czas, który upłynął w bieżącym kroku odliczania / kary (kroki co 1 s).
var _duel_step_time := 0.0
var _state_before_pause: DuelState = DuelState.RUNNING


func _process(delta: float) -> void:
	if phase != Phase.DUEL:
		return
	match duel_state:
		DuelState.COUNTDOWN:
			_process_countdown(delta)
		DuelState.RUNNING:
			_process_clock(delta)
		DuelState.PENALTY:
			_process_penalty(delta)


#region Gracze (przed wygenerowaniem podłogi)

func add_roster_player(player_name: String, category: String) -> bool:
	var clean_name := TextUtils.to_proper(player_name) # "jan kowalski" -> "Jan Kowalski"
	if not _is_valid_roster_name(clean_name, -1):
		return false
	roster.append({ "name": clean_name, "category": category })
	_log("Dodano gracza: %s (%s)." % [clean_name, _describe_roster_category(category)])
	roster_changed.emit()
	return true


func update_roster_player(index: int, player_name: String, category: String) -> bool:
	if index < 0 or index >= roster.size():
		return false
	var clean_name := TextUtils.to_proper(player_name) # "jan kowalski" -> "Jan Kowalski"
	if not _is_valid_roster_name(clean_name, index):
		return false
	roster[index] = { "name": clean_name, "category": category }
	_log("Zmieniono gracza: %s (%s)." % [clean_name, _describe_roster_category(category)])
	roster_changed.emit()
	return true


func remove_roster_player(index: int) -> void:
	if index < 0 or index >= roster.size():
		return
	var removed: Dictionary = roster.pop_at(index)
	_log("Usunięto gracza: %s." % removed["name"])
	roster_changed.emit()


func clear_roster() -> void:
	if roster.is_empty():
		return
	roster.clear()
	_log("Wyczyszczono listę graczy.")
	roster_changed.emit()


## Wymiary siatki dla [param player_count] graczy: kolumny = ceil(sqrt(n)),
## wiersze = ile trzeba (np. 13 -> 4 x 4, 17 -> 5 x 4).
func get_grid_size_for(player_count: int) -> Vector2i:
	var count := maxi(player_count, 1)
	var grid_columns := ceili(sqrt(float(count)))
	return Vector2i(grid_columns, ceili(float(count) / grid_columns))


## Indeksy komórek, w których stoją pola: wszystkie pełne rzędy + wyśrodkowany ostatni rząd.
## Przy nieparzystej różnicy ostatni rząd przesuwa się o pół pola w lewo (siatka jest dyskretna).
func get_playable_cells(player_count: int) -> Array[int]:
	var grid := get_grid_size_for(player_count)
	var cells: Array[int] = []
	for i in (grid.y - 1) * grid.x:
		cells.append(i)
	var last_row_count := player_count - (grid.y - 1) * grid.x
	@warning_ignore("integer_division")
	var offset := (grid.x - last_row_count) / 2
	for k in last_row_count:
		cells.append((grid.y - 1) * grid.x + offset + k)
	return cells

#endregion


#region Akcje podłogi (wywoływane przez panel admina)

## Tworzy podłogę dla [param player_count] graczy (nie mniej niż jest na liście).
## Gracze ponad listę to automatyczni "Gracz N" z losową, jeszcze niezajętą kategorią.
func generate_floor(player_count: int, shuffle_positions := true) -> void:
	if phase == Phase.DUEL:
		_log("Najpierw zakończ pojedynek.")
		return
	if roster.size() > MAX_PLAYERS:
		_log("Maksymalnie %d graczy na podłodze." % MAX_PLAYERS)
		return

	var tile_count := clampi(maxi(player_count, roster.size()), MIN_PLAYERS, MAX_PLAYERS)
	var grid := get_grid_size_for(tile_count)
	columns = grid.x
	rows = grid.y
	players.clear()

	var used_categories: Array[String] = []
	for entry in roster:
		if CategoryManager.has_category(entry["category"]):
			used_categories.append(entry["category"])
	var taken_names := roster.map(func(entry: Dictionary) -> String: return str(entry["name"]).to_lower())

	for i in tile_count:
		var entry: Dictionary = roster[i] if i < roster.size() else {}
		var player_name: String = entry.get("name", "")
		if player_name.is_empty():
			player_name = _make_placeholder_name(taken_names)

		var category: String = entry.get("category", "")
		if not CategoryManager.has_category(category):
			if not category.is_empty():
				_log("Kategoria \"%s\" nie istnieje – %s dostaje losową." % [category, player_name])
			category = _pick_free_category(used_categories)
			used_categories.append(category)

		players.append({
			"id": i,
			"name": player_name,
			"color": _make_player_color(i),
			"category": category,
			"alive": true,
			"duels": 0,
		})

	var cells := get_playable_cells(tile_count)
	if shuffle_positions:
		cells.shuffle()
	tile_owners.resize(columns * rows)
	tile_owners.fill(EMPTY_CELL)
	for player_id in tile_count:
		tile_owners[cells[player_id]] = player_id

	selected_player_id = -1
	defender_id = -1
	last_stepped_down_player = -1
	selected_is_duel_winner = false
	_roll_id += 1
	_log("Wygenerowano podłogę dla %d graczy (siatka %d x %d): %d z listy + %d automatycznych." % [
		tile_count, columns, rows, roster.size(), tile_count - roster.size(),
	])
	for player in players:
		if CategoryManager.get_questions(player["category"]).is_empty():
			_log("Uwaga: kategoria \"%s\" (%s) nie ma zdjęć ani utworów – pojedynek o nią będzie niemożliwy." % [
				player["category"], player["name"],
			])

	floor_generated.emit(columns, rows)
	_set_phase(Phase.IDLE)


## Ruletka. Jeśli na ruchu jest zwycięzca pojedynku, nowe losowanie oznacza, że zszedł z podłogi.
func select_random_player() -> void:
	if phase not in [Phase.IDLE, Phase.PLAYER_SELECTED]:
		_log("Nie można teraz losować gracza.")
		return
	if phase == Phase.PLAYER_SELECTED and selected_is_duel_winner:
		_mark_stepped_down(selected_player_id)

	var candidates := get_roll_pool()
	if candidates.is_empty():
		_log("Brak graczy, którzy mogą walczyć.")
		return

	# Wynik znany od razu; ekran TV pokazuje go po animacji ruletki (skacząc po tej samej puli).
	var winner_id: int = candidates.pick_random()
	selected_is_duel_winner = false
	selected_player_id = -1
	defender_id = -1
	_roll_id += 1
	_set_phase(Phase.ROLLING)
	player_roll_started.emit(candidates, winner_id, ROLL_DURATION)
	get_tree().create_timer(ROLL_DURATION).timeout.connect(_finish_roll.bind(_roll_id, winner_id))


func _finish_roll(roll_id: int, winner_id: int) -> void:
	if roll_id != _roll_id or phase != Phase.ROLLING:
		return
	selected_player_id = winner_id
	# Wykluczenie obowiązuje tylko w jednym, bezpośrednio następnym losowaniu.
	last_stepped_down_player = -1
	_log("Wylosowano: %s" % describe_player(selected_player_id))
	player_selected.emit(selected_player_id)
	_set_phase(Phase.PLAYER_SELECTED)


## Zwycięzca pojedynku rezygnuje z dalszej walki i wraca na planszę.
## Nie może zostać wylosowany w najbliższym losowaniu.
func step_down() -> void:
	if phase != Phase.PLAYER_SELECTED or not selected_is_duel_winner:
		return
	_mark_stepped_down(selected_player_id)
	selected_is_duel_winner = false
	selected_player_id = -1
	selection_cleared.emit()
	_set_phase(Phase.IDLE)


func cancel_selection() -> void:
	if phase not in [Phase.PLAYER_SELECTED, Phase.DUEL]:
		return
	if phase == Phase.DUEL:
		_end_duel()
	is_final = false
	final_round = 0
	selected_player_id = -1
	defender_id = -1
	selected_is_duel_winner = false
	_log("Anulowano wybór.")
	selection_cleared.emit()
	_set_phase(Phase.IDLE)


## Pula ruletki: żywi gracze z sąsiadem, bez gracza, który właśnie zszedł z podłogi.
## Jeśli są wśród nich gracze bez żadnego pojedynku – losujemy tylko spośród nich.
func get_roll_pool() -> Array[int]:
	var can_fight := get_alive_player_ids().filter(
		func(id: int) -> bool: return not get_neighbor_player_ids(id).is_empty()
	)
	var pool := can_fight.filter(func(id: int) -> bool: return id != last_stepped_down_player)
	if pool.is_empty():
		pool = can_fight # Został tylko on – i tak musi walczyć.
	var fresh := pool.filter(func(id: int) -> bool: return get_player_duel_count(id) == 0)
	var result: Array[int] = []
	result.assign(fresh if not fresh.is_empty() else pool)
	return result


func _mark_stepped_down(player_id: int) -> void:
	last_stepped_down_player = player_id
	_log("%s schodzi z podłogi – nie weźmie udziału w najbliższym losowaniu." % get_player_name(player_id))

#endregion


#region Pojedynek

## Otwiera ekran pojedynku. Kategoria = kategoria obrońcy (jak w teleturnieju).
## Zegar rusza dopiero po [method begin_duel].
func start_duel(target_player_id: int) -> void:
	if phase != Phase.PLAYER_SELECTED:
		_log("Najpierw wylosuj gracza.")
		return
	if target_player_id not in get_neighbor_player_ids(selected_player_id):
		_log("%s nie sąsiaduje z aktywnym graczem." % get_player_name(target_player_id))
		return

	var category := get_player_category(target_player_id)
	if CategoryManager.get_questions(category).is_empty():
		_log("Kategoria \"%s\" nie ma zdjęć ani utworów – wybierz innego przeciwnika." % category)
		return

	defender_id = target_player_id
	is_final = get_alive_player_ids().size() == 2
	final_round = 1 if is_final else 0
	final_score = PackedInt32Array([0, 0])
	if is_final:
		_log("FINAŁ! Rundy do %d wygranych." % FINAL_ROUNDS_TO_WIN)
	_start_round(category)
	_set_phase(Phase.DUEL)


## Przygotowuje (kolejną) rundę: nowa kategoria i talia, zegary od 45 s, czeka na START.
func _start_round(category: String) -> void:
	duel_category = category
	var deck := CategoryManager.get_questions(category)
	deck.shuffle()
	_duel_deck = deck
	if not _duel_deck.is_empty():
		CategoryManager.preload_file(_duel_deck.back()["path"])
	duel_image = {}
	duel_times = PackedFloat32Array([DUEL_TIME, DUEL_TIME])
	duel_active_side = ATTACKER_SIDE
	duel_state = DuelState.READY
	duel_countdown = 0
	duel_penalty_left = 0

	_log("%s: %s vs %s | kategoria: %s (%s)" % [
		get_final_round_title() if is_final else "POJEDYNEK",
		get_player_name(selected_player_id), get_player_name(defender_id),
		get_duel_category_name(), CategoryManager.describe_question_count(category),
	])
	duel_started.emit(selected_player_id, defender_id)


## START: odliczanie 3-2-1, po nim pierwsze zdjęcie i zegar zaczynającego gracza.
func begin_duel() -> void:
	if phase != Phase.DUEL or duel_state != DuelState.READY:
		return
	duel_state = DuelState.COUNTDOWN
	duel_countdown = COUNTDOWN_FROM
	_duel_step_time = 0.0
	duel_countdown_changed.emit(duel_countdown)
	state_changed.emit()


## Poprawna odpowiedź: zegar przechodzi na przeciwnika, pojawia się kolejne zdjęcie.
func duel_correct() -> void:
	if phase != Phase.DUEL or duel_state != DuelState.RUNNING:
		return
	duel_active_side = 1 - duel_active_side
	_show_next_image(DuelAction.CORRECT)
	duel_turn_changed.emit(duel_active_side)


## Pas: zdjęcie zostaje (przyciemnione), a przez [constant PASS_PENALTY] s co sekundę
## z zegara gracza schodzi 1 s. Po karze ten sam gracz dostaje nowe zdjęcie.
func duel_pass() -> void:
	if phase != Phase.DUEL or duel_state != DuelState.RUNNING:
		return
	duel_state = DuelState.PENALTY
	duel_penalty_left = PASS_PENALTY
	_duel_step_time = 0.0
	duel_penalty_started.emit(duel_active_side)
	state_changed.emit()


## Wstrzymuje / wznawia zegar, odliczanie startowe albo karę – co akurat trwa.
func toggle_duel_pause() -> void:
	if phase != Phase.DUEL:
		return
	if duel_state == DuelState.PAUSED:
		duel_state = _state_before_pause
		_log("Wznowiono.")
	elif duel_state in [DuelState.COUNTDOWN, DuelState.RUNNING, DuelState.PENALTY]:
		_state_before_pause = duel_state
		duel_state = DuelState.PAUSED
		_log("Pauza.")
	else:
		return
	state_changed.emit()


## Zatwierdza wynik po upływie czasu: wygrywa gracz, któremu czas NIE minął.
func finish_duel() -> void:
	if phase != Phase.DUEL or duel_state != DuelState.TIMEOUT:
		return
	resolve_duel(duel_active_side == DEFENDER_SIDE)


## Ręczne rozstrzygnięcie. [param attacker_wins] = true -> wygrywa wylosowany gracz.
func resolve_duel(attacker_wins: bool) -> void:
	if phase != Phase.DUEL:
		return
	if is_final and not _finish_final_round(attacker_wins):
		return # Finał trwa – zaczęła się kolejna runda.

	var winner_id := selected_player_id if attacker_wins else defender_id
	var loser_id := defender_id if attacker_wins else selected_player_id
	var captured := get_tiles_of(loser_id)
	# Zasada kategorii: grana była kategoria obrońcy – po pojedynku znika ona z gry,
	# a zwycięzca (niezależnie od tego, kto wygrał) gra dalej kategorią ATAKUJĄCEGO.
	var played_category := get_duel_category_name()
	var attacker_category := get_player_category(selected_player_id)
	is_final = false
	final_round = 0
	_end_duel()

	for tile_index in captured:
		tile_owners[tile_index] = winner_id
	players[loser_id]["alive"] = false
	players[winner_id]["duels"] += 1
	players[loser_id]["duels"] += 1
	players[winner_id]["category"] = attacker_category
	_log("Kategoria \"%s\" zagrana i usunięta; %s gra teraz kategorią \"%s\"." % [
		played_category, get_player_name(winner_id), attacker_category,
	])

	selected_player_id = winner_id
	selected_is_duel_winner = true
	defender_id = -1
	_log("%s przejmuje terytorium gracza %s (+%d pól)." % [
		get_player_name(winner_id), get_player_name(loser_id), captured.size(),
	])
	territory_captured.emit(winner_id, loser_id, captured)

	if get_alive_player_ids().size() <= 1:
		_log("KONIEC GRY! Zwycięzca: %s" % get_player_name(winner_id))
		game_over.emit(winner_id)
		_set_phase(Phase.GAME_OVER)
	else:
		_set_phase(Phase.PLAYER_SELECTED)


## Zapisuje wynik rundy finału. Zwraca true, gdy finał jest rozstrzygnięty
## (ktoś ma [constant FINAL_ROUNDS_TO_WIN] wygrane), inaczej od razu startuje następną rundę.
func _finish_final_round(attacker_wins: bool) -> bool:
	var side := ATTACKER_SIDE if attacker_wins else DEFENDER_SIDE
	var round_winner := get_duel_player_id(side)
	final_score[side] += 1
	_log("Finał – rundę %d wygrywa %s. Wynik %d:%d." % [
		final_round, get_player_name(round_winner),
		final_score[ATTACKER_SIDE], final_score[DEFENDER_SIDE],
	])
	final_round_finished.emit(round_winner, final_round)
	if final_score[side] >= FINAL_ROUNDS_TO_WIN:
		return true

	var next_category := ""
	if final_round == 1:
		# Dogrywka: kategoria atakującego – jedyna jeszcze niewykorzystana.
		next_category = get_player_category(selected_player_id)
		if CategoryManager.get_questions(next_category).is_empty():
			_log("Kategoria atakującego nie ma pytań – dogrywka z kategorii finałowej.")
			next_category = _pick_final_category()
	else:
		# Remis 1:1 – runda rozstrzygająca z folderu "kategorie final".
		next_category = _pick_final_category()
	final_round += 1

	if next_category.is_empty():
		_log("Brak kategorii na kolejną rundę – rozstrzygnij finał ręcznie.")
		next_category = duel_category
	CategoryManager.clear_cache()
	_start_round(next_category)
	state_changed.emit()
	return false


## Losowa kategoria z folderu "kategorie final"; gdy pusty – zwykła kategoria,
## która nie była grana w tym finale.
func _pick_final_category() -> String:
	var keys: Array = CategoryManager.get_final_category_keys()
	if keys.is_empty():
		_log("Folder \"%s\" jest pusty – losuję zwykłą kategorię." % CategoryManager.FINAL_CATEGORIES_DIR)
		var played := [get_player_category(defender_id), get_player_category(selected_player_id), duel_category]
		keys = CategoryManager.get_category_names().filter(
			func(category_name: String) -> bool:
				return category_name not in played and not CategoryManager.get_questions(category_name).is_empty()
		)
	return keys.pick_random() if not keys.is_empty() else ""


func _process_countdown(delta: float) -> void:
	if not _advance_step(delta):
		return
	duel_countdown -= 1
	if duel_countdown > 0:
		duel_countdown_changed.emit(duel_countdown)
		return
	duel_state = DuelState.RUNNING
	_show_next_image(DuelAction.START)
	duel_turn_changed.emit(duel_active_side)
	state_changed.emit()


func _process_clock(delta: float) -> void:
	var side := duel_active_side
	var before := duel_times[side]
	duel_times[side] = maxf(before - delta, 0.0)
	duel_time_updated.emit(duel_times)
	if duel_times[side] <= 0.0:
		_on_duel_time_out()
	elif ceili(duel_times[side]) < ceili(before):
		# Wyświetlana liczba sekund właśnie się zmieniła.
		duel_clock_ticked.emit(side, ceili(duel_times[side]))


func _process_penalty(delta: float) -> void:
	if not _advance_step(delta):
		return
	var side := duel_active_side
	duel_times[side] = maxf(duel_times[side] - 1.0, 0.0)
	duel_penalty_left -= 1
	duel_time_updated.emit(duel_times)
	duel_penalty_ticked.emit(side, duel_penalty_left)
	if duel_times[side] <= 0.0:
		_on_duel_time_out()
	elif duel_penalty_left <= 0:
		duel_state = DuelState.RUNNING
		_show_next_image(DuelAction.PASS)
		state_changed.emit()


## Zwraca true, gdy minęła kolejna pełna sekunda kroku (odliczanie / kara).
func _advance_step(delta: float) -> bool:
	_duel_step_time += delta
	if _duel_step_time < 1.0:
		return false
	_duel_step_time -= 1.0
	return true


func _show_next_image(action: DuelAction) -> void:
	var previous_answer: String = duel_image.get("answer", "")
	if _duel_deck.is_empty():
		_duel_deck = CategoryManager.get_questions(duel_category)
		_duel_deck.shuffle()
		# Nie pokazuj tego samego zdjęcia dwa razy z rzędu po przetasowaniu.
		if _duel_deck.size() > 1 and _duel_deck.back()["path"] == duel_image.get("path", ""):
			_duel_deck.push_front(_duel_deck.pop_back())
		_log("Pokazano już wszystkie zdjęcia z kategorii – tasuję od nowa.")

	duel_image = _duel_deck.pop_back()
	if not _duel_deck.is_empty():
		CategoryManager.preload_file(_duel_deck.back()["path"])
	duel_image_changed.emit(duel_image, previous_answer, action)


func _on_duel_time_out() -> void:
	duel_state = DuelState.TIMEOUT
	var loser_side := duel_active_side
	_log("Koniec czasu: %s! Wygrywa %s." % [
		get_player_name(get_duel_player_id(loser_side)),
		get_player_name(get_duel_player_id(1 - loser_side)),
	])
	duel_timeout.emit(loser_side)
	state_changed.emit()


func _end_duel() -> void:
	duel_state = DuelState.READY
	duel_category = ""
	duel_countdown = 0
	duel_penalty_left = 0
	duel_image = {}
	_duel_deck.clear()
	CategoryManager.clear_cache()
	duel_ended.emit()

#endregion


#region Zapytania (read-only)

func get_player(player_id: int) -> Dictionary:
	if player_id < 0 or player_id >= players.size():
		return {}
	return players[player_id]


func get_player_name(player_id: int) -> String:
	return get_player(player_id).get("name", "?")


func get_player_color(player_id: int) -> Color:
	return get_player(player_id).get("color", Color.GRAY)


func get_player_duel_count(player_id: int) -> int:
	return get_player(player_id).get("duels", 0)


func get_player_category(player_id: int) -> String:
	return get_player(player_id).get("category", "-")


func describe_player(player_id: int) -> String:
	var player := get_player(player_id)
	if player.is_empty():
		return "-"
	return "%s (%s, pól: %d, pojedynków: %d)" % [
		player["name"], player["category"], get_tiles_of(player_id).size(), player["duels"],
	]


## Nazwa granej kategorii DO WYŚWIETLENIA (zwykle kategoria obrońcy; w finale – kategoria rundy).
func get_duel_category_name() -> String:
	if duel_category.is_empty():
		return get_player_category(defender_id) if defender_id >= 0 else "-"
	return CategoryManager.get_display_name(duel_category)


## Klucz granej kategorii do zapytań w CategoryManager (pytania, tło, czy muzyczna).
func get_duel_category_key() -> String:
	return duel_category


## Czy pojedynek toczy się w kategorii muzycznej (pytania = utwory .ogg)?
func is_duel_music() -> bool:
	return CategoryManager.is_music_category(duel_category)


## Np. "FINAŁ · DOGRYWKA" – podpis rundy finału na ekranach.
func get_final_round_title() -> String:
	match final_round:
		1:
			return "FINAŁ · RUNDA 1"
		2:
			return "FINAŁ · DOGRYWKA"
		_:
			return "FINAŁ · RUNDA ROZSTRZYGAJĄCA"


func get_duel_player_id(side: int) -> int:
	return selected_player_id if side == ATTACKER_SIDE else defender_id


## Zwycięzca po upływie czasu (-1, jeśli czas jeszcze nikomu nie minął).
func get_duel_winner_id() -> int:
	if phase != Phase.DUEL or duel_state != DuelState.TIMEOUT:
		return -1
	return get_duel_player_id(1 - duel_active_side)


func get_tile_owner(tile_index: int) -> int:
	return tile_owners[tile_index]


func get_alive_player_ids() -> Array[int]:
	var result: Array[int] = []
	for player in players:
		if player["alive"]:
			result.append(player["id"])
	return result


func get_tiles_of(player_id: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for i in tile_owners.size():
		if tile_owners[i] == player_id:
			result.append(i)
	return result


## Gracze, których terytorium styka się bokiem z terytorium [param player_id].
func get_neighbor_player_ids(player_id: int) -> Array[int]:
	var result: Array[int] = []
	for tile_index in get_tiles_of(player_id):
		for neighbor_index in get_neighbor_tiles(tile_index):
			var owner_id := tile_owners[neighbor_index]
			if owner_id != player_id and owner_id not in result:
				result.append(owner_id)
	result.sort()
	return result


func get_neighbor_tiles(tile_index: int) -> Array[int]:
	var result: Array[int] = []
	var cell := index_to_cell(tile_index)
	for offset: Vector2i in NEIGHBOR_OFFSETS:
		var neighbor := cell + offset
		if is_cell_inside(neighbor) and tile_owners[cell_to_index(neighbor)] != EMPTY_CELL:
			result.append(cell_to_index(neighbor))
	return result


func is_cell_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < columns and cell.y >= 0 and cell.y < rows


@warning_ignore("integer_division")
func index_to_cell(tile_index: int) -> Vector2i:
	return Vector2i(tile_index % columns, tile_index / columns)


func cell_to_index(cell: Vector2i) -> int:
	return cell.y * columns + cell.x

#endregion


func _set_phase(new_phase: Phase) -> void:
	phase = new_phase
	state_changed.emit()


func _log(text: String) -> void:
	print("[GameManager] " + text)
	log_message.emit(text)


func _is_valid_roster_name(player_name: String, ignored_index: int) -> bool:
	if player_name.is_empty():
		_log("Podaj imię gracza.")
		return false
	for i in roster.size():
		if i != ignored_index and str(roster[i]["name"]).to_lower() == player_name.to_lower():
			_log("Gracz \"%s\" już jest na liście." % player_name)
			return false
	return true


func _describe_roster_category(category: String) -> String:
	return category if not category.is_empty() else "losowa kategoria"


func _make_placeholder_name(taken_names: Array) -> String:
	var number := 1
	while ("gracz %d" % number) in taken_names:
		number += 1
	taken_names.append("gracz %d" % number)
	return "Gracz %d" % number


## Losowa kategoria ze zdjęciami, w miarę możliwości jeszcze nieużyta przez innego gracza.
func _pick_free_category(used_categories: Array[String]) -> String:
	var all_names: Array = CategoryManager.get_category_names()
	var playable := all_names.filter(
		func(category: String) -> bool: return not CategoryManager.get_questions(category).is_empty()
	)
	if playable.is_empty():
		playable = all_names
	if playable.is_empty():
		return NO_CATEGORY

	var unused := playable.filter(func(category: String) -> bool: return category not in used_categories)
	return (unused if not unused.is_empty() else playable).pick_random()


## Złoty podział na kole barw = kolejne kolory są od siebie maksymalnie odległe.
func _make_player_color(index: int) -> Color:
	var hue := fposmod(0.07 + index * 0.618034, 1.0)
	var value := 0.78 if index % 2 == 0 else 0.62
	return Color.from_hsv(hue, 0.62, value)
