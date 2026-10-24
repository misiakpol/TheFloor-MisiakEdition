extends Node
## StatsManager (Autoload)
##
## Statystyki "dla nerdów" bieżącej sesji – trzymane w pamięci do zamknięcia gry
## (kolejne gry w tej samej sesji się sumują). Słucha wyłącznie sygnałów GameManagera.
## Gracze identyfikowani są po imieniu, więc te same osoby w kolejnych grach to jeden wpis.
##
## Ranking: tytuły (wygrane gry) > wygrane pojedynki > % wygranych > zdobyte pola > poprawne odp.

signal stats_changed

## Imię -> statystyki gracza (patrz [method _new_player_stats]).
var players: Dictionary = {}
## Liczniki całej sesji.
var session := {
	"games_started": 0,
	"games_finished": 0,
	"duels": 0,
	"finals": 0,
	"final_rounds": 0,
	"correct": 0,
	"passes": 0,
	"timeouts": 0,
}
## Najszybsza poprawna odpowiedź sesji: { seconds, player, answer, category }.
var fastest_answer: Dictionary = {}
## Najdłuższe zgadywanie zakończone sukcesem: { seconds, player, answer, category }.
var slowest_answer: Dictionary = {}
## Nazwa kategorii -> ile razy była grana (rundy pojedynków).
var category_plays: Dictionary = {}
## Odpowiedź -> ile razy ją spasowano ("najtrudniejsze" zdjęcia/utwory).
var passed_answers: Dictionary = {}
## Seria wygranych pojedynków z rzędu w bieżącej grze: imię -> liczba.
var _current_streaks: Dictionary = {}


func _ready() -> void:
	GameManager.floor_generated.connect(_on_floor_generated)
	GameManager.duel_started.connect(_on_duel_started)
	GameManager.duel_answered.connect(_on_duel_answered)
	GameManager.duel_timeout.connect(_on_duel_timeout)
	GameManager.final_round_finished.connect(_on_final_round_finished)
	GameManager.territory_captured.connect(_on_territory_captured)
	GameManager.game_over.connect(_on_game_over)


## Gracze posortowani wg rankingu. Każdy wpis to statystyki gracza + pola wyliczone
## ([code]rank, duels, win_rate, avg_answer[/code]).
func get_ranking() -> Array[Dictionary]:
	var ranking: Array[Dictionary] = []
	for stats: Dictionary in players.values():
		var entry := stats.duplicate()
		entry["duels"] = stats["duels_won"] + stats["duels_lost"]
		entry["win_rate"] = float(stats["duels_won"]) / entry["duels"] if entry["duels"] > 0 else 0.0
		entry["avg_answer"] = stats["answer_time_total"] / stats["correct"] if stats["correct"] > 0 else -1.0
		ranking.append(entry)
	ranking.sort_custom(_ranks_higher)
	for i in ranking.size():
		ranking[i]["rank"] = i + 1
	return ranking


## Kategoria grana najczęściej: { name, plays } (pusty słownik, gdy brak danych).
func get_most_played_category() -> Dictionary:
	return _max_entry(category_plays)


## Odpowiedź najczęściej pasowana: { name, plays }.
func get_most_passed_answer() -> Dictionary:
	return _max_entry(passed_answers)


func reset() -> void:
	players.clear()
	for key in session:
		session[key] = 0
	fastest_answer = {}
	slowest_answer = {}
	category_plays.clear()
	passed_answers.clear()
	_current_streaks.clear()
	stats_changed.emit()


#region Sygnały GameManagera

func _on_floor_generated(_columns: int, _rows: int) -> void:
	session["games_started"] += 1
	_current_streaks.clear()
	for player in GameManager.players:
		_stats_for(player["name"])["games"] += 1
	stats_changed.emit()


## Każda runda (także w finale) to jedno zagranie kategorii.
func _on_duel_started(_attacker_id: int, _defender_id: int) -> void:
	var category := CategoryManager.get_admin_name(GameManager.get_duel_category_key())
	category_plays[category] = category_plays.get(category, 0) + 1
	if GameManager.is_final and GameManager.final_round == 1:
		session["finals"] += 1
	stats_changed.emit()


func _on_duel_answered(player_id: int, correct: bool, seconds: float, answer: String) -> void:
	var stats := _stats_for(GameManager.get_player_name(player_id))
	if not correct:
		stats["passes"] += 1
		session["passes"] += 1
		passed_answers[answer] = passed_answers.get(answer, 0) + 1
		stats_changed.emit()
		return

	stats["correct"] += 1
	stats["answer_time_total"] += seconds
	if stats["fastest"] < 0.0 or seconds < stats["fastest"]:
		stats["fastest"] = seconds
	session["correct"] += 1
	var record := {
		"seconds": seconds,
		"player": stats["name"],
		"answer": answer,
		"category": CategoryManager.get_admin_name(GameManager.get_duel_category_key()),
	}
	if fastest_answer.is_empty() or seconds < fastest_answer["seconds"]:
		fastest_answer = record
	if slowest_answer.is_empty() or seconds > slowest_answer["seconds"]:
		slowest_answer = record
	stats_changed.emit()


func _on_duel_timeout(loser_side: int) -> void:
	_stats_for(GameManager.get_player_name(GameManager.get_duel_player_id(loser_side)))["timeouts"] += 1
	session["timeouts"] += 1
	stats_changed.emit()


func _on_final_round_finished(round_winner_id: int, _round_number: int) -> void:
	_stats_for(GameManager.get_player_name(round_winner_id))["final_rounds_won"] += 1
	session["final_rounds"] += 1
	stats_changed.emit()


func _on_territory_captured(winner_id: int, loser_id: int, tile_indices: PackedInt32Array) -> void:
	var winner := _stats_for(GameManager.get_player_name(winner_id))
	var loser := _stats_for(GameManager.get_player_name(loser_id))
	winner["duels_won"] += 1
	winner["tiles_captured"] += tile_indices.size()
	loser["duels_lost"] += 1
	session["duels"] += 1

	var streak: int = _current_streaks.get(winner["name"], 0) + 1
	_current_streaks[winner["name"]] = streak
	_current_streaks.erase(loser["name"])
	winner["best_streak"] = maxi(winner["best_streak"], streak)
	stats_changed.emit()


func _on_game_over(winner_id: int) -> void:
	_stats_for(GameManager.get_player_name(winner_id))["titles"] += 1
	session["games_finished"] += 1
	stats_changed.emit()

#endregion


func _stats_for(player_name: String) -> Dictionary:
	if not players.has(player_name):
		players[player_name] = _new_player_stats(player_name)
	return players[player_name]


func _new_player_stats(player_name: String) -> Dictionary:
	return {
		"name": player_name,
		"games": 0, ## Gry, w których był na podłodze.
		"titles": 0, ## Wygrane całe gry.
		"duels_won": 0,
		"duels_lost": 0,
		"tiles_captured": 0, ## Pola przejęte w wygranych pojedynkach.
		"correct": 0,
		"passes": 0,
		"timeouts": 0, ## Przegrane przez koniec czasu.
		"answer_time_total": 0.0,
		"fastest": -1.0, ## Najszybsza poprawna odpowiedź (s), -1 = brak.
		"best_streak": 0, ## Najdłuższa seria wygranych pojedynków w jednej grze.
		"final_rounds_won": 0,
	}


func _ranks_higher(a: Dictionary, b: Dictionary) -> bool:
	for key in ["titles", "duels_won", "win_rate", "tiles_captured", "correct"]:
		if a[key] != b[key]:
			return a[key] > b[key]
	return a["name"].naturalnocasecmp_to(b["name"]) < 0


func _max_entry(counts: Dictionary) -> Dictionary:
	var best := {}
	for key in counts:
		if best.is_empty() or counts[key] > best["plays"]:
			best = { "name": key, "plays": counts[key] }
	return best
