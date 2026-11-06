class_name TextUtils
## Pomocnicze funkcje tekstowe (statyczne – bez autoloadu).


## Format "proper": pierwsza litera każdego słowa wielka, np. "jan kowalski" -> "Jan Kowalski",
## "dworce kolejowe" -> "Dworce Kolejowe", "anna-maria" -> "Anna-Maria".
## Pozostałe litery zostają bez zmian, więc skróty typu "ACDC" czy "VII" nie są psute.
static func to_proper(text: String) -> String:
	var result := ""
	var capitalize_next := true
	for character in text.strip_edges():
		result += character.to_upper() if capitalize_next else character
		capitalize_next = character in WORD_SEPARATORS
	return result


## Tekst do wyszukiwania: małe litery, bez polskich znaków ("Pociągi" -> "pociagi").
static func to_search_key(text: String) -> String:
	var result := text.to_lower()
	for letter: String in POLISH_LETTERS:
		result = result.replace(letter, POLISH_LETTERS[letter])
	return result


## Największa czcionka (od [param max_size] w dół do [param min_size]), przy której
## [param text] z zawijaniem słów mieści się w prostokącie [param area].
static func fit_font_size(font: Font, text: String, area: Vector2, max_size: int, min_size: int, step := 2) -> int:
	var font_size := max_size
	while font_size > min_size:
		var text_size := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, area.x, font_size,
				-1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND)
		if text_size.x <= area.x and text_size.y <= area.y:
			break
		font_size -= step
	return maxi(font_size, min_size)


const POLISH_LETTERS := { "ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n", "ó": "o", "ś": "s", "ź": "z", "ż": "z" }
## "[" też – tagi wariantów kategorii: "marvel [aktorzy]" -> "Marvel [Aktorzy]".
const WORD_SEPARATORS: PackedStringArray = [" ", "-", "(", "[", "\"", "/"]
