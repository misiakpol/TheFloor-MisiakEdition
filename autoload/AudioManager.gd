extends Node
## AudioManager (Autoload)
##
## Jedno miejsce na całe audio gry:
## [br]- szyny: [code]Master[/code] (z limiterem przeciw przesterowaniom) <- [code]Music[/code], [code]SFX[/code],
##   [code]Questions[/code] (utwory-pytania z kategorii muzycznych, osobna głośność),
## [br]- muzyka: dwa odtwarzacze na szynie Music, zmiana utworu = płynny crossfade (Tween),
## [br]- efekty: pula odtwarzaczy na szynie SFX, więc dźwięki mogą na siebie nachodzić,
## [br]- muzyka zwycięstwa: losowy plik .ogg z folderu [code]audio/music/win/[/code] wczytywany
##   z dysku w locie (można podmieniać utwory obok pliku .exe), zapętlony, ale gaszony
##   automatycznie po [constant WIN_MUSIC_MAX_DURATION] s lub przy resecie gry.
##
## AudioManager nie zna zasad gry – kiedy co zagrać, decydują ekrany (Main, DuelScreen).

const SFX_CLICK: AudioStream = preload("res://audio/sfx/click.wav")
const SFX_BEEP: AudioStream = preload("res://audio/sfx/beep.wav")
const SFX_START: AudioStream = preload("res://audio/sfx/start.wav")
const SFX_CORRECT: AudioStream = preload("res://audio/sfx/correct.wav")
const SFX_PASS: AudioStream = preload("res://audio/sfx/fahh.wav")
const SFX_WOOSH: AudioStream = preload("res://audio/sfx/woosh.wav")
const MUSIC_MAIN: AudioStream = preload("res://audio/music/bg_main.ogg")
const MUSIC_DUEL: AudioStream = preload("res://audio/music/bg_duel.ogg")

## Folder z muzyką zwycięstwa – względem katalogu danych gry (jak folder kategorii).
const WIN_MUSIC_DIR := "audio/music/win"
const WIN_MUSIC_MAX_DURATION := 60.0

const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"
const QUESTION_BUS := &"Questions"
## Muzyka domyślnie ciszej niż efekty, żeby tykanie zegara było dobrze słychać.
const MUSIC_BUS_VOLUME_DB := -8.0
const SFX_BUS_VOLUME_DB := 0.0
const QUESTION_BUS_VOLUME_DB := 0.0
const SFX_POOL_SIZE := 12
const MUSIC_FADE_DURATION := 1.2

## Główny odtwarzacz muzyki i jego "partner" do crossfade'u (role zamieniają się przy każdej zmianie).
var _music_player: AudioStreamPlayer
var _music_player_alt: AudioStreamPlayer
var _music_tween: Tween
var _sfx_players: Array[AudioStreamPlayer] = []
var _next_sfx_player := 0
var _win_music_timer: Timer
## Odtwarzacz utworów-pytań (kategorie muzyczne) – niezależny od muzyki tła.
var _question_player: AudioStreamPlayer


func _ready() -> void:
	# Muzyka i efekty grają także przy wstrzymanym drzewie (np. przyszłe menu pauzy).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_buses()
	_setup_players()


#region Muzyka

## Płynnie przełącza muzykę na [param stream] (zapętloną). Ten sam utwór nie restartuje się.
## Zawsze wyłącza też licznik muzyki zwycięstwa (np. reset gry = nowa podłoga).
func play_music(stream: AudioStream, fade_duration := MUSIC_FADE_DURATION) -> void:
	_win_music_timer.stop()
	if stream == null:
		stop_music(fade_duration)
		return
	if _music_player.stream == stream and _music_player.playing:
		_crossfade_to(_music_player, fade_duration) # Dokończ ew. przerwany fade-in.
		return

	_set_looping(stream)
	# Nowy utwór startuje na drugim odtwarzaczu, stary jest w tym czasie wyciszany.
	var incoming := _music_player_alt
	_music_player_alt = _music_player
	_music_player = incoming
	incoming.stop()
	incoming.stream = stream
	incoming.volume_linear = 0.0
	incoming.play()
	_crossfade_to(incoming, fade_duration)


func stop_music(fade_duration := MUSIC_FADE_DURATION) -> void:
	_win_music_timer.stop()
	_crossfade_to(null, fade_duration)


## Gra losowy utwór z folderu [constant WIN_MUSIC_DIR]. Utwór jest zapętlony, ale
## AudioManager wycisza go po [constant WIN_MUSIC_MAX_DURATION] s. Zwraca false, gdy brak plików.
func play_win_music() -> bool:
	var stream := load_random_win_music()
	if stream == null:
		push_warning("[AudioManager] Brak plików .ogg w folderze: %s" % get_win_music_dir())
		return false
	play_music(stream, 0.6)
	_win_music_timer.start(WIN_MUSIC_MAX_DURATION) # play_music() zatrzymało timer – startujemy po nim.
	return true


func stop_win_music() -> void:
	if not _win_music_timer.is_stopped():
		stop_music()


func get_win_music_dir() -> String:
	return CategoryManager.get_data_dir().path_join(WIN_MUSIC_DIR)


## Wczytuje losowy plik .ogg z [constant WIN_MUSIC_DIR] bezpośrednio z dysku
## ([method AudioStreamOggVorbis.load_from_file]) – bez importu Godota.
func load_random_win_music() -> AudioStreamOggVorbis:
	var directory := get_win_music_dir()
	var files := Array(DirAccess.get_files_at(directory)).filter(
		func(file_name: String) -> bool: return file_name.get_extension().to_lower() == "ogg"
	)
	if files.is_empty():
		return null

	var path := directory.path_join(files.pick_random())
	var stream := AudioStreamOggVorbis.load_from_file(path)
	if stream == null:
		push_warning("[AudioManager] Nie udało się wczytać utworu: %s" % path)
		return null
	stream.loop = true
	print("[AudioManager] Muzyka zwycięstwa: %s" % path.get_file())
	return stream

#endregion


#region Utwory-pytania (kategorie muzyczne)

func play_question(stream: AudioStream) -> void:
	_question_player.stop()
	_question_player.stream = stream
	_question_player.stream_paused = false
	if stream != null:
		_question_player.play()


func stop_question() -> void:
	_question_player.stop()
	_question_player.stream = null


func set_question_paused(paused: bool) -> void:
	_question_player.stream_paused = paused

#endregion


#region Głośność (suwaki w konsoli admina)

## [param value] 0..1 (liniowo). Zero całkowicie wycisza szynę.
func set_bus_volume_linear(bus_name: StringName, value: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index == -1:
		return
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, 0.0001)))
	AudioServer.set_bus_mute(index, value <= 0.001)


func get_bus_volume_linear(bus_name: StringName) -> float:
	var index := AudioServer.get_bus_index(bus_name)
	if index == -1 or AudioServer.is_bus_mute(index):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(index))

#endregion


#region Efekty

## Odtwarza efekt na pierwszym wolnym odtwarzaczu z puli (gdy wszystkie grają –
## przerywa najstarszy). [param pitch] pozwala lekko różnicować powtarzane dźwięki.
func play_sfx(stream: AudioStream, volume_db := 0.0, pitch := 1.0) -> void:
	if stream == null:
		return
	var player := _get_free_sfx_player()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()


func _get_free_sfx_player() -> AudioStreamPlayer:
	for i in _sfx_players.size():
		var index := (_next_sfx_player + i) % _sfx_players.size()
		if not _sfx_players[index].playing:
			_next_sfx_player = (index + 1) % _sfx_players.size()
			return _sfx_players[index]
	var oldest := _sfx_players[_next_sfx_player]
	_next_sfx_player = (_next_sfx_player + 1) % _sfx_players.size()
	return oldest

#endregion


#region Konfiguracja

func _setup_buses() -> void:
	var master_index := AudioServer.get_bus_index(&"Master")
	if not _bus_has_limiter(master_index):
		var limiter := AudioEffectLimiter.new()
		limiter.ceiling_db = -0.3
		limiter.threshold_db = -1.0
		AudioServer.add_bus_effect(master_index, limiter)

	_ensure_bus(MUSIC_BUS, MUSIC_BUS_VOLUME_DB)
	_ensure_bus(SFX_BUS, SFX_BUS_VOLUME_DB)
	_ensure_bus(QUESTION_BUS, QUESTION_BUS_VOLUME_DB)


## Tworzy szynę (jeśli jej nie ma, np. brak default_bus_layout.tres) i podpina ją do Master.
func _ensure_bus(bus_name: StringName, volume_db: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index == -1:
		AudioServer.add_bus()
		index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_volume_db(index, volume_db)
	AudioServer.set_bus_send(index, &"Master")


func _bus_has_limiter(bus_index: int) -> bool:
	for i in AudioServer.get_bus_effect_count(bus_index):
		if AudioServer.get_bus_effect(bus_index, i) is AudioEffectLimiter:
			return true
	return false


func _setup_players() -> void:
	_music_player = _make_player("MusicPlayer", MUSIC_BUS)
	_music_player_alt = _make_player("MusicPlayerCrossfade", MUSIC_BUS)
	_question_player = _make_player("QuestionPlayer", QUESTION_BUS)
	for i in SFX_POOL_SIZE:
		_sfx_players.append(_make_player("SFXPlayer%d" % (i + 1), SFX_BUS))

	_win_music_timer = Timer.new()
	_win_music_timer.name = "WinMusicTimer"
	_win_music_timer.one_shot = true
	_win_music_timer.timeout.connect(stop_music)
	add_child(_win_music_timer)


func _make_player(player_name: String, bus: StringName) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.bus = bus
	add_child(player)
	return player


## Podgłaśnia [param target] (null = cisza), wycisza pozostały odtwarzacz i go zatrzymuje.
func _crossfade_to(target: AudioStreamPlayer, fade_duration: float) -> void:
	if _music_tween and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween().set_parallel()
	_music_tween.tween_interval(fade_duration) # Tween bez poleceń zgłasza błąd (np. stop przy ciszy).
	for player: AudioStreamPlayer in [_music_player, _music_player_alt]:
		if player == target:
			_music_tween.tween_property(player, "volume_linear", 1.0, fade_duration)
		elif player.playing:
			_music_tween.tween_property(player, "volume_linear", 0.0, fade_duration)
			_music_tween.tween_callback(player.stop).set_delay(fade_duration)


func _set_looping(stream: AudioStream) -> void:
	if stream is AudioStreamOggVorbis or stream is AudioStreamMP3:
		stream.set("loop", true)
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD

#endregion
