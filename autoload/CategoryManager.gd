extends Node
## CategoryManager (Autoload)
##
## Kategorie to podfoldery katalogu [code]kategorie/[/code] leżącego obok gry:
## [codeblock]
## kategorie/
## ├─ Kuchnia Śląska/          <- kategoria OBRAZKOWA: nazwa folderu = nazwa kategorii
## │  ├─ Rolada.jpg            <- nazwa pliku (bez rozszerzenia) = poprawna odpowiedź
## │  └─ Kluski śląskie.png
## └─ Hity lat 80/             <- kategoria MUZYCZNA: zawiera pliki .ogg
##    ├─ tlo.jpg               <- (opcjonalnie) JEDEN obrazek – tło na ekranie pojedynku
##    ├─ Take on me - a-ha.ogg <- nazwa pliku = poprawna odpowiedź
##    └─ ...
## [/codeblock]
## Pliki ładowane są w locie z dysku (bez systemu importu Godota) – można je podmieniać
## obok pliku .exe i przeskanować folder bez restartu gry.
## Plik [code].gdignore[/code] w folderze kategorii blokuje ich import w edytorze.

## Emitowany po (prze)skanowaniu folderu kategorii.
signal categories_loaded(count: int)
## Emitowany, gdy folderu nie da się odczytać lub jest pusty.
signal load_failed(message: String)

const CATEGORIES_DIR := "kategorie"
const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
const AUDIO_EXTENSIONS: PackedStringArray = ["ogg"]
const KIND_IMAGE := "image"
const KIND_MUSIC := "music"
## Większe zdjęcia są zmniejszane przy wczytaniu (pamięć + brak przycięć na TV).
const MAX_IMAGE_SIZE := Vector2i(1920, 1080)

## Wczytane kategorie, posortowane po nazwie. Każdy element:
## [code]{ "name", "path", "kind": KIND_IMAGE|KIND_MUSIC, "background": String, "questions": Array[Dictionary] }[/code],
## a każde pytanie: [code]{ "answer": String, "path": String, "kind": KIND_IMAGE|KIND_MUSIC }[/code].
## [code]background[/code] – ścieżka obrazka tła kategorii muzycznej (lub pusta).
var categories: Array[Dictionary] = []

## Cache zasobów: absolutna ścieżka -> Texture2D / AudioStream.
var _resource_cache: Dictionary = {}
## Pliki wczytywane w tle (kolejne pytanie pojedynku): ścieżka -> id zadania WorkerThreadPool.
var _preload_tasks: Dictionary = {}
## Wyniki wczytywania w tle: ścieżka -> Image / AudioStream (dostęp chroniony mutexem).
var _preloaded: Dictionary = {}
var _preload_mutex := Mutex.new()


func _ready() -> void:
	reload()


func _exit_tree() -> void:
	clear_cache()


## Katalog z danymi gry:
## - w edytorze: katalog projektu (res:// zglobalizowany do ścieżki systemowej),
## - w eksporcie: katalog, w którym leży plik wykonywalny.
func get_data_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()


func get_categories_dir() -> String:
	return get_data_dir().path_join(CATEGORIES_DIR)


## Skanuje folder kategorii od nowa. Można wywołać w trakcie gry (poza pojedynkiem).
func reload() -> void:
	clear_cache()
	categories.clear()

	var root := get_categories_dir()
	if not DirAccess.dir_exists_absolute(root):
		DirAccess.make_dir_recursive_absolute(root)
		_fail("Utworzono pusty folder kategorii: %s – dodaj do niego podfoldery ze zdjęciami." % root)
		return

	var folder_names := Array(DirAccess.get_directories_at(root))
	folder_names.sort_custom(_natural_less)

	for folder_name: String in folder_names:
		if folder_name.begins_with("."):
			continue
		categories.append(_scan_category(root.path_join(folder_name), folder_name.strip_edges()))

	if categories.is_empty():
		_fail("Folder %s nie zawiera żadnych podfolderów z kategoriami." % root)
		return

	print("[CategoryManager] Wczytano %d kategorii z: %s" % [categories.size(), root])
	categories_loaded.emit(categories.size())


func get_category(category_name: String) -> Dictionary:
	for category in categories:
		if category["name"] == category_name:
			return category
	return {}


func has_category(category_name: String) -> bool:
	return not get_category(category_name).is_empty()


func is_music_category(category_name: String) -> bool:
	return get_category(category_name).get("kind", KIND_IMAGE) == KIND_MUSIC


## Ścieżka obrazka tła kategorii muzycznej (pusta, gdy go brak).
func get_background(category_name: String) -> String:
	return get_category(category_name).get("background", "")


func get_category_names() -> Array[String]:
	var names: Array[String] = []
	for category in categories:
		names.append(category["name"])
	return names


## Kopia listy pytań kategorii ([code]{ answer, path, kind }[/code]) – można ją bezpiecznie tasować.
func get_questions(category_name: String) -> Array[Dictionary]:
	var category := get_category(category_name)
	if category.is_empty():
		return []
	var questions: Array[Dictionary] = category["questions"]
	return questions.duplicate()


## Opis liczby pytań do UI, np. "12 zdj." albo "40 utw.".
func describe_question_count(category_name: String) -> String:
	var count := get_questions(category_name).size()
	return "%d %s" % [count, "utw." if is_music_category(category_name) else "zdj."]


## Zaczyna wczytywać plik pytania (zdjęcie lub utwór) w wątku roboczym, żeby późniejsze
## [method load_texture] / [method load_audio] było natychmiastowe.
func preload_file(path: String) -> void:
	if path.is_empty() or _resource_cache.has(path) or _preload_tasks.has(path):
		return
	_preload_tasks[path] = WorkerThreadPool.add_task(
			_load_in_background.bind(path), false, "Preload " + path.get_file())


## Zwraca teksturę zdjęcia (z cache, z wątku preloadu albo dekodując je teraz).
## Zwraca [code]null[/code], jeśli pliku nie ma lub format jest nieobsługiwany.
func load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _resource_cache.has(path):
		return _resource_cache[path] as Texture2D

	var image := _take_preloaded(path) as Image if _preload_tasks.has(path) else _decode_image(path)
	if image == null:
		return null
	var texture := ImageTexture.create_from_image(image)
	_resource_cache[path] = texture
	return texture


## Zwraca utwór .ogg wczytany z dysku (zapętlony – gra, dopóki ktoś nie odgadnie).
func load_audio(path: String) -> AudioStream:
	if path.is_empty():
		return null
	if _resource_cache.has(path):
		return _resource_cache[path] as AudioStream

	var stream := _take_preloaded(path) as AudioStream if _preload_tasks.has(path) else _load_ogg(path)
	if stream != null:
		_resource_cache[path] = stream
	return stream


## Zwalnia wczytane pliki (wywoływane m.in. po każdym pojedynku).
func clear_cache() -> void:
	for task_id: int in _preload_tasks.values():
		WorkerThreadPool.wait_for_task_completion(task_id)
	_preload_tasks.clear()
	_preloaded.clear()
	_resource_cache.clear()


func _scan_category(path: String, category_name: String) -> Dictionary:
	var file_names := Array(DirAccess.get_files_at(path))
	file_names.sort_custom(_natural_less)

	var images: Array[Dictionary] = []
	var tracks: Array[Dictionary] = []
	for file_name: String in file_names:
		var extension := file_name.get_extension().to_lower()
		var answer := file_name.get_basename().strip_edges()
		if answer.is_empty():
			continue
		if extension in IMAGE_EXTENSIONS:
			images.append({ "answer": answer, "path": path.path_join(file_name), "kind": KIND_IMAGE })
		elif extension in AUDIO_EXTENSIONS:
			tracks.append({ "answer": answer, "path": path.path_join(file_name), "kind": KIND_MUSIC })

	# Jakikolwiek plik .ogg = kategoria muzyczna; obrazek (maks. jeden) to wtedy tylko tło.
	if not tracks.is_empty():
		if images.size() > 1:
			push_warning("[CategoryManager] Kategoria muzyczna \"%s\" ma %d obrazków – tłem będzie %s." % [
				category_name, images.size(), images[0]["path"].get_file(),
			])
		return {
			"name": category_name,
			"path": path,
			"kind": KIND_MUSIC,
			"background": images[0]["path"] if not images.is_empty() else "",
			"questions": tracks,
		}

	if images.is_empty():
		push_warning("[CategoryManager] Kategoria \"%s\" nie zawiera zdjęć ani utworów." % category_name)
	return { "name": category_name, "path": path, "kind": KIND_IMAGE, "background": "", "questions": images }


func _take_preloaded(path: String) -> Variant:
	WorkerThreadPool.wait_for_task_completion(_preload_tasks[path])
	_preload_tasks.erase(path)
	_preload_mutex.lock()
	var result: Variant = _preloaded.get(path)
	_preloaded.erase(path)
	_preload_mutex.unlock()
	return result


func _load_in_background(path: String) -> void:
	var result: Variant = _load_ogg(path) if path.get_extension().to_lower() in AUDIO_EXTENSIONS \
			else _decode_image(path)
	_preload_mutex.lock()
	_preloaded[path] = result
	_preload_mutex.unlock()


## Bezpieczne do wywołania z wątku roboczego (nie dotyka drzewa sceny ani cache).
func _load_ogg(path: String) -> AudioStream:
	if not FileAccess.file_exists(path):
		push_warning("[CategoryManager] Brak pliku utworu: %s" % path)
		return null
	var stream := AudioStreamOggVorbis.load_from_file(path)
	if stream == null:
		push_warning("[CategoryManager] Nie udało się wczytać utworu: %s" % path)
		return null
	stream.loop = true
	return stream


## Bezpieczne do wywołania z wątku roboczego (nie dotyka drzewa sceny ani cache).
func _decode_image(path: String) -> Image:
	if path.get_extension().to_lower() not in IMAGE_EXTENSIONS:
		push_warning("[CategoryManager] Nieobsługiwany format obrazka: %s" % path)
		return null
	if not FileAccess.file_exists(path):
		push_warning("[CategoryManager] Brak pliku obrazka: %s" % path)
		return null

	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		push_warning("[CategoryManager] Nie udało się zdekodować obrazka: %s" % path)
		return null

	var factor := minf(float(MAX_IMAGE_SIZE.x) / image.get_width(), float(MAX_IMAGE_SIZE.y) / image.get_height())
	if factor < 1.0:
		image.resize(maxi(1, roundi(image.get_width() * factor)),
				maxi(1, roundi(image.get_height() * factor)), Image.INTERPOLATE_CUBIC)

	# Mipmapy = gładkie skalowanie (np. mały podgląd w konsoli admina).
	image.generate_mipmaps()
	return image


func _natural_less(a: String, b: String) -> bool:
	return a.naturalnocasecmp_to(b) < 0


func _fail(message: String) -> void:
	push_error("[CategoryManager] " + message)
	load_failed.emit(message)
	categories_loaded.emit(0)
