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


const WORD_SEPARATORS: PackedStringArray = [" ", "-", "(", "\"", "/"]
