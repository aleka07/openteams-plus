# План: Self-hosted Jitsi Meet с авто-записью и пер-участниковыми аудиодорожками

Статус: черновик на утверждение. Дата: 2026-07-07.
Синтез двух независимых исследований (Opus deep-reasoner + Codex), проверено по исходникам Jitsi и актуальной документации (июнь 2026).

## Вводные

- Сервер: `contabo-hermes-alikhan` (185.197.249.105), Ubuntu 24.04, 4 CPU / 7.8 GB RAM / 145 GB диск.
  Сервер разделяемый: нативный Caddy на 80/443, Rails-приложение (puma+sidekiq), hermes-agent (~3 GB RAM уже занято).
- Деплой: официальный docker-jitsi-meet (compose), свежий stable-релиз 2026.
- Авторизация: secure domain (`ENABLE_AUTH=1`, `ENABLE_GUESTS=1`, `AUTH_TYPE=internal`), позже — OpenLDAP.
- Масштаб: 1–2 одновременные записываемые конференции.

## Архитектура

```
                            docker-jitsi-meet (внутренняя docker-сеть)
   Caddy (хост, 80/443) ──reverse proxy──► web ──► prosody ◄──► jicofo ◄─Colibri2─► jvb
                                                    │                                │
                                    (1) mod_jibri_autostart                          │ (2) Exporter: media-json ws,
                                        авто-старт записи                            │     Opus каждого участника
                                                    ▼                                ▼
                                                 jibri ──► общий .mp4      jitsi-multitrack-recorder ──► .mka
                                                    │                                │  (по дорожке на участника)
                                             finalize.sh                       finalize: split → WAV на спикера
                                                    │                                │
                                    (3) mod_participant_log ─► participants.json ────┘ (имена, join/leave)
```

Два независимых пути записи, оба стартуют автоматически, оба полностью self-hosted.

## Ключевые решения и обоснование

### 1. Авто-запись всех встреч → Jibri + Prosody-модуль `jibri_autostart`

- Встроенного autoRecord в Jitsi НЕ существует (проверено обоими исследованиями; jicofo issue #344 — не реализовано намеренно).
- `jibri_autostart` из [jitsi-contrib/prosody-plugins](https://github.com/jitsi-contrib/prosody-plugins) (поддерживается): на входе модератора шлёт тот же IQ, что и кнопка «Start recording». ~70 строк Lua, без дополнительных процессов.
- Отвергнуто: скрытый бот-модератор через IFrame API (предложение Codex) — рабочий вариант, но добавляет целый headless-браузер, который надо обслуживать. Оставляем как fallback, если модуль не заведётся на нашей версии.
- Известные failure modes модуля:
  - one-shot без ретрая: если Jibri занят/упал в момент старта — комната остаётся без записи. Митигция: мониторинг + при необходимости патч «латч только при успехе».
  - запись стартует при входе первого модератора (в secure domain — авторизованного пользователя); гости до этого момента не записываются — для нас это желаемое поведение.

### 2. Дорожки участников → `jitsi-multitrack-recorder` + JVB Exporter

Официальный [jitsi/jitsi-multitrack-recorder](https://github.com/jitsi/jitsi-multitrack-recorder) (живой, коммиты 2026). JVB сам стримит Opus-аудио каждого участника (media-json по websocket, `videobridge.exporter`), рекордер пишет multitrack `.mka` и после встречи finalize-скриптом раскладывает в отдельные файлы по спикерам (форкаем `flatten-mka.sh` → WAV на участника).

Почему он, а не альтернативы:
- **Не участник конференции**: JVB-side копия медиа. Не нужны XMPP-аккаунт, hidden domain, невидимость; secure domain и LDAP его не затрагивают.
- Только аудио — минимальный CPU, масштабируется почти бесплатно (в отличие от Jibri).
- Дорожки синхронизированы (общая референс-шкала SSRC-таймстампов в JVB).
- Отвергнуты: Jigasi transcriber (`RECORD_AUDIO=true`) — Plan B, тяжёлая JVM, участник конференции, формат аудио-дампа недокументирован; puppeteer-бот с MediaRecorder — N процессов записи, дрейф синхронизации, хрупко; свой aiortc/pion клиент — реимплементация сигналинга Jitsi, неподъёмное сопровождение.

Риски (проверяем на шаге 4 до продолжения):
- Путь Exporter→recorder новый (2024–2025), слабо задокументирован. Верифицировать на пиннутом образе: `reference.conf` JVB содержит `videobridge.exporter`; у Jicofo есть `transcription.url-template`.
- В docker-jitsi-meet нет готовых env для multitrack-recorder — добавляем как кастомный compose-сервис + кастомный конфиг Jicofo.
- Триггер: `transcription.autoTranscribeOnRecord: true` (по умолчанию true) — запись Jibri автоматически включает и transcriber-коннект. Проверить цепочку end-to-end; при необходимости — мини-модуль Prosody, включающий transcribing на создании комнаты.

### 3. Имена участников → кастомный Prosody-модуль (единственный самописный компонент)

Рекордер знает только endpoint/source ID. Пишем модуль `mod_participant_log`: на `muc-occupant-joined/-left` дописывает `{endpointId, displayName, jid, joinedAt, leftAt}` в `participants.json` комнаты. Finalize мапит дорожку → имя. (~50–100 строк Lua; готового решения нет — подтверждено обоими исследованиями.)

### 4. Публикация через существующий Caddy

80/443 заняты нативным Caddy → web-контейнер Jitsi слушает внутренний порт (например 127.0.0.1:8443), Caddy проксирует `meet.<домен>`. JVB-медиа идёт мимо Caddy напрямую: **UDP 10000** открыть в firewall. TLS терминирует Caddy (штатный сценарий docker-jitsi-meet).

### 5. LDAP — фаза 2, без переделок

docker-jitsi-meet поддерживает `AUTH_TYPE=ldap` из коробки (saslauthd + Cyrus SASL, env: `LDAP_URL`, `LDAP_BASE`, `LDAP_BINDDN`, `LDAP_BINDPW`, `LDAP_FILTER`, `LDAP_TLS_*`; протестировано с OpenLDAP). Топология secure domain не меняется — переключение `internal` → `ldap` = правка env. Сервисные аккаунты (jibri) остаются internal.

## Ограничение по ресурсам (требует решения)

Jibri = headless Chrome + ffmpeg: ~2 vCPU / 3 GB RAM на одну запись в 720p. На нашем разделяемом 4 CPU / 8 GB:

- Реалистично: **1 одновременная Jibri-запись в 720p**. Вторая параллельная встреча при этом ВСЁ РАВНО получит пер-участниковое аудио (multitrack-recorder дёшев), но не общий видеофайл.
- Варианты, если 2 параллельных видеозаписи обязательны: апгрейд VPS (8 vCPU / 16 GB) или вынос Jibri на отдельную машину.

## Файловая структура записей

```
/srv/jitsi-recordings/<room>/<YYYY-MM-DD_HHMM>/
  combined/recording.mp4        # Jibri (finalize.sh переименовывает и переносит)
  tracks/<displayName>.wav      # multitrack-recorder после finalize
  participants.json             # mod_participant_log: кто, когда вошёл/вышел
  meeting.json                  # сводные метаданные, status=complete
```

Диск: ~1–3 GB/час на видеозапись 720p + ~30 MB/час на участника (аудио). 124 GB свободно — заложить ротацию/очистку в runbook.

## Фазы реализации

0. **Подготовка хоста** (нужен sudo): `linux-modules-extra-$(uname -r)` + `snd-aloop` (2 loopback-устройства про запас), `alikhan` в группу `docker`, UDP 10000 в firewall, DNS-запись `meet.<домен>`.
1. **Базовый стек**: docker-jitsi-meet (свежий stable), web за Caddy, secure domain (`AUTH_TYPE=internal`), проверка звонка двух участников.
2. **Jibri + авто-старт**: 1 инстанс, 720p, ручная запись → `jibri_autostart` → finalize.sh с раскладкой файлов. Верификация: встреча записывается без единого клика.
3. **Multitrack-recorder**: верифицировать Exporter в пиннутом образе JVB; добавить сервис в compose; `transcription.url-template` → `ws://jmr:8989/record/{{MEETING_ID}}`; проверить `.mka` с дорожками.
4. **Идентификация**: `mod_participant_log` + форк `flatten-mka.sh` → WAV по спикерам с именами.
5. **Фронт записей**: Filebrowser (Docker) над `/srv/jitsi-recordings` на **rec.kzt.asia** через существующий Caddy; просмотр mp4 в браузере, скачивание, доступ по логину/паролю. (Решение 2026-07-07.)
6. **Эксплуатация**: мониторинг (Jibri busy/failed, диск), ротация записей, runbook.
7. **LDAP** (отдельно, позже): OpenLDAP-контейнер + `AUTH_TYPE=ldap`.

## Принятые решения (2026-07-07)

1. Домен: **meet.kzt.asia** (DNS A-запись → 185.197.249.105).
2. Железо: остаёмся на текущем VPS — 1 одновременная видеозапись достаточно; приоритет — аудиодорожки per-participant (пишутся у всех встреч без ограничений).
3. Ретенция: записи храним последние N дней (конфигурируемо, по умолчанию 14), автоочистка по cron в фазе 5.
