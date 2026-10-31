# CLAUDE.md – The Floor

Lokalna gra imprezowa w **Godot 4.7** (GDScript, renderer GL Compatibility), inspirowana teleturniejem *The Floor*. Dwa okna: **ekran TV** (podłoga, pojedynki, ogłoszenia) i **konsola admina** (osobne okno systemowe, prowadzący steruje całą grą). Cały kod, komentarze, UI i logi są **po polsku** – trzymaj się tego.

## Uruchamianie i testy

- Godot: `~/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe` (wersja konsolowa – widać `print` i błędy).
- Import (po dodaniu/podmianie zasobów w `res://`): `"$G" --headless --path . --import`
- Szybka kontrola, że skrypty się parsują: `"$G" --headless --path . --quit-after 60 2>&1 | grep -E "SCRIPT ERROR|Parse"`
- Testy logiki: tymczasowa scena/skrypt w `_smoketest/` (np. `extends SceneTree` + `-s res://_smoketest/Smoke.gd`, albo scena instancjonująca `Main.tscn`), która woła metody `GameManager` i drukuje stan. **Zawsze usuń `_smoketest/` po teście.**
- Zrzuty ekranu (bez headless): `get_viewport().get_texture().get_image().save_png(...)`; okno admina ma własny viewport (`$Main/AdminWindow.get_texture()`). Wycisz dźwięk w teście: `AudioServer.set_bus_mute(0, true)`.
- W testach **nie zapisuj** ustawień użytkownika (`user://settings.cfg`) i nie zostawiaj tymczasowych folderów w `kategorie/`.
- Ostrzeżenia „ObjectDB instances leaked / resources still in use” przy wyjściu z trybu headless to artefakt grających strumieni audio – nie błąd gry.

## Architektura

Okna **nie znają się nawzajem**. Przepływ jest jednokierunkowy:

```
AdminWindow --(metody)--> GameManager --(sygnały)--> Main / DuelScreen / AdminWindow / StatsManager
```

### Autoloady (kolejność w `project.godot` ma znaczenie)
1. **CategoryManager** – skanuje foldery kategorii, wczytuje zdjęcia/utwory w locie (Image/AudioStreamOggVorbis), cache + preload w `WorkerThreadPool`.
2. **GameManager** – jedyne źródło prawdy: gracze, podłoga, fazy, ruletka, pojedynek (zegary, odliczanie, kara, talia pytań), finał, śledzenie zużytych kategorii. Sam liczy czas w `_process`.
3. **StatsManager** – statystyki sesji (w pamięci), słucha tylko sygnałów GameManagera.
4. **AudioManager** – szyny `Master` (z `AudioEffectLimiter`) ← `Music`, `SFX`, `Questions`; crossfade muzyki (2 odtwarzacze), pula 12 odtwarzaczy SFX, muzyka zwycięstwa.
5. **SettingsManager** – musi być PO GameManager i AudioManager; wczytuje/zapisuje `user://settings.cfg`.
- `TextUtils` (class_name, statyczne) – `to_proper()`.

### Sceny
- `scenes/main/Main.tscn` – ekran TV: siatka kafelków (`GridContainer` w `CenterContainer`), baner, `DuelScreen`, `WinnerScreen`, `Confetti` (tworzone w kodzie), `AdminWindow` (dziecko-okno; `embed_subwindows=false`). Ustawia okna na monitorach (TV na monitorze 1, fullscreen przy >1 monitorze).
- `scenes/tile/Tile.tscn` – pojedyncze pole; rysuje się samo w `_draw`.
- `scenes/duel/DuelScreen.tscn` – ekran pojedynku (przykrywa podłogę, `z_index = 10`).
- `scenes/admin/AdminWindow.tscn` – konsola z 3 zakładkami: **Konfiguracja**, **Rozgrywka / Pojedynek**, **Statystyki**.
- `scenes/effects/WinnerScreen.tscn` (`z_index = 50`), `Confetti.gd` (CPUParticles2D, `z_index = 100`).

### Fazy (`GameManager.Phase`)
`NO_FLOOR → IDLE → ROLLING (ruletka 2 s) → PLAYER_SELECTED → DUEL → … → GAME_OVER`.
Stany pojedynku (`DuelState`): `READY → COUNTDOWN (3-2-1) → RUNNING ⇄ PENALTY`, `PAUSED` (wznawia poprzedni stan), `TIMEOUT`.

## Zasady gry (zaimplementowane)

- **Podłoga**: dowolna liczba graczy (2–100). Kolumny = `ceil(sqrt(n))`; niepełny ostatni rząd wyśrodkowany przez puste komórki (`EMPTY_CELL = -1`, w Main niewidoczne `Control`-wypełniacze). Puste komórki nie są sąsiadami. Brakujący gracze to „Gracz N”.
- **Ruletka**: pula = żywi gracze z sąsiadem; najpierw gracze bez pojedynku (`duels == 0`); wykluczony `last_stepped_down_player` (tylko w najbliższym losowaniu). Losowanie po wygranej = zwycięzca „schodzi z podłogi” (`step_down()`).
- **Pojedynek**: grana kategoria **obrońcy**. Zegar każdego gracza = `duel_time` (domyślnie 45 s, ustawialny 10–300, zapisywany). START → odliczanie 3-2-1 (click) → pierwsze zdjęcie (`start.wav`). Poprawna = zmiana gracza + `correct.wav`. **Pas** = `fahh.wav`, zegar gracza na czerwono, zdjęcie przyciemnione, licznik kary 3→0 (co sekundę −1 s i click) **z widoczną odpowiedzią**, potem nowe zdjęcie. Tykanie (click) co pełną sekundę aktywnego zegara.
- **Pytanie-wideo** (`DuelScreen`: `%VideoBox` = `AspectRatioContainer` z `%VideoRect` = `VideoStreamPlayer`): gra w pętli w miejscu zdjęcia aż do zmiany pytania; proporcje z pierwszej klatki; przyciemniane w karze; pauzowane z pojedynkiem; przy końcu czasu zatrzymane na ostatniej klatce. Brak klatki przez ~1 s (lub „koniec” < 300 ms po starcie) = plik uszkodzony → komunikat zamiast czarnego pola i bez pętli restartów (`is_playing()` przy złym pliku zwraca true – nie polegaj na nim). Konsola admina pokazuje wyciszony podgląd (`%AnswerVideo`).
- **Po pojedynku**: kategoria obrońcy znika z gry; **zwycięzca (ktokolwiek) gra dalej kategorią atakującego**. Przegrany odpada, całe jego terytorium przechodzi na zwycięzcę.
- **Finał** (zostało 2 graczy): rundy do 2 wygranych – runda 1: kategoria obrońcy, runda 2 (dogrywka): kategoria atakującego, runda 3 przy 1:1: kategoria z `kategorie final/` (losowa z puli **niezużytych w sesji** albo wybrana ręcznie przez admina; po wyczerpaniu – zwykła niezagrana w tym finale). Przed rundą 1 na TV przelatuje napis „FINAŁ”.
- **Koniec gry**: fala przejęcia → po `WINNER_REVEAL_DELAY` (1.5 s) pełnoekranowy `WinnerScreen` + konfetti + losowa muzyka zwycięstwa (max 60 s, gaszona też przy nowej podłodze).
- **Kategorie w sesji**: zagrana = kliknięto START w tej kategorii (`played_categories`). Losowanie kategorii dla graczy omija najpierw zagrane, a na jednej podłodze **nazwy wyświetlane muszą być unikalne** (dotyczy też wariantów, patrz niżej; ręczne przypisanie kolidującego wariantu jest blokowane).

## Kategorie (foldery na dysku, nie w systemie importu)

```
kategorie/                     <- zwykłe kategorie (.gdignore!)
  Kuchnia Śląska/Rolada.jpg     <- nazwa pliku bez rozszerzenia = poprawna odpowiedź
  Marvel [Aktorzy]/...          <- WARIANT: na TV "Marvel", w konsoli "Marvel [Aktorzy]"
  Hity Lat 80/                  <- MUZYCZNA: zawiera .ogg (utwór = pytanie)
    tlo.jpg                     <-   max. 1 obrazek = tło na ekranie pojedynku
    Take On Me - a-ha.ogg
  Las/bocian.jpg + lis.ogv      <- MIESZANA: zdjęcia + wideo (.ogv) w jednej kategorii
kategorie final/                <- tylko runda rozstrzygająca finału (.gdignore!)
audio/music/win/*.ogg           <- muzyka zwycięstwa, ładowana w locie (.gdignore!)
```

- Katalog danych: w edytorze `res://` zglobalizowany, w eksporcie **katalog obok .exe** (`CategoryManager.get_data_dir()`). Te foldery trzeba kopiować obok .exe.
- Obrazki: png/jpg/jpeg/webp/bmp/tga, zmniejszane do 1920×1080, z mipmapami. Audio pytań: tylko `.ogg` (zapętlone, osobna szyna `Questions`).
- **Wideo**: tylko `.ogv` (Ogg Theora – jedyny format natywny Godota 4; mp4/mkv/webm/mov/avi dają ostrzeżenie przy skanowaniu). Pytanie ma `kind = KIND_VIDEO`, kategoria pozostaje `KIND_IMAGE` (zdjęcia i wideo mieszają się w jednej talii; opis np. „12 zdj. + 3 wid.”). W kategorii muzycznej wideo jest pomijane. Wczytywanie: `CategoryManager.load_video()` → `VideoStreamTheora` z `file` = ścieżka absolutna (bez importu, bez preloadu). Konwersja: `ffmpeg -i in.mp4 -c:v libtheora -q:v 7 -c:a libvorbis -q:a 5 out.ogv`.
- **Klucze vs nazwy**: klucz kategorii = pełna nazwa folderu w formacie proper (`TextUtils.to_proper`); kategorie finałowe mają klucz `"final:" + nazwa`. Do ekranu gry używaj `CategoryManager.get_display_name()` / `GameManager.get_player_category_display()` / `get_duel_category_name()`; do konsoli i statystyk `get_admin_name()`; do zapytań (pytania, tło, czy muzyczna) zawsze **klucza** (`get_duel_category_key()`).
- Admin: „Skanuj foldery” = `CategoryManager.reload()` (nie w trakcie pojedynku).

## Audio (stałe pliki w `res://audio/`, `preload` w AudioManager)
`click.wav` (odliczanie, tykanie, kara, ruletka), `start.wav` (koniec odliczania), `beep.wav` (wynik ruletki, napis FINAŁ), `correct.wav`, `fahh.wav` (pas), `woosh.wav` (przejęcie), `bg_main.ogg`, `bg_duel.ogg` (zapętlane w kodzie). W kategorii muzycznej muzyka tła milknie na czas pojedynku. Na czas pytania-wideo muzyka jest **wyciszana** (`AudioManager.set_music_ducked()` – efekt `AudioEffectAmplify` na szynie `Music`, niezależny od suwaka i crossfade'u; muzyka gra dalej pod spodem). Dźwięk wideo idzie na szynę `Questions`. Podmiana stałego pliku: ta sama nazwa i format → Godot przeimportuje; inna nazwa → popraw stałą `SFX_*`/`MUSIC_*`.

## Rysowanie podłogi (najtrudniejsza część – czytaj przed zmianami w Tile/Main)

- `Tile._draw_shape()` rysuje pole + „mostki” (pół szczeliny) do sąsiadów tego samego gracza wg 8-bitowej maski (`N,E,S,W,NE,SE,SW,NW`, liczonej w `Main._neighbor_mask_in`). Ćwiartki skrzyżowań tylko w pełnym bloku 2×2. Zaokrąglenia tylko na zewnętrznych narożnikach. Mostki zachodzą `SEAM_OVERLAP` px pod krawędź (inaczej widać kreski od antyaliasingu StyleBoxa).
- Obrys podświetlenia (`HighlightLayer`) tylko po zewnętrznej krawędzi terytorium, pulsowanie z globalnego zegara (synchroniczne). Styl `ROLL` = bez pulsowania (ruletka).
- `Main._displayed_owners` = właściciele **tak, jak są narysowani** (może się różnić od `GameManager.tile_owners` w trakcie animacji).
- **Przejęcie radialne** (`radial_capture.gdshader`): stara podłoga zostaje nietknięta, a na `CaptureLayer` wszystkich pól zwycięzcy + przejmowanych rysowany jest kształt **po scaleniu** (`_draw_shape_with_mask`), odsłaniany kołem z jednym wspólnym `ShaderMaterial` (uniformy `center`, `radius` w współrzędnych świata via `MODEL_MATRIX`). Po fali (`CAPTURE_DURATION` 3 s) właściciele są zatwierdzani, obrys zwycięzcy wraca.
- `z_index` w Tile: tło 0, `CaptureLayer` 1, `Content`/`Flash`/`HighlightLayer` 2. Dlatego `DuelScreen` ma 10, `WinnerScreen` 50, konfetti 100.
- Podpisy (kategoria + gracz) tylko na jednym polu terytorium (najbliżej środka ciężkości), z autowrapem (bez „…”).

## Konsola admina – ważne szczegóły
- Konfiguracja: lista graczy (imiona → `to_proper`, Enter dodaje i zostawia focus – `keep_editing_on_text_submit` + `edit()` deferred), liczba graczy (podąża za listą), kategorie zwykłe i finałowe (zielona/szara kropka = nowa/zagrana; „Odnów zagrane”, „Odnów pulę”), wybór kategorii rundy 3, czas na odpowiedź, głośności, „Zapisz ustawienia”.
- Rozgrywka: losowanie, wybór przeciwnika, w fazie DUEL panel sterowania. Skróty (Button.shortcut): **Enter/Spacja** = START / poprawna, **P** = pas. Przyciski pojedynku mają `focus_mode = 0`.
- Statystyki: ranking (`Tree`) wg tytuły > wygrane pojedynki > % > pola > poprawne; ciekawostki sesji; reset wymaga dwóch kliknięć.

## Konwencje i pułapki

- Komunikacja tylko przez sygnały/metody GameManagera; widoki nie zawierają zasad gry.
- Sceny `.tscn` bywają zapisywane przez edytor, który dopisuje `unique_id=...` do nagłówków węzłów – przy edycji tekstowej dopasowuj nagłówek po prefiksie (bez zamykającego `]`). Węzły używane w kodzie mają `unique_name_in_owner` (`%Nazwa`).
- Edycja plików ze skryptów Pythona na Windows: uruchamiaj z `python -X utf8` (polskie znaki), dłuższe skrypty zapisuj do pliku zamiast heredoca.
- Nie twórz/generuj obrazków do kategorii – zawartość folderów `kategorie*/` należy do użytkownika i nie wolno jej ruszać. Tymczasowe foldery testowe w `kategorie/` usuwaj **z powłoki** po teście (nie tylko w skrypcie GDScript – błąd skryptu przerwie sprzątanie).
- W GDScript `Array[T] + Array[T]` daje nietypowane `Array` – do zmiennej typowanej użyj `.assign()`.
- Na tej maszynie nie ma ffmpeg (do testów wideo potrzebny prawdziwy plik `.ogv` od użytkownika).
- Po każdej zmianie w projekcie aktualizuj ten plik (CLAUDE.md).
- Odmiana i teksty UI po polsku; na TV używaj wielkich, czytelnych czcionek (ekran oglądany z kanapy).
- Nowe stałe czasowe (`ROLL_DURATION`, `CAPTURE_DURATION`, `WINNER_REVEAL_DELAY`, `PASS_PENALTY`, `COUNTDOWN_FROM`, `DuelScreen.FADE_DURATION`) są powiązane sekwencjami animacji – zmieniając jedną, sprawdź zależne opóźnienia w `Main`.
