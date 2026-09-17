# Структура проекта

Принято 17.09.2026, при подготовке к релизу. Две цели: убрать свалки (`Components/` 25 файлов, `Pages/` 23) и сделать так, чтобы изменение api-v2 на стороне SoundCloud правилось в одном месте, а не искалось по телам 65 методов.

Проект собирается синхронизированными папками (`PBXFileSystemSynchronizedRootGroup`), поэтому перенос файлов — это `git mv`: `project.pbxproj` не трогается, история сохраняется.

## Дерево

```
Nimbus/
├── App/                    NimbusApp · AppModel · Navigator · Theme
│   └── Shell/              ContentView · SidebarNav · DetailColumn · PlaybackErrorBanner
│
├── SoundCloud/             весь контакт с сервисом
│   ├── Transport/          SCHTTPClient · SCEndpoint · SCError
│   │                       GraphQLTransport · ClientIDResolver · WebWriteBridge
│   ├── Endpoints/          Me · Users · Tracks · Playlists · Search · Stream
│   │                       Charts · Stations · Comments · ProfileEdit · Mutations
│   ├── Models/             Track · User · Playlist · Page · Stream · Search
│   │                       Comment · Media · Profile · Genre
│   └── Auth/               Keychain · LoginWebView · WebSessionCookies
│
├── Playback/               PlayerEngine · PlayQueue · PreparedTrack · HLSResourceLoader
│                           FairPlayKeyDelegate · PrimingProbe · HandoffTrace
├── Player/                 PlayerPill · QueuePanel
│
├── Features/               страница = папка со своими частями
│   Home · Feed · Artist · Track · Playlist · Search · Likes · Profile · Genre · Welcome
│
├── Components/             общие блоки, знающие о доменных моделях
│   Cards/ · Rows/ · Blocks/ · Artwork · WaveformStrip
│
├── DesignSystem/           общие блоки без знания домена
│   Controls/ (Glass*, PlayerGlyphs, PlayerButtonStyle) · Feedback/ (Skeleton, FaderLoader, Paging)
│   Brand/ (NimbusMark, SCGradient) · Layout/ (Metrics, StickyColumn, RailBlock)
│   Media/ (MediaCard, ArtworkLightbox)
│
├── Data/                   LibraryStore · Pager · TrackFeed · AppDatabase · WaveformStore
└── Core/                   Formatters · PreparedImage
```

## Куда класть новый файл

1. **Использует одна фича** → внутрь неё, `Features/<Фича>/`.
2. **Использует две и больше** → в общий слой, и там выбор механический:
   - упоминает `SC*`-модель, `AppModel`, `PlayerEngine`, `PlayQueue` или `LibraryStore` → `Components/`;
   - не упоминает ничего из этого → `DesignSystem/`.

Второй пункт держит `DesignSystem/` ни от чего не зависящим — его можно вынести в отдельный пакет, не распутывая связи.

## Как меняются запросы к api-v2

Запрос — значение, а не тело метода. Каталог лежит в `SoundCloud/Endpoints/`, по файлу на домен:

```swift
extension SCEndpoint where Response == SCPage<SCTrack> {
    static func userTracks(_ id: Int, limit: Int = 30) -> Self {
        .get("/users/\(id)/tracks",
             ["limit": "\(limit)", "linked_partitioning": "1"],
             verified: "2026-09-08")
    }
}
```

Фабрики сгруппированы по типу ответа (`extension SCEndpoint where Response == …`) — так `.userTracks(id)` выводится без указания типа. Записи не дженерик и живут в `SCWrite`: они уходят через `WebWriteBridge` и тела не возвращают.

Методы `SoundCloudAPI` остаются тонкими обёртками над каталогом, поэтому файлы-потребители при смене схемы не трогаются.

`verified` — дата последней живой проверки, данные, а не комментарий: по ней строится отчёт «что давно не проверялось», и по каталогу же прогоняется smoke-тест.

Сломанную схему видно по имени: транспорт ловит `DecodingError`, достаёт `codingPath` и отдаёт `SCError.decoding(endpoint:field:)` плюс запись в `Logger(category: "api")` — вместо «не загрузилось» в UI.

`NimbusTests` прогоняет каталог с живым токеном из Keychain и печатает таблицу: `OK` / HTTP-код / имя пропавшего поля.

GraphQL-операции (комментарии, топ-фанаты) каталогом не покрыты: там меняется не путь, а текст запроса, и все шесть уже лежат рядом в `Endpoints/Comments.swift`.

## Порядок перехода

| Этап | Что | Проверка | |
|---|---|---|---|
| 1 | `SoundCloud/Transport` + `Models` (разрезан 735-строчный файл моделей) | сборка | сделано 17.09.2026 |
| 2 | `Endpoints/` — каталог из 64 эндпоинтов, методы стали обёртками | сборка | сделано 17.09.2026 |
| 3 | `SCError.decoding` + лог по эндпоинтам | сборка | сделано 17.09.2026 |
| 4 | `NimbusTests` — smoke-прогон каталога | живой прогон, 39/39 за 19 с | сделано 17.09.2026 |
| 5 | `Features/` + `Components/` + `DesignSystem/` — перенос вью | сборка + рендер превью | сделано 17.09.2026 |
| 6 | `Data/`, `Core/`, разрезание `Shell.swift` | сборка | сделано 17.09.2026 |

Тестовый таргет запускается внутри приложения (`TEST_HOST`): приложение в песочнице и держит токен в Data Protection keychain, до которого голый тест-бандл не дотянется. Прогон только читает — ни лайков, ни подписок, ни загрузок, так что состояние аккаунта он не меняет.

API идёт первым: он и есть главная боль, и с переносом вью не пересекается. Вью — последними, чтобы их диффы не мешались с API-правками.

## Решённое при переносе

- `TrackHero` остался в `Features/Track`: странице сета от него нужен был не сам блок, а одна константа отступа. Она переехала в `ContentMetrics.heroInset`, и межфичевой ссылки не осталось.
- Правило проверяется скриптом и уже отработало: `RailBlock` домена не знает — уехал в `DesignSystem/Layout/`; `DesignPreview` знает (`AppModel`, `PlayerEngine`, модели) — остался в `App/`, потому что это витрина страниц, а не компонент.
- Имена файлов держим уникальными по всему таргету: два `.swift` с одним базовым именем не собираются («Multiple commands produce … .stringsdata»).
