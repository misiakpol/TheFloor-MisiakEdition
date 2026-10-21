extends Node
## SettingsManager (Autoload)
##
## Trwałe ustawienia gry zapisywane w [constant SETTINGS_PATH] (ConfigFile):
## [br]- czas na odpowiedź w pojedynku (zegar każdego gracza),
## [br]- głośności szyn audio (Muzyka, SFX, Utwory-pytania).
## Wczytywane automatycznie przy starcie; zapis na żądanie z konsoli admina.
## Musi być zarejestrowany PO GameManagerze i AudioManagerze (używa ich w _ready).

signal settings_saved(path: String)

## user:// = %APPDATA%/Godot/app_userdata/The Floor/ (Windows) – działa też w wersji wyeksportowanej.
const SETTINGS_PATH := "user://settings.cfg"
const VOLUME_BUSES: Array[StringName] = [&"Music", &"SFX", &"Questions"]


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return # Pierwsze uruchomienie – zostają wartości domyślne.

	GameManager.set_duel_time(config.get_value("game", "duel_time", GameManager.DEFAULT_DUEL_TIME))
	for bus in VOLUME_BUSES:
		var volume: float = config.get_value("audio", String(bus), AudioManager.get_bus_volume_linear(bus))
		AudioManager.set_bus_volume_linear(bus, clampf(volume, 0.0, 1.0))
	print("[SettingsManager] Wczytano ustawienia: %s" % ProjectSettings.globalize_path(SETTINGS_PATH))


## Zapisuje bieżące wartości (czas pojedynku z GameManagera, głośności z AudioServera).
func save_settings() -> bool:
	var config := ConfigFile.new()
	config.set_value("game", "duel_time", GameManager.duel_time)
	for bus in VOLUME_BUSES:
		config.set_value("audio", String(bus), snappedf(AudioManager.get_bus_volume_linear(bus), 0.01))
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_error("[SettingsManager] Nie udało się zapisać ustawień (%s)." % error_string(error))
		return false
	settings_saved.emit(ProjectSettings.globalize_path(SETTINGS_PATH))
	return true
