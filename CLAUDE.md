# Nimbus

Нативное приложение SoundCloud для macOS. Цель: самый быстрый и красивый клиент с фичами, которых нет в вебе — gapless-ощущение, очередь с drag-and-drop, системный Now Playing, мини-плеер в меню-баре, оффлайн-кэш.

Полный план первой версии: **[docs/PLAN.md](docs/PLAN.md)**. Эталон для изучения — [lbrndnr/nuage-macos](https://github.com/lbrndnr/nuage-macos) (живой SwiftUI SoundCloud-клиент, GPL-3, использует api-v2).

## Зафиксированные решения (2026-07-09)

- **Авторизация:** основной путь — внутренний **api-v2** (логин через WKWebView + харвест cookie `oauth_token`). Официальный OAuth 2.1 — подключаемый fallback. Слой авторизации **развязан** с движком стриминга.
- **Оффлайн-кэш:** в v1, строго **personal-use** (OSS, без бинарных релизов именно с этой фичей).
- **Целевая ОС:** deployment target **macOS 26.0**, только Apple Silicon (`ARCHS = arm64`). Floor поднят 16.09.2026: дизайн строится на Liquid Glass, а фолбэки на материалах никогда не проверялись вживую. Именно 26.0, не 26.5 — все glass-API есть в 26.0.
- **Язык/конкурентность:** Swift 6 language mode + Approachable Concurrency (`defaultIsolation = MainActor`); RT-аудио-путь помечать `nonisolated`.

## Жёсткие технические ограничения (проверено вживую, июль 2026)

- **Стриминг — AAC-over-HLS.** `hls_aac_160_url` / `hls_aac_96_url` (`.m3u8`): это HLS-клиент, не «скачай mp3». Прогрессивный MP3 вопреки анонсу **не убран** (проверено 05.09.2026) и остаётся фолбэком, но он на порядок медленнее — 3570 мс до звука против 1477 мс на HLS (замер 07.09.2026).
- **Подписанные HLS-ссылки живут ~5 мин** → на треках >5 мин переполучать плейлист во время игры (ре-резолв).
- **client_id (32 символа) ротируется** → скрейпить из `a-v2.sndcdn.com/assets/*.js`, ре-скрейп по 401/403. Первоисточник техники — `yt_dlp/extractor/soundcloud.py`.
- **Настоящий sample-accurate gapless не бесплатный:** сегменты — **fMP4/CMAF** (не ADTS/TS), `edts/elst` есть, но вырожденный, прайминг **2048 сэмплов ≈ 46,44 мс** на стыке (2112 — дефолт CoreAudio при молчащем контейнере). v1 = две деки `AVPlayer` с прогревом следующего трека: переход 20–34 мс против 1477 мс раньше (измерено 07.09.2026), архитектура держит задел под кроссфейд. v2 = кастом на `AVSampleBufferAudioRenderer`.
- **Now Playing на macOS:** нет `AVAudioSession`; вручную ставить `MPNowPlayingInfoCenter.default().playbackState` + заполнять `nowPlayingInfo`; `MPRemoteCommandCenter` для медиа-клавиш.
- **`AVAssetResourceLoaderDelegate` не кэширует HLS-сегменты** (ошибка -12881, только редирект). Офлайн = скачать сегменты + passthrough-ремукс через `AVAssetWriter` в `.m4a`.
- **ToS SoundCloud** запрещает офлайн-доступ и сохранение аудио, требует атрибуции. Отсюда personal-use posture и раздача вне App Store (DMG/Homebrew/GitHub, гайдлайн 5.2.2).

## Стек

GRDB.swift 7.11 (SQLite + FTS5-поиск) · swift-atomics 1.3 · Nuke 13 (артворк) · KeyboardShortcuts 3 (глоб. хоткеи, без прав доступа) · свой `SecItem`-Keychain (KeychainAccess мёртв) · URLSession async/await (без Alamofire) · DSWaveformImage 14.5 или свой Canvas · MPNowPlayingInfoCenter + MPRemoteCommandCenter.

## Стиль кода

- Комментарии по умолчанию — **нулевые**; только если объясняют неочевидное «почему» одной строкой. Комментарии на английском.
- LSP для символьных правок (references/rename), grep — для текста.
