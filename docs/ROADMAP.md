# Nimbus — план работ: баг плеер-пилла, разбор ContentView, фичи

Каркас (M0–M2) готов: логин, HLS-плеер с ре-резолвом и FairPlay, очередь, Now Playing, библиотека, поиск, страницы артиста/трека. Этот документ задаёт порядок работ поверх него. Сначала — наблюдаемый баг и структурная база (их правит и проверяет только автор, поэтому они идут первыми и на минимальном диффе), затем фичи по зависимостям, только на проверенных эндпоинтах. Строки `**Done:**` в PLAN.md и старом ROADMAP — это критерии приёмки этапа, а не заявление о готовности.

## Прогресс (2026-07-11)

Шаги 1–6 сделаны и собраны: ✅ фикс пилла на pushed-страницах, ✅ подъём `AppModel` в `NimbusApp`, ✅ разбор `ContentView` на 21 файл по ролям, ✅ атрибуция + copyright, ✅ автопропуск битых треков + баннер ошибок, ✅ лайки треков (работают до аккаунта). Следующий — шаг 7 (репосты).

**Ключевая находка: записи в api-v2 закрыты антиботом DataDome, чтения — нет.** Захват реального веб-запроса показал, что write-эндпоинты требуют куку `datadome`; без неё — 403. Решено синком куки WKWebView в `HTTPCookieStorage.shared` (см. `LoginWebView.harvest`), `mutate` шлёт `Authorization` + `client_id`. Проверено вживую на лайке. **Это разблокировало весь write-слой** — репост/фоллоу/add-to-playlist/play-history едут на том же пути. Оговорка: синк куки идёт только при логине, уже залогиненному нужен разовый sign-out/in (учесть в «тихом ре-логине»).

---

## 1. Баг: плеер-пилл пропадает на pushed-страницах

### Корневая причина (насколько её подтверждают данные)

Пилл рисуется модификатором `.safeAreaInset(edge: .bottom)`, навешенным на `NavigationStack` **снаружи** (`Nimbus/App/ContentView.swift:96-101`); сам стек и его четыре `navigationDestination` — внутри (`ContentView.swift:81-95`). `.safeAreaInset` делает две вещи: рисует пилл в нижней полосе и урезает safe-area, которая втекает в модифицируемую вьюху. Корневой контент стека (`DetailContent`) получает урезанную safe-area и ложится над пиллом — поэтому на Home/Likes/History пилл виден. Но каждый pushed-destination (`ArtistView`, `TrackDetailView`, `PlaylistTracksView`, `GenreChartView` — все это `ScrollView`/`TrackTable` + `.navigationTitle`, без своего `.ignoresSafeArea`) презентуется в отдельном контейнере, который заполняет колонку detail и композитится поверх inset-полосы. Пилл не уничтожается — он перекрывается, а зарезервированное под него место отбирается pushed-страницей, поэтому читается как «пропал».

Историю подтверждает git: до коммита `648512e` колонка detail была простым `Group` с тем же `.safeAreaInset` и **без** `NavigationStack` — пушить было некуда, пилл был всегда. Коммит `648512e` обернул контент в `NavigationStack(path:)`, но оставил inset снаружи — так и появился баг. Первоисточник: Apple Developer Forums thread 735672 — точь-в-точь тот же сетап (`NavigationStack` в detail-колонке `NavigationSplitView` + `safeAreaInset` для плавающего бара) и тот же симптом («floating bar obscured by the pushed view»), плюс подтверждение, что перенос inset на сам `NavigationSplitView` растягивает бар и на сайдбар.

**Честно про разногласия трёх диагнозов.** Все три сходятся в том, **куда** двигать (перестать держать пилл на `.safeAreaInset` стека; сделать его sibling-слоем поверх стека внутри `detail:`) и в том, что у голого `.overlay` есть регрессия (он не резервирует место). Расходятся в **почему** и в уверенности:

- Утверждение «баг специфичен для macOS, на iOS та же конструкция бар сохраняет» — **неверно**: собственный первоисточник 735672 наблюдал симптом на iOS/iPad. Механизм, скорее всего, кросс-платформенный.
- Ни один источник не доказывает, что ZStack-sibling z-order отличается от `safeAreaInset`-на-той-же-вьюхе (оба кладут пилл вне стека). Фикс работает потому, что `.overlay`/ZStack — канонический способ прибить постоянный chrome поверх `NavigationStack`, а не потому, что доказан конкретный сбой распространения safe-area.

Итог: **высокая** уверенность, что фикс сделает пилл видимым на всех pushed-страницах; **низкая** — в точной причинной механике. Запустить может только автор, поэтому ниже — процедура решения, а не ложная определённость.

### Точное исправление

В `ContentView.swift:96-101` заменить рисующий модификатор с `.safeAreaInset(edge: .bottom)` на `.overlay(alignment: .bottom)`, оставив его на `NavigationStack` **внутри** `detail:` (пилл остаётся в колонке detail и не лезет под сайдбар). Поскольку `.overlay` не резервирует место — **добавить** отдельный резерв снизу, чтобы последний ряд списка не прятался под ~капсулой:

```swift
} detail: {
    NavigationStack(path: $path) {
        DetailContent(model: model, section: $section, searchText: searchText)
            .navigationDestination(for: SCUser.self)     { user in ArtistView(user: user, model: model) }
            .navigationDestination(for: SCTrack.self)    { track in TrackDetailView(track: track, model: model) }
            .navigationDestination(for: SCPlaylist.self) { playlist in PlaylistTracksView(playlist: playlist, library: model.library, player: model.player) }
            .navigationDestination(for: SCGenre.self)    { genre in GenreChartView(genre: genre, model: model) }
    }
    .overlay(alignment: .bottom) {
        PlayerPill(
            player: model.player,
            onOpenTrack: { path.append($0) },
            onOpenArtist: { path.append($0) })
    }
    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: pillHeight) }
}
```

`pillHeight` подобрать под реальную высоту пилла (у `PlayerPill` `.padding(.bottom, 14)` на `ContentView.swift:180` плюс сам `PlayerPillContent` — ориентир ~64–76pt). Эквивалентная форма рисующего слоя: `ZStack(alignment: .bottom) { NavigationStack(path: $path) { … }; PlayerPill(...) }`.

Владение `@State private var section` / `@State private var path` **оставить** на `LibraryShell` (`ContentView.swift:55,58`; комментарий на `:57` уже фиксирует, что пилл живёт вне стека и пушит в этот `path`). Не переносить это владение при разборе файла (шаг 3).

### Как автор это проверяет (запустить может только он)

1. Заиграть трек — на Home пилл виден.
2. Из сайдбара уйти в `ArtistView`, `TrackDetailView`, `PlaylistTracksView` и genre-chart (все четыре — push). Пилл должен остаться видимым на всех четырёх.
3. Проскроллить каждый список до последнего ряда — он должен уходить над пиллом, а не прятаться под ним.
4. Корневые страницы (Home/Likes/History) — без изменений.

### Запасной вариант и процедура решения

- **Пилл всё равно исчезает на push** → взять явную форму `ZStack(alignment: .bottom) { NavigationStack{…}; PlayerPill }`. Если и это не держит — крайний вариант из эталона `nuage-macos`: док пилла на всю ширину как sibling **снаружи** `NavigationSplitView` (`VStack(spacing: 0) { NavigationSplitView{…}; PlayerPill }`). Это полностью обходит навигационный композитинг и резервирует место, ценой того, что бар растянется на всю ширину окна (включая сайдбар), а не будет плавать только над detail.
- **Пилл виден, но последний ряд прячется под ним на pushed-странице** → значит clear-color `.safeAreaInset`-резерв не дошёл до этого destination (это ровно тот же вопрос распространения safe-area, что и сам баг). **Не** раскидывать паддинг по всем страницам заранее (если резерв на стеке *доходит* до pushed-страниц, получится двойной резерв). Добавить резерв только в конкретную страницу: `.contentMargins(.bottom, pillHeight, for: .scrollContent)` либо `.safeAreaInset(edge: .bottom){ Color.clear.frame(height: pillHeight) }` внутри её `ScrollView`.
- Открытый пункт, который решается только запуском: доходит ли clear-резерв на `NavigationStack` до pushed-страниц. Относиться к нему как к гипотезе, проверяемой постранично, а не как к гарантии.

---

## 2. Рефакторинг: разбить ContentView + поднять AppModel

Разбить `ContentView.swift` (1713 строк) и `LibraryViews.swift` на пофайловое дерево и поднять `AppModel` из `@State` в `ContentView` на уровень `NimbusApp`. Ничего сверх этого: без Router/Coordinator, без TCA, без view-model-на-вью. Разбор — чистое перемещение символов, ноль изменений поведения.

### Целевое дерево файлов

Все текущие top-level типы учтены. Page-local энумы кладём рядом со своей страницей (локальность), кросс-cutting UI-модель (`SCGenre`) — в `Models`.

| Файл | Символы (откуда) |
|---|---|
| `Nimbus/App/NimbusApp.swift` | `NimbusApp` (правка: получает `@State private var model = AppModel()`) |
| `Nimbus/App/Shell.swift` | `ContentView` (теперь `let model: AppModel`), `LibrarySection` (:23), `LibraryShell` (:53), `DetailContent` (:111), `AccountRow` (:680), `#Preview` (:1711 → `ContentView(model: AppModel())`) |
| `Nimbus/Player/PlayerPill.swift` | `PlayerPill` (:150), `PlayerPillContent` (:185), `ProgressScrubber` (:387), `VolumeButton` (:413) |
| `Nimbus/Player/QueuePanel.swift` | `QueueButton` (:297), `QueueView` (:310), `QueueItemView` (:336) |
| `Nimbus/Pages/HomeView.swift` | `HomeView` (:11), `ShelfData` (:86), `ShelfStyle` (:353), `FeaturedMix` (:176), `RecentGrid` (:278), `RecentPill` (:296), `SelectionShelf` (:357), `PlayFAB` (:380, private), `SquareSetCard` (:402), `WideSetCard` (:457), `ArtistShelf` (:524), `ChartSection` (:569), `GenreChipsRow` (:611), `ChartRow` (:637) |
| `Nimbus/Pages/FeedView.swift` | `FeedView` (`LibraryViews.swift:5`) |
| `Nimbus/Pages/PlaylistCollection.swift` | `PlaylistCollection` (`LibraryViews.swift:46`) |
| `Nimbus/Pages/FollowingView.swift` | `FollowingView` (`LibraryViews.swift:87`) |
| `Nimbus/Pages/SearchResultsView.swift` | `SearchResultsView` (:494), `SearchScope` (:473), `SearchSort` (:482) |
| `Nimbus/Pages/ProfileView.swift` | `ProfileView` (:902), `ProfileHeader` (:953) |
| `Nimbus/Pages/ArtistView.swift` | `ArtistView` (:1167), `ArtistHeader` (:1312), `ArtistTab` (:1157) |
| `Nimbus/Pages/TrackDetailView.swift` | `TrackDetailView` (:1356), `GenreBadge` (:1561) |
| `Nimbus/Pages/PlaylistTracksView.swift` | `PlaylistTracksView` (:1051), `PlaylistHeader` (:1083) |
| `Nimbus/Pages/GenreBrowseView.swift` | `GenreGridView` (:1618), `GenreTile` (:1637), `GenreChartView` (:1661) |
| `Nimbus/Components/Artwork.swift` | `Artwork` (`HomeView.swift:161`) |
| `Nimbus/Components/Shelf.swift` | `Shelf` (`HomeView.swift:127`), `SectionHeader` (`HomeView.swift:99`), `HomeCarousel` (:758), `gutter` (`HomeView.swift:95`, private→internal, объявить ЗДЕСЬ ровно один раз) |
| `Nimbus/Components/Rows.swift` | `TrackRow` (:1458), `UserRow` (:998), `PlaylistRow` (:1028), `StreamItemView` (:725) |
| `Nimbus/Components/Cards.swift` | `TrackCard` (:786), `PlaylistCard` (:842), `ArtistCircle` (`HomeView.swift:537`) |
| `Nimbus/Components/TrackTable.swift` | `TrackTable` (:430), `TrackList` (:455) |
| `Nimbus/Components/TrackContextMenu.swift` | `trackContextMenu(_:player:)` extension View (`HomeView.swift:144`) |
| `Nimbus/Models/SCGenre.swift` | `SCGenre` (:1577) |
| `Nimbus/Support/Formatters.swift` | `countString` (:1690), `timeString` (:1699), `longDurationString(ms:)` (:1705) |

Без изменений и на месте: `AppModel.swift`, `Theme.swift` (`Color.scOrange`, `Optional<String>.scArtwork(_:)`), `DesignPreview.swift`, `Library/Waveform.swift` (`WaveformView`/`WaveformLoader`/`Waveform`), `Playback/PlayerEngine.swift` (включая `RepeatMode`), `API/SoundCloudModels.swift` (все `SC*`-декодабл).

### Поднятие AppModel в NimbusApp

Способ — **явная передача** (Option A), не `.environment`. Это минимальный дифф, совпадает со стилем (каждая вью уже получает `model`/`player`/`library` как `let`) и это единственное, что удовлетворяет требование: `.commands` и будущий `MenuBarExtra` дотягиваются до `model.player`.

- Удалить `@State private var model = AppModel()` (`ContentView.swift:6`). `ContentView` становится `struct ContentView: View { let model: AppModel; var body … }` (body не трогать).
- `NimbusApp` (`NimbusApp.swift:11`) получает `@State private var model = AppModel()` и рендерит `WindowGroup { ContentView(model: model) }` (сейчас `ContentView()` на `NimbusApp.swift:14`).
- `#Preview` (`ContentView.swift:1711`) → `ContentView(model: AppModel())`.

Ломается ровно два call-site: тело `NimbusApp` и `#Preview`. Всё вниз по дереву не трогается — дети уже принимают `model` явно.

Почему не `.environment(model)` + `@Environment(AppModel.self)`: (а) `.commands` навешивается на Scene, а не внутрь окружения контента `WindowGroup`, поэтому `CommandMenu` не прочитает `@Environment`, поставленное на `ContentView` — пришлось бы всё равно передавать `model.player` руками или публиковать через `.focusedSceneValue`; (б) это заставило бы переписать ~20 вью с `let` на `@Environment` ради нулевой новой возможности здесь. `@Environment(AppModel.self)` к тому же **необязательный** и трапнет, если хоть одна Scene/`#Preview` забудет инъекцию. Оставляем как опциональный сахар на будущее.

Swift 6 / MainActor — без церемоний: `defaultIsolation = MainActor` (`project.pbxproj:298,331`), `NimbusApp: App` сам MainActor-изолирован, `@State`-дефолт вычисляется лениво на главном акторе — ровно как сегодня в `ContentView`; мы лишь поднимаем свойство на уровень выше. Изоляция-нейтрально.

### Опасности

1. **Пофайловые импорты фреймворков** (самое лёгкое пропустить): `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` (`project.pbxproj:300,333`) — член виден, только если файл импортирует модуль, который его **объявляет** (транзитивные импорты не считаются). Каждый новый файл переобъявляет ровно нужные фреймворки: **NukeUI** везде, где встречается `LazyImage` (`PlayerPill`, `QueuePanel`, `Shell`, `Rows`, `Cards`, `Artwork`, `ProfileView`, `ArtistView`, `TrackDetailView`, `PlaylistTracksView`); **AVFoundation** в `Player/PlayerPill.swift` (биндинг тома читает/пишет `player.player.volume` — `AVPlayer.volume` объявлен в AVFoundation, `ContentView.swift:166-167`); **AppKit** в `Components/TrackContextMenu.swift` (`NSPasteboard`). Внутримодульные переезды типов импорта **не** требуют.
2. **`gutter`** (`HomeView.swift:95`) — `private let` файлового уровня, на него ссылаются `SectionHeader`, `Shelf`, `FeaturedMix`, `RecentGrid`, `SelectionShelf`, `ArtistShelf`, `ChartSection`, `GenreChipsRow`. Как только `Shelf`/`SectionHeader` уедут в `Components/Shelf.swift`, а секции Home останутся в `Pages/HomeView.swift`, `private` перестанет доставать межфайлово. Поднять до internal (`let gutter: CGFloat = 24`) и объявить **ровно один раз** в `Components/Shelf.swift` (дубль — ошибка переобъявления).
3. **`PlayFAB`** (`HomeView.swift:380`, `private struct`) используют только `SquareSetCard` и `WideSetCard`. Держать все три в `Pages/HomeView.swift` — тогда `PlayFAB` остаётся private, поднимать не нужно. Это единственный, помимо `gutter`, file-private символ, чувствительный к разбору — специально проверить оба.
4. **`player.player.volume`** (`ContentView.swift:166-167`): `PlayerEngine.player` — `let player = AVPlayer()` (`PlayerEngine.swift:32`, internal), так что кросс-файловый доступ компилируется, но это протекающая абстракция (пилл мутирует `AVPlayer` в обход движка) и она тянет AVFoundation в `PlayerPill.swift`. К тому же `AVPlayer.volume` не трекается `@Observable`, слайдер write-through/read-once, не реактивный. Разбор сохраняет этот дефект как есть; чинится в шаге 12 (вынести `var volume: Float` на `PlayerEngine`).
5. **Связка `Binding<LibrarySection?>`**: `DetailContent`, `AccountRow`, `ProfileView` берут `@Binding var section`; onOpen-замыкания пилла пушат в `@State path` у `LibraryShell`; `path` сбрасывается в `LibraryShell.onChange(of: section)` (`ContentView.swift:105`). Разносить это по файлам безопасно **только** если source-of-truth `@State section`/`@State path` остаётся во владении `LibraryShell` (`Shell.swift`). Не переносить владение — это же машинерия, на которой держится фикс пилла из шага 1.
6. **Коллизии имён**: на top-level их нет. Повторяющиеся приватные хелперы (`play()`, `start(_:shuffled:)`, `stat(_:_:)`, `card(_:)`) безопасны как инстанс-члены разных структур — они столкнутся, только если кто-то поднимет один в свободную функцию при переезде; держать членами.
7. **Ретейн-циклы**: не вносятся. **Единственный реальный баг, которого нельзя допустить**: после поднятия `@State var model` из `ContentView` должен быть удалён **полностью**. Если оставить — родится ВТОРОЙ `AppModel` (дубликат `PlayerEngine`/`LibraryStore`), это баг корректности, не утечка.

### project.pbxproj — правки НЕ нужны

`objectVersion = 77` (`project.pbxproj:6`), для всей папки `Nimbus/` объявлена `PBXFileSystemSynchronizedRootGroup` (`:20-26`), включённая в `fileSystemSynchronizedGroups` таргета (`:82`). Следствие: новые `.swift`-файлы **и** новые подпапки (`Nimbus/Player`, `Nimbus/Pages`, `Nimbus/Components`, `Nimbus/Models`, `Nimbus/Support`) авто-регистрируются в compile sources таргета без правки pbxproj. Удаление/перемещение файлов — тоже без правки. Разбор — чисто файловая операция.

`DesignPreview.swift` разбор не трогает: он не ссылается ни на `AppModel`, ни на `ContentView` (строит `PlayerEngine(api: SoundCloudAPI())` напрямую и рендерит `TrackTable`, `PlayerPillContent`, `SCTrack`, `.scOrange`). Условие — `TrackTable` (→ `Components/TrackTable.swift`) и `PlayerPillContent` (→ `Player/PlayerPill.swift`) остаются internal/same-module (они и остаются). `#Preview("Library")` продолжает работать.

---

## 3. Порядок работ

Спина — «сначала снять неопределённость на минимальном диффе, потом фичи по зависимостям, только на проверенных эндпоинтах». Шаги 1–3 подробно описаны в разделах 1–2, здесь — их место в порядке и критерий приёмки.

### ✅ 1. [S] `fix: keep the player pill visible on pushed detail pages`

**Что:** фикс пилла из раздела 1 (`.overlay(alignment: .bottom)` + резерв `.safeAreaInset { Color.clear.frame(height: pillHeight) }`).
**Почему здесь:** наблюдаемый баг и ~2–3 строки ровно в тех местах, которые разбор вот-вот перенесёт; чинить сейчас — разбор понесёт уже исправленную версию, автор получит немедленный визуальный выигрыш, а safe-area-механика де-рискуется, пока файл маленький.
**Трогает:** `ContentView.swift:96-101` (`LibraryShell` detail-closure); `PlayerPill` без изменений (:150).
**Проверка:** раздел 1 → «Как автор проверяет».

### ✅ 2. [S] `refactor: hoist AppModel into NimbusApp`

**Что:** поднятие `AppModel` из раздела 2.
**Почему здесь:** снимает вопрос изоляции Swift 6 на крошечном диффе и открывает Scene-уровень, который нужен шагу 12 (`.commands`) и будущему `MenuBarExtra` — те дотянутся до `model.player`, только когда моделью владеет Scene. Сделать до разбора, чтобы разбор просто переносил уже поднятую форму.
**Трогает:** `NimbusApp.swift:11-16`; `ContentView.swift:5-6`, `:1711`.
**Проверка:** приложение всё так же логинится и играет; один плеер — старт трека из двух мест управляет одним пиллом (доказательство, что движок один, а не два); живой `#Preview` строится.

### ✅ 3. [L] `refactor: split ContentView into per-page and component files`

**Что:** перераспределить `ContentView.swift`/`LibraryViews.swift`/`HomeView.swift` по дереву из раздела 2. Чистый перенос, ноль изменений поведения. При разборе перечислить **все** file-private символы к продвижению: `gutter` (`HomeView.swift:95` → internal, один раз в `Components/Shelf.swift`) и `PlayFAB` (`HomeView.swift:380` — остаётся private вместе с `SquareSetCard`/`WideSetCard` в `Pages/HomeView.swift`).
**Почему здесь:** большая, но малонеопределённая механика; до фич — чтобы шаги 4–13 правили маленькие целевые файлы, а не god-компонент. Автор решил, что полный разбор в scope.
**Трогает:** всё дерево; `ContentView.swift` и `LibraryViews.swift` опустошаются/удаляются; `HomeView.swift` переезжает в `Pages/` минус вынесенные generics. project.pbxproj не трогается.
**Проверка:** каждая секция сайдбара и каждая pushed-страница рендерятся как раньше, поиск работает, `#Preview("Library")` в `DesignPreview.swift` строится. Повторить проверку пилла из шага 1 (разбор не должен сломать навигацию). Любая разница в поведении = символ переехал неверно.

### ✅ 4. [S] `chore: add SoundCloud attribution and copyright`

**Что:** заполнить пустой `INFOPLIST_KEY_NSHumanReadableCopyright` (`project.pbxproj:286,319`) и вывести видимую атрибуцию «Powered by SoundCloud» (в `AccountRow` — `Shell.swift`, бывш. `ContentView.swift:680`, или отдельным About).
**Почему здесь:** compliance-гейт **до** первой фичи, пишущей в реальный аккаунт (лайки/репосты/фоллоу). PLAN.md:42 и CLAUDE.md называют атрибуцию ключевой мерой соблюдения ToS для personal-use, а в коде её нет (grep = 0). Если автор остановит план на полпути (норма для соло-проекта), атрибуция и непустой copyright уже отгружены до того, как клиент начал писать.
**Трогает:** `project.pbxproj:286,319`; `Shell.swift` `AccountRow`.
**Проверка:** атрибуция видна в работающем UI; поле copyright в стандартной панели About/Get-Info непустое.

### ✅ 5. [M] `fix: auto-skip unplayable tracks and surface playback errors`

**Что:** четыре тупиковые ветки ошибок в `PlayerEngine` сейчас пишут в `status` и возвращаются без `next()`, поэтому очередь встаёт на первом гео/Go+-блокнутом треке: нет источника (`:220`), нет FairPlay-токена (`:228`), catch резолва (`:232-233`), catch прямого проигрывания (`:280-281`). Перевести их на автопропуск через `next()`. В `start()` (`:285`) добавить KVO на `currentItem.status == .failed` и наблюдатель `AVPlayerItem.failedToPlayToEndTimeNotification`, чтобы срыв в середине тоже двигал очередь.

> **Критично — НЕ маршрутизировать `AVPlayerItem.playbackStalledNotification` в автопропуск.** Stall — это нормальный, восстановимый underrun буфера, и здесь он ожидаем: HLS-ссылки подписаны ~на 5 минут и ре-резолвятся в процессе игры resource-loader’ом (`PlayerEngine.swift` ~`:239-262`, сессия ключа на `:250`), так что срыв на треке >5 мин — часто именно кейс ре-резолва. Stall в худшем случае гонит транзиентный баннер «reconnecting…», но **никогда** не двигает очередь. Автопропуск — только по `status == .failed` и `failedToPlayToEndTimeNotification`.

Ограничить автопропуск счётчиком подряд-неудач, чтобы полностью блокнутая очередь **останавливалась**, а не крутилась вечно (не заворачиваться за ветку `repeatMode == .all` на `:115`). Новый наблюдатель не должен дважды срабатывать с `didPlayToEndTimeNotification` на `:290`. Вывести ошибку наружу: `status` сегодня write-only (ни одна вью его не читает) — добавить `lastError`, который покажет пилл/баннер.
**Почему здесь:** очередь-тупик на первом блокнутом треке — «мешает ежедневно»; к тому же это закаляет ровно тот путь конца-очереди/`next()`, на который обопрётся autoplay (шаг 11), поэтому идёт до него.
**Трогает:** `PlayerEngine.swift`: `playCurrent` (`:204-220`), `playFairPlay` (`:224-233`), `playDirect` (`:273-281`), `start` (`:285-293`), `playbackFinished` (`:300-307`); маленькая поверхность ошибки в `Shell`/пилле.
**Проверка:** в очереди перед играбельным лежит заведомо блокнутый трек → плеер перескакивает на играбельный, а не встаёт; обрыв сети посреди трека → плеер продвигается или показывает ошибку, но **не** самопропускается на короткой сетевой икоте и не на ре-резолве URL у трека длиннее 5 минут.

### ✅ 6. [M] `feat: like tracks and playlists` — эндпоинты VERIFIED

**Что:** добавить первый не-GET-путь в `SoundCloudAPI` — хелпер рядом с `getDecoded` (`:211-241`), зеркалящий сборку URL, `client_id`, заголовок `Authorization: OAuth`, ретрай по 401/403 (`:238-241`), но с `req.httpMethod`, пустым телом и трактовкой любого 2xx как успеха (сейчас актор на 100% GET). Провод VERIFIED-эндпоинтов (сверено с пакетом SoundCloud из Nuage): `PUT/DELETE /users/{userID}/track_likes/{trackID}` и `/users/{userID}/playlist_likes/{playlistID}`, переиспользуя `api.me().id` (как `likedTracks` на `LibraryStore.swift:68`). В `LibraryStore` добавить `likedTrackIDs`/`likedPlaylistIDs: Set<Int>`, засеянные из ленты лайков, с оптимистичным тоглом, откатывающимся на не-2xx. Отрисовать сердечко в `PlayerPillContent` и заменить **статичную** глиф-статистику на странице трека (`ContentView.swift:1432` → `Pages/TrackDetailView.swift`) и в `TrackRow` (`Components/Rows.swift`).

> **Ограничение засева (баг корректности, известный заранее):** лента лайков страницами по `limit: 24` (`SoundCloudAPI.swift:82`), а у `SCTrack` нет пофлагового «liked» (`SoundCloudModels.swift:78-109`). Поэтому `likedTrackIDs` знает только уже загруженные из ленты лайков треки — лайкнутый, но не попавший в загруженные страницы, отрисуется как не-лайкнутый. Не подавать состояние как глобально авторитетное: сделать сердечко точным для загруженных треков и до-сверять по мере подгрузки страниц.

**Почему здесь:** keystone. Единственная недостающая проводка, на которой заблокированы лайки/репосты/фоллоу/история; строим первый не-GET на VERIFIED-эндпоинте — если актор преподнесёт сюрприз, это случится здесь, а не четырьмя шагами глубже. Лайки — фича, которую автор обозначил следующей.
**Трогает:** `SoundCloudAPI.swift` (хелпер + like-вызовы); `LibraryStore.swift` (liked-сеты, тогл); `Player/PlayerPill.swift`; `Pages/TrackDetailView.swift`; `Components/Rows.swift`.
**Проверка:** лайкнуть трек из пилла И со страницы трека (состояние совпадает для одного трека); перезагрузить soundcloud.com в браузере → лайк появился; снять → исчез; принудительная ошибка запроса откатывает сердечко.

### 7. [S] `feat: repost tracks and playlists` — эндпоинты VERIFIED

**Что:** переиспользовать проводку из шага 6. Добавить `repostedTrackIDs`/`repostedPlaylistIDs` и VERIFIED `PUT/DELETE /me/track_reposts/{trackID}`, `/me/playlist_reposts/{playlistID}`, пустое тело, тот же оптимистичный откат.
**Почему здесь:** тот же паттерн проводки и состояния, что лайки; контекстному меню (шаг 8) нужны живыми и Like, и Repost.
**Трогает:** `SoundCloudAPI.swift`; `LibraryStore.swift`; row/detail UI.
**Проверка:** репостнуть трек в Nimbus → появился в веб-клиенте/на профиле; снять репост → убрался.

### 8. [M] `feat: track context menus with share and open in soundcloud`

**Что:** в приложении уже есть **одно** переиспользуемое `trackContextMenu(_:player:)` (`HomeView.swift:144`, с Copy Link через `permalinkURL` на `:155`) → перенести в `Components/TrackContextMenu.swift` и обогатить: Like/Unlike · Repost/Unrepost · Play Next · Add to Queue · Go to Artist · Copy Link · Open in SoundCloud · Share. Применить ко **всем** трек-поверхностям, включая `QueueItemView` (`ContentView.swift:336`, у которой меню сейчас нет): `TrackRow`, `RecentPill`, `ChartRow`, `QueueItemView`, `TrackCard`. Copy Link / Open in SoundCloud / Share — по неопциональному `permalinkURL` каждого трека через `NSPasteboard` (AppKit уже импортируется здесь) + `openURL` / `ShareLink`. `playNext(_:)`/`playLater(_:)` уже есть на `PlayerEngine`.
**Почему здесь:** зависит от того, что лайки (6) и репосты (7) уже работают, иначе пункты меню мертвы; даёт правый клик везде; Open in SoundCloud усиливает атрибуционную позицию из шага 4.
**Трогает:** `Components/TrackContextMenu.swift` (import SwiftUI + AppKit); `Components/Rows.swift`, `Components/Cards.swift`, `Player/QueuePanel.swift`, `Pages/HomeView.swift`.
**Проверка:** правый клик по треку в Home, Search, на странице артиста и в очереди → одинаковое меню; Copy Link кладёт permalink в буфер; Share открывает macOS share-sheet; Open in SoundCloud открывает браузер; Play Next / Add to Queue переставляют очередь.

### 9. [S] `docs: record the verified api-v2 follow request` — ГЕЙТ ЗАХВАТА (эндпоинт UNVERIFIED)

**Что:** до единой строки follow-кода снять реальный запрос follow/unfollow, который шлёт веб-клиент SoundCloud (метод, точный путь, тело, заголовки — **особенно** нужен ли cookie-auth вдобавок к заголовку OAuth), через прокси на живой сессии, и записать в docs. Догадка старого роадмапа — `POST/DELETE /me/followings/{userID}` — но `SoundCloudAPI.swift:150` уже документирует, что `/me/followings` — мёртвый путь (те, кого вы фоллоуите, живут под `/users/{id}/followings`), поэтому **write-путь UNVERIFIED**, а догадка подозрительна.
**Почему здесь:** жёсткое правило — никакого кода на непроверенном эндпоинте без предшествующего захвата. Лайки/репосты были сверены с Nuage; фоллоу — нет.
**Трогает:** `docs/ROADMAP.md` или заметка `docs/api-captures`.
**Проверка:** записанный запрос совпадает с реальным захватом — метод/путь/тело зафиксированы, а не предположены.

### 10. [S] `feat: follow and unfollow artists` — зависит от шага 9

**Что:** реализовать follow/unfollow в `SoundCloudAPI` **ровно** тем запросом, что подтверждён в шаге 9; добавить `followedUserIDs: Set<Int>` в `LibraryStore`, засеянный из `userFollowings` (`SoundCloudAPI.swift:151`, `limit: 100` — та же оговорка постраничности, что у лайков); кнопка Follow на `Pages/ArtistView.swift` с оптимистичным тоглом.
**Почему здесь:** только теперь, на проверенном эндпоинте. Завершает трио Like/Repost/Follow на странице артиста.
**Трогает:** `SoundCloudAPI.swift`; `LibraryStore.swift`; `Pages/ArtistView.swift`.
**Проверка:** зафоллоуить артиста в Nimbus → фоллоу виден в веб-клиенте; список Following отражает после перезагрузки; unfollow откатывает. Если захват показал, что нужен cookie-auth — убедиться, что запрос не тихо 401-ит.

### 11. [M] `feat: autoplay related tracks at end of queue` — VERIFIED (уже реализован)

**Что:** вызвать уже реализованный, но мёртвый `relatedTracks(id:)` (`SoundCloudAPI.swift:104`) в `playbackFinished` (`:300`), когда очередь **действительно** дошла до конца (`canGoNext == false` на `:303`, repeat off) — **не** когда шаг 5 автопропустил блокнутый трек — до-загрузить related от последнего трека, дедуп против живой очереди, продолжить. Переключатель Autoplay (persist через `@AppStorage`) в пилле.
**Почему здесь:** после соц-слоя (низкий downstream-риск, эндпоинт уже есть) и после закалённого шагом 5 пути конца-очереди; autoplay обязан срабатывать на реальном исчерпании, а не на каждом пропуске.
**Трогает:** `PlayerEngine.swift` `playbackFinished` (`:300-307`), `canGoNext` (`:58-59`); `Player/PlayerPill.swift`.
**Проверка:** дать одиночному треку доиграть с Autoplay on → related продолжают играть; выключить Autoplay → воспроизведение чисто останавливается в конце; блокнутый трек, который автопропускается (шаг 5), autoplay **не** запускает.

### 12. [M] `feat: keyboard playback control and persisted volume`

**Что:** повесить `.commands { PlaybackCommands(player: model.player) }` на `WindowGroup` (достижимо теперь, когда `NimbusApp` владеет моделью, шаг 2): Space = play/pause (загейтить, чтобы не воровать ввод в поле поиска), `⌘→` / `⌘←` = next/previous (**не** голые стрелки — оставить их под будущий seek), `⌘F` = фокус в поиск, тоглы shuffle/repeat. Вынести `var volume: Float` на `PlayerEngine` (вместо протекающего, нереактивного `player.player.volume` на `ContentView.swift:166-167`) и персистить его + последнюю выбранную секцию + последнюю очередь/`currentIndex` через `@AppStorage` (сегодня ноль `UserDefaults`/`AppStorage`; `AVPlayer.volume` сбрасывается в 1.0, и первое воспроизведение после запуска бьёт на 100%). На перезапуске восстановить громкость/секцию/очередь **без** автостарта воспроизведения (если только автор не захочет resume — см. открытые вопросы).
**Почему здесь:** последним — чистая полировка трения, ничего не открывает вниз; клавиатурная половина достижима только после поднятия модели на Scene (шаг 2). Восстановление сессии переиспользует тот же `@AppStorage`.
**Трогает:** `NimbusApp.swift` (`.commands` + `PlaybackCommands`); `PlayerEngine.swift` (`var volume`, restore-on-init); `Player/PlayerPill.swift` `VolumeButton` (бывш. `ContentView.swift:413`) биндится к громкости движка; `App/Shell.swift` (`@AppStorage` секции, фокус-биндинг `⌘F`).
**Проверка:** Space переключает play/pause, `⌘`-стрелки меняют треки, `⌘F` фокусирует поиск; выставить громкость ~30%, выйти, перезапустить → первое воспроизведение на 30%, очередь и секция восстановлены.

### 13. [M] `feat: distinguish load errors from empty results`

**Что:** дать упавшим загрузкам отдельное состояние ошибки+retry вместо `ContentUnavailableView`. `FeedView` (`LibraryViews.swift:36` → `Pages/FeedView.swift`) и `FollowingView` (`LibraryViews.swift:104` → `Pages/FollowingView.swift`) показывают `ContentUnavailableView` на сбое — неотличимо от честно пустой ленты; читать флаги ошибок стора (`LibraryStore.playlistsError` на `:16` уже есть, но ни одна вью его не читает), чтобы показать «couldn't load — retry». Прекратить проглатывание ошибок в `[]` в `LibraryStore.tracks(for:)` (`:254-264`, `return []` на `:264`), из-за которого упавшая quick-play-карточка Home — мёртвый клик; выдать сбой наружу, чтобы карточка сообщила о нём.
**Почему здесь:** независимо, низкий риск, без зависимостей — можно и подвинуть раньше; поставлено последним как «легибельность сбоя» после движкового шага 5, чтобы и плеер, и списки говорили правду об ошибке.
**Трогает:** `Pages/FeedView.swift`, `Pages/FollowingView.swift`, `Pages/HomeView.swift` (quick-play-карточки); `LibraryStore.swift` `tracks(for:)` (`:254-264`) и флаги ошибок.
**Проверка:** с выключенной сетью Feed/Following показывают ошибку с retry, а не пустое состояние; упавшая quick-play-карточка Home сообщает о сбое; честно пустая лента по-прежнему читается как пустая.

---

## 4. Статус эндпоинтов api-v2

| Эндпоинт | Метод | Статус | Основание / шаг |
|---|---|---|---|
| `/users/{userID}/track_likes/{trackID}` | PUT/DELETE | **VERIFIED** | сверено с Nuage; шаг 6 |
| `/users/{userID}/playlist_likes/{playlistID}` | PUT/DELETE | **VERIFIED** | сверено с Nuage; шаг 6 |
| `/me/track_reposts/{trackID}` | PUT/DELETE | **VERIFIED** | сверено с Nuage; шаг 7 |
| `/me/playlist_reposts/{playlistID}` | PUT/DELETE | **VERIFIED** | сверено с Nuage; шаг 7 |
| `/tracks/{id}/related` | GET | **VERIFIED** | уже реализован `SoundCloudAPI.swift:104`; шаг 11 |
| `/users/{id}/followings` | GET | **VERIFIED** (чтение) | рабочий путь `SoundCloudAPI.swift:151`; засев в шаге 10 |
| follow/unfollow write (догадка `POST/DELETE /me/followings/{userID}`) | ? | **UNVERIFIED** | `/me/followings` — мёртвый путь (`SoundCloudAPI.swift:150`); захват в шаге 9, провод в шаге 10 |
| `/me/play-history` | POST | **UNVERIFIED-для-нашей-авторизации** | форма известна, но реальные клиенты шлют ещё и cookie-auth, не только заголовок OAuth (`SoundCloudAPI.swift:229`); вырезано |
| `/playlists` (создание) | POST | **UNVERIFIED** | вырезано |
| `/playlists/{id}` (правка) | PUT | **semi-verified** | вырезано |

FairPlay-license POST — единственный существующий не-GET в репозитории; вне scope.

---

## 5. Что сознательно вырезано

- **Preload + кроссфейд.** Один `AVPlayer` (`PlayerEngine.swift:32`), `replaceCurrentItem` на трек, холодный HLS-резолв на каждой границе. Сессия ключа FairPlay привязана к ассету (`PlayerEngine.swift:250`), поэтому preload N+1 требует второй `AVContentKeySession` — крупно и рискованно. v2 (CLAUDE.md отдаёт настоящий gapless в `AVSampleBufferAudioRenderer`). Поднятие модели (шаг 2) этому не помогает.
- **Мини-плеер в меню-баре + глобальные хоткеи** (PLAN Этап 5 / M3). `NSStatusItem`/`MenuBarExtra` + `KeyboardShortcuts` — отдельная подсистема. Поднятие модели оставляет дверь открытой (`MenuBarExtra` может читать `model.player`), не тратя бюджет сейчас.
- **`POST /me/play-history`.** Форма проверена; cookie-auth, которого не хватало, теперь есть (DataDome-синк) — **разблокировано**, едет на `mutate`. Хороший дешёвый «попутчик» write-слоя (корректность History, не UI).
- **Создание/правка плейлистов, add-to-playlist.** Write-путь готов; `PUT /playlists/{id}` (read-modify-write массива треков) semi-verified, `POST /playlists` (создание) ещё стоит подтвердить захватом. Крупнейший фича-пробел; нужен picker/dialog UI.
- **Настоящий Sign Out.** `signOut` (`AppModel.swift:24-27`) чистит только Keychain; cookie ре-харвестится из `WKWebsiteDataStore.default()` за секунду. Однокоммитный баг, отложен (ничего не блокирует).
- **Тихий ре-логин по протухшему `oauth_token`.** Сегодня обрабатывается только ротация `client_id`.
- **Персист библиотеки для холодного/офлайн-старта.**
- **Drag трека в очередь; drag-to-seek по волне** (роадмап Этап 3). Паттерн `DragGesture`→`onSeek` уже есть рядом в `ProgressScrubber` (`ContentView.swift:387`+), а `WaveformView` (`Waveform.swift`) — Canvas без жестов; на будущее.
- **Полный проход по accessibility** (`accessibilityLabel` = 0; PLAN M5 «VoiceOver читает скраббер» — 0%). Добавлять оппортунистически по мере правки каждой вью выше, не одним коммитом.
- **Локальный FTS5-мёрдж поиска** по фоллоу-артистам и своим плейлистам; сорт/фильтр для Likes/History; Clear Queue; инвалидация кэша; восстановление состояния окна. Реальные дыры, планируются независимо.

---

## 6. Открытые вопросы — на них ответит только автор (он запускает приложение)

1. **Пилл**: `.overlay` действительно удерживает пилл на всех четырёх pushed-страницах? (наблюдаемо только запуском)
2. **Резерв пилла**: доходит ли clear-color `.safeAreaInset` на `NavigationStack` до pushed-страниц, или конкретным страницам нужен свой нижний паддинг? От этого зависит, полон ли первичный фикс (раздел 1 → «Запасной вариант»).
3. **Форма follow-запроса** (метод/путь/тело/авторизация) — снимается захватом в шаге 9.
4. **Авторизация записи**: лайк/репост/фоллоу проходят с одним заголовком `OAuth` (`SoundCloudAPI.swift:229`), или write-путь требует ещё и cookie (та же неопределённость, что помечена для play-history)?
5. **Восстановление сессии**: на перезапуске возобновлять воспроизведение автоматически или только восстанавливать очередь/выбор без автостарта? (предпочтение автора; шаг 12)
6. **Deployment target**: `MACOSX_DEPLOYMENT_TARGET` = 15.6 на таргете приложения (`project.pbxproj:291,324`), но 26.5 на двух проект-уровневых конфигах (`:207,264`). Согласуется с решением «пол macOS 15, собирать SDK 26» на уровне таргета — подтвердить, что проект-уровневые 26.5 намеренны, а не забытый floor.