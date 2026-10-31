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
## Folder [code]kategorie final/[/code] ma identyczną strukturę, ale jego kategorie grane są
## WYŁĄCZNIE w decydującej rundzie finału (przy remisie 1:1). Nie trafiają do listy kategorii
## graczy. Ich klucz to [code]"final:" + nazwa[/code] (nazwy mogą powtarzać zwykłe kategorie),
## a do wyświetlania służy [method get_display_name].
##
## WARIANTY kategorii: foldery z tagiem w nawiasie kwadratowym, np. "Marvel [Aktorzy]"
## i "Marvel [Postacie]", to osobne kategorie (osobne klucze i pliki), ale na ekranie gry
## obie nazywają się "Marvel" ([method get_display_name]). Admin widzi pełną nazwę z tagiem.
##
## Pliki ładowane są w locie z dysku (bez systemu importu Godota) – można je podmieniać
## obok pliku .exe i przeskanować folder bez restartu gry.
## Plik [code].gdignore[/code] w folderze kategorii blokuje ich import w edytorze.

## Emitowany po (prze)skanowaniu folderu kategorii.
signal categories_loaded(count: int)
## Emitowany, gdy folderu nie da się odczytać lub jest pusty.
signal load_failed(message: String)

const CATEGORIES_DIR := "kategorie"
const FINAL_CATEGORIES_DIR := "kategorie final"
## Prefiks klucza kategorii finałowej (odróżnia ją od zwykłej o tej samej nazwie).
const FINAL_PREFIX := "final:"
const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
const AUDIO_EXTENSIONS: PackedStringArray = ["ogg"]
## Godot 4 odtwarza natywnie tylko Ogg Theora. Inne formaty wideo trzeba skonwertować do .ogv.
const VIDEO_EXTENSIONS: PackedStringArray = ["ogv"]
const UNSUPPORTED_VIDEO_EXTENSIONS: PackedStringArray = ["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv"]
const KIND_IMAGE := "image"
const KIND_MUSIC := "music"
## Pytanie-wideo (w kategorii obrazkowej, także mieszanej ze zdjęciami). Kategoria ma wtedy kind KIND_IMAGE.
const KIND_VIDEO := "video"
## Rozmiar pola zdjęcia na ekranie gry w pikselach (ustawia Main wg okna). Zdjęcia są do niego
## dopasowywane przy wczytaniu: ostre w 4K, a na mniejszym ekranie nie marnują pamięci.
const DEFAULT_IMAGE_TARGET := Vector2i(922, 814)
## Małych zdjęć nie powiększamy bardziej niż tyle razy (dalej i tak nie przybywa szczegółów).
const MAX_IMAGE_UPSCALE := 4.0
## Limit zdjęć w pamięci – w 4K jedno to ok. 16 MB, a pojedynek potrafi ich pokazać dziesiątki.
const MAX_CACHED_TEXTURES := 8

## Wczytane kategorie, posortowane po nazwie. Każdy element:
## [code]{ "name", "path", "kind": KIND_IMAGE|KIND_MUSIC, "background": String, "questions": Array[Dictionary] }[/code],
## a każde pytanie: [code]{ "answer": String, "path": String, "kind": KIND_IMAGE|KIND_MUSIC|KIND_VIDEO }[/code].
## Kategoria obrazkowa może mieszać zdjęcia i wideo (.ogv) – wideo gra w pętli na ekranie pojedynku.
## [code]background[/code] – ścieżka obrazka tła kategorii muzycznej (lub pusta).
var categories: Array[Dictionary] = []
## Kategorie finałowe (te same pola; [code]name[/code] = klucz z [constant FINAL_PREFIX]).
var final_categories: Array[Dictionary] = []

## Cache zasobów: absolutna ścieżka -> Texture2D / AudioStream.
var _resource_cache: Dictionary = {}
## Ścieżki tekstur w cache od najstarszej ([constant MAX_CACHED_TEXTURES]).
var _texture_order: PackedStringArray = []
var image_target_size := DEFAULT_IMAGE_TARGET
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


func get_final_categories_dir() -> String:
	return get_data_dir().path_join(FINAL_CATEGORIES_DIR)


## Skanuje folder kategorii od nowa. Można wywołać w trakcie gry (poza pojedynkiem).
func reload() -> void:
	clear_cache()
	categories.clear()
	final_categories.clear()

	# Kategorie finałowe są opcjonalne – brak folderu to nie błąd.
	var final_root := get_final_categories_dir()
	_ensure_categories_dir(final_root)
	final_categories = _scan_root(final_root, FINAL_PREFIX)
	print("[CategoryManager] Kategorie finałowe: %d (%s)" % [final_categories.size(), final_root])

	var root := get_categories_dir()
	if not DirAccess.dir_exists_absolute(root):
		_ensure_categories_dir(root)
		_fail("Utworzono pusty folder kategorii: %s – dodaj do niego podfoldery ze zdjęciami." % root)
		return

	categories = _scan_root(root, "")
	if categories.is_empty():
		_fail("Folder %s nie zawiera żadnych podfolderów z kategoriami." % root)
		return

	print("[CategoryManager] Wczytano %d kategorii z: %s" % [categories.size(), root])
	categories_loaded.emit(categories.size())


## [param category_name] – nazwa zwykłej kategorii albo klucz finałowej ("final:...").
func get_category(category_name: String) -> Dictionary:
	var pool := final_categories if is_final_category(category_name) else categories
	for category in pool:
		if category["name"] == category_name:
			return category
	return {}


func is_final_category(category_name: String) -> bool:
	return category_name.begins_with(FINAL_PREFIX)


## Nazwa do wyświetlenia NA EKRANIE GRY (kafelki, pojedynek): bez prefiksu kategorii
## finałowej i bez tagu wariantu w nawiasie kwadratowym.
## [br]"Marvel [Aktorzy]" -> "Marvel", "Marvel [Postacie]" -> "Marvel", "Stolice Europy" -> bez zmian.
## Pełna nazwa folderu (z tagiem) zostaje kluczem kategorii i ścieżką do plików.
func get_display_name(category_name: String) -> String:
	var name_without_prefix := get_admin_name(category_name)
	var bracket := name_without_prefix.find("[")
	if bracket <= 0:
		return name_without_prefix # Brak tagu (albo sam tag) – cała nazwa.
	var base_name := name_without_prefix.substr(0, bracket).strip_edges()
	return base_name if not base_name.is_empty() else name_without_prefix


## Nazwa dla admina: pełna, z tagiem wariantu (np. "Marvel [Aktorzy]"), bez prefiksu "final:".
func get_admin_name(category_name: String) -> String:
	return category_name.trim_prefix(FINAL_PREFIX)


## Klucze kategorii finałowych, które mają pytania.
func get_final_category_keys() -> Array[String]:
	var keys: Array[String] = []
	for category in final_categories:
		if not category["questions"].is_empty():
			keys.append(category["name"])
	return keys


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
	var questions := get_questions(category_name)
	if is_music_category(category_name):
		return "%d utw." % questions.size()
	var videos := questions.filter(func(question: Dictionary) -> bool: return question["kind"] == KIND_VIDEO).size()
	if videos == 0:
		return "%d zdj." % questions.size()
	if videos == questions.size():
		return "%d wid." % videos
	return "%d zdj. + %d wid." % [questions.size() - videos, videos]


## Zaczyna wczytywać plik pytania (zdjęcie lub utwór) w wątku roboczym, żeby późniejsze
## [method load_texture] / [method load_audio] było natychmiastowe.
func preload_file(path: String) -> void:
	if path.is_empty() or _resource_cache.has(path) or _preload_tasks.has(path):
		return
	if path.get_extension().to_lower() in VIDEO_EXTENSIONS:
		return # Wideo jest strumieniowane z dysku – nie ma czego wczytywać z wyprzedzeniem.
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
	_texture_order.append(path)
	while _texture_order.size() > MAX_CACHED_TEXTURES:
		_resource_cache.erase(_texture_order[0])
		_texture_order.remove_at(0)
	return texture


## Zwraca utwór .ogg wczytany z dysku (zapętlony – gra, dopóki ktoś nie odgadnie).
## Strumień wideo (.ogv) czytany prosto z dysku – bez importu Godota.
func load_video(path: String) -> VideoStream:
	if path.is_empty() or not FileAccess.file_exists(path):
		push_warning("[CategoryManager] Brak pliku wideo: %s" % path)
		return null
	var stream := VideoStreamTheora.new()
	stream.file = path
	return stream


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
	_texture_order.clear()


## Skanuje podfoldery [param root]; nazwy w formacie "proper" (Dworce Kolejowe),
## poprzedzone [param key_prefix] (dla kategorii finałowych). Ścieżki zostają oryginalne.
func _scan_root(root: String, key_prefix: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(root):
		return result
	var folder_names := Array(DirAccess.get_directories_at(root))
	folder_names.sort_custom(_natural_less)
	for folder_name: String in folder_names:
		if folder_name.begins_with("."):
			continue
		result.append(_scan_category(root.path_join(folder_name), key_prefix + TextUtils.to_proper(folder_name)))
	return result


## Tworzy folder (jeśli go nie ma) razem z .gdignore, żeby edytor nie importował zdjęć.
func _ensure_categories_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)
	var gdignore := path.path_join(".gdignore")
	if OS.has_feature("editor") and not FileAccess.file_exists(gdignore):
		FileAccess.open(gdignore, FileAccess.WRITE)


func _scan_category(path: String, category_name: String) -> Dictionary:
	var file_names := Array(DirAccess.get_files_at(path))
	file_names.sort_custom(_natural_less)

	var images: Array[Dictionary] = []
	var tracks: Array[Dictionary] = []
	var videos: Array[Dictionary] = []
	for file_name: String in file_names:
		var extension := file_name.get_extension().to_lower()
		var answer := file_name.get_basename().strip_edges()
		if answer.is_empty():
			continue
		if extension in IMAGE_EXTENSIONS:
			images.append({ "answer": answer, "path": path.path_join(file_name), "kind": KIND_IMAGE })
		elif extension in AUDIO_EXTENSIONS:
			tracks.append({ "answer": answer, "path": path.path_join(file_name), "kind": KIND_MUSIC })
		elif extension in VIDEO_EXTENSIONS:
			videos.append({ "answer": answer, "path": path.path_join(file_name), "kind": KIND_VIDEO })
		elif extension in UNSUPPORTED_VIDEO_EXTENSIONS:
			push_warning("[CategoryManager] %s: format .%s nie jest obsługiwany – skonwertuj do .ogv (Ogg Theora)." % [
				path.path_join(file_name), extension,
			])

	# Jakikolwiek plik .ogg = kategoria muzyczna; obrazek (maks. jeden) to wtedy tylko tło.
	if not tracks.is_empty():
		if not videos.is_empty():
			push_warning("[CategoryManager] Kategoria muzyczna \"%s\" zawiera wideo – pomijam je (pytaniami są utwory)." % category_name)
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

	# Kategoria obrazkowa: zdjęcia i wideo razem (posortowane po nazwie pliku).
	var questions: Array[Dictionary] = []
	questions.assign(images + videos)
	questions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _natural_less(a["path"].get_file(), b["path"].get_file()))
	if questions.is_empty():
		push_warning("[CategoryManager] Kategoria \"%s\" nie zawiera zdjęć, wideo ani utworów." % category_name)
	return { "name": category_name, "path": path, "kind": KIND_IMAGE, "background": "", "questions": questions }


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

	# Dopasowanie do pola na ekranie. Powiększanie Lanczosem wygląda dużo lepiej niż
	# rozciąganie przez GPU, które przy małych zdjęciach daje widoczne "schodki".
	var target := image_target_size
	var factor := minf(float(target.x) / image.get_width(), float(target.y) / image.get_height())
	factor = minf(factor, MAX_IMAGE_UPSCALE)
	if not is_equal_approx(factor, 1.0):
		image.convert(Image.FORMAT_RGBA8)
		image.resize(maxi(1, roundi(image.get_width() * factor)), maxi(1, roundi(image.get_height() * factor)),
				Image.INTERPOLATE_LANCZOS if factor > 1.0 else Image.INTERPOLATE_CUBIC)

	# Mipmapy = gładkie skalowanie (np. mały podgląd w konsoli admina).
	image.generate_mipmaps()
	return image


func _natural_less(a: String, b: String) -> bool:
	return a.naturalnocasecmp_to(b) < 0


func _fail(message: String) -> void:
	push_error("[CategoryManager] " + message)
	load_failed.emit(message)
	categories_loaded.emit(0)
