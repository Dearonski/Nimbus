# Nimbus

Нативное приложение SoundCloud для macOS. Цель: самый быстрый и красивый клиент с фичами, которых нет в вебе — gapless-ощущение, очередь с drag-and-drop, системный Now Playing, мини-плеер в меню-баре, оффлайн-кэш.

Полный план первой версии: **[docs/PLAN.md](docs/PLAN.md)**. Эталон для изучения — [lbrndnr/nuage-macos](https://github.com/lbrndnr/nuage-macos) (живой SwiftUI SoundCloud-клиент, GPL-3, использует api-v2).

## Зафиксированные решения (2026-07-09)

- **Авторизация:** основной путь — внутренний **api-v2** (логин через WKWebView + харвест cookie `oauth_token`). Официальный OAuth 2.1 — подключаемый fallback. Слой авторизации **развязан** с движком стриминга.
- **Оффлайн-кэш:** в v1, строго **personal-use** (OSS, без бинарных релизов именно с этой фичей).
- **Целевая ОС:** deployment target **macOS 15**, собирать SDK 26 (не ставить floor в 26.5).
- **Язык/конкурентность:** Swift 6 language mode + Approachable Concurrency (`defaultIsolation = MainActor`); RT-аудио-путь помечать `nonisolated`.

## Жёсткие технические ограничения (проверено вживую, июль 2026)

- **Стриминг только AAC-over-HLS.** Прогрессивный MP3 убран ~31.12.2025. Есть `hls_aac_160_url` / `hls_aac_96_url` (`.m3u8`). Это HLS-клиент, не «скачай mp3».
- **Подписанные HLS-ссылки живут ~5 мин** → на треках >5 мин переполучать плейлист во время игры (ре-резолв).
- **client_id (32 символа) ротируется** → скрейпить из `a-v2.sndcdn.com/assets/*.js`, ре-скрейп по 401/403. Первоисточник техники — `yt_dlp/extractor/soundcloud.py`.
- **Настоящий sample-accurate gapless не бесплатный:** сегменты — ADTS/TS без edit-lists (≈48 мс тишины прайминга на стыке). v1 = `AVQueuePlayer` (бесшовно) + кроссфейд. v2 = кастом на `AVSampleBufferAudioRenderer`.
- **Now Playing на macOS:** нет `AVAudioSession`; вручную ставить `MPNowPlayingInfoCenter.default().playbackState` + заполнять `nowPlayingInfo`; `MPRemoteCommandCenter` для медиа-клавиш.
- **`AVAssetResourceLoaderDelegate` не кэширует HLS-сегменты** (ошибка -12881, только редирект). Офлайн = скачать сегменты + passthrough-ремукс через `AVAssetWriter` в `.m4a`.
- **ToS SoundCloud** запрещает офлайн-доступ и сохранение аудио, требует атрибуции. Отсюда personal-use posture и раздача вне App Store (DMG/Homebrew/GitHub, гайдлайн 5.2.2).

## Стек

GRDB.swift 7.11 (SQLite + FTS5-поиск) · swift-atomics 1.3 · Nuke 13 (артворк) · KeyboardShortcuts 3 (глоб. хоткеи, без прав доступа) · свой `SecItem`-Keychain (KeychainAccess мёртв) · URLSession async/await (без Alamofire) · DSWaveformImage 14.5 или свой Canvas · MPNowPlayingInfoCenter + MPRemoteCommandCenter.

## Стиль кода

- Комментарии по умолчанию — **нулевые**; только если объясняют неочевидное «почему» одной строкой. Комментарии на английском.
- LSP для символьных правок (references/rename), grep — для текста.
