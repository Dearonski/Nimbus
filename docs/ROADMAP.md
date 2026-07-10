# Nimbus — порядок работ после M0–M2

Каркас готов: логин, HLS-плеер с ре-резолвом и FairPlay, очередь, Now Playing, библиотека, поиск, страницы артиста/трека. Дальше — по соотношению «ощущение полноценности / трудозатраты».

## Этап 1 — Интерактив: клиент перестаёт быть read-only

Самая большая дыра: в `SoundCloudAPI` нет ни одного мутирующего запроса.

1. **Социальные действия в API** (эндпоинты сверять с Nuage / веб-клиентом):
   - лайк трека: `PUT/DELETE /users/{me}/track_likes/{trackID}`; лайк плейлиста аналогично через `playlist_likes`
   - репост: `PUT/DELETE /me/track_reposts/{trackID}` (и `playlist_reposts`)
   - фоллоу: `POST/DELETE /me/followings/{userID}`
   - состояние «лайкнуто/зафоллоулено» — в `LibraryStore` (сеты id из likes/followings), оптимистичное обновление UI.
2. **Контекстные меню** на `TrackRow`, `TrackCard`, `QueueItemView`: Play Next · Add to Queue · Like · Repost · Go to Artist · Copy Link.
3. **Очередь**: `playNext(_:)` / `playLater(_:)` в `PlayerEngine` (вставка после `currentIndex` / в конец, с учётом shuffle-порядка).
4. **Запись истории**: `POST /me/play-history` (track_urn) при старте трека — иначе History наполняется только вебом.
5. Кнопки Like/Repost на странице трека и в плеер-пилле (сердечко).

**Done:** лайк из Nimbus виден в вебе; правый клик работает везде; History растёт от прослушиваний в Nimbus.

## Этап 2 — Музыка не останавливается

1. **Related tracks**: `GET /tracks/{id}/related` в API.
2. **Autoplay-станция**: очередь исчерпана → дозагрузить related от последнего трека (переключатель в UI, состояние «Autoplay» в пилле).
3. Полки на странице трека: «More like this» (related) и «More from {artist}» (userTracks уже есть).

**Done:** плейлист закончился → музыка продолжается related-треками; страница трека — не тупик.

## Этап 3 — Waveform-скраббер

1. Парсить `waveform_url` в `SCTrack` (JSON `{width, height, samples[]}`).
2. Рендер на Canvas: столбики, заливка прогресса тинтом, drag-to-seek. Компонент общий.
3. Использовать на странице трека (крупно) и в PlayerPill вместо тонкой полоски (мелко).
4. Таймлайн-комменты: `GET /tracks/{id}/comments`, аватарки на волне на странице трека.

**Done:** скраббинг по волне в пилле и на странице трека; комменты видны на таймлайне.

## Этап 4 — Разнообразить страницы

1. **Плейлист**: хедер — обложка, автор, число треков и суммарная длительность, кнопки Play / Shuffle; описание.
2. **Артист**: баннер из `visuals`, кнопки Follow и Play all, табы Popular / Tracks / Albums / Playlists / Reposts (`/users/{id}/toptracks`, `/albums`, `/playlists_without_albums`, `/reposts`).
3. **Home**: `/mixed-selections` (системные миксы, Daily Drops, «Artists you should know»), полка «Recently played» из GRDB, ряд жанровых чипов над Trending (charts уже принимает genre).
4. **Library**: разделить Albums / Playlists / Stations.
5. **Пустой поиск**: сетка жанров вместо пустоты.
6. **FTS5 к поиску**: локальные результаты из `AppDatabase.search()` мгновенно, сетевые доклеиваются (оба куска готовы, соединить в `LibraryStore.search`).

**Done:** Home из 4–5 разнородных полок; у плейлиста и артиста полноценные хедеры; поиск отвечает мгновенно из локальной базы.

## Этап 5 — Мини-плеер в меню-баре (M3 плана)

`NSStatusItem` + `NSPanel`, переключение activation policy (`.regular`/`.accessory`), close = hide, глобальные хоткеи через KeyboardShortcuts.

**Done:** приложение живёт в меню-баре без иконки в доке; мини-плеер управляет воспроизведением.

## Этап 6 — Устойчивость и полировка (M5 плана)

- Тихий ре-логин по протухшему `oauth_token` (сейчас обрабатывается только ротация client_id).
- Ошибки наружу: тосты/баннеры вместо поля `status` плеера.
- Предбуферизация следующего трека + кроссфейд (убрать паузу на стыке).
- Клавиатурная навигация (space = play/pause, стрелки, ⌘F в поиск), окно настроек.

## Потом

- Оффлайн-кэш (M4 плана) — сегменты + ремукс `AVAssetWriter` в `.m4a`, personal-use.
- Настоящий gapless на `AVSampleBufferAudioRenderer` (v2).
- Тема по цветам обложки (MeshGradient), Go+ 256k, sleep timer, scrobble.
