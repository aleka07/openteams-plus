# OpenTeams+ recording module

Adds meeting recording to a stock `docker-jitsi-meet` (stable-11031) deployment.
Three independent, fully self-hosted capabilities, all triggered automatically with
no UI clicks:

## 1. What you get

- **Auto video recording** — every meeting is recorded to a combined `mp4` by
  **Jibri**, started automatically when the first authorized participant joins (no
  "Start recording" click). Output: `<room>/<timestamp>/combined/recording.mp4`.
- **Per-speaker audio tracks + participants journal** — the
  **jitsi-multitrack-recorder (JMR)** captures one Opus track per participant
  directly from the videobridge, and after each meeting `split-tracks.sh` splits it
  into named, timeline-aligned `WAV`s (`tracks/NN_Name.wav`) plus a
  `participants.json` / `meeting.json` journal. This is the raw material for
  diarized transcription / STT pipelines: one clean channel per speaker, all sharing
  `t=0` = recording start.
- **Web UI to browse and download** — a **Filebrowser** container serves the whole
  recordings tree read-only: browse folders, stream the mp4 in-browser, download the
  WAVs and json. Single login in front of everything.

## 2. Architecture

```
                    docker-jitsi-meet (internal docker network)
  reverse proxy ──► web ──► prosody ◄────► jicofo ◄──Colibri2──► jvb
   (Caddy etc.)               │              │                     │
                              │              │                     │ videobridge.exporter:
              mod_jibri_autostart            │                     │ per-participant Opus
              (start IQ + set recording      │                     │ media-json over ws
               metadata: isTranscribing +    │                     ▼
               asyncTranscription) ──────────┘        jitsi-multitrack-recorder (JMR)
                              │       jicofo transcription.url-template          │
                              ▼       = ws://jmr:8989/record/{{MEETING_ID}}      │
                           jibri                                    recording.mka (1 track/participant)
                              │                                                  │
                        finalize.sh                                     split-tracks.sh (JMR finalize)
                     combined/recording.mp4                            tracks/NN_Name.wav + meeting.json
                              │                                                  ▲
              mod_participant_log ──► _meta/<meetingId>.json (names, join/leave) ┘

              Filebrowser (recfront) ──► read-only view of /srv/jitsi-recordings
```

Two independent recording paths (Jibri video, JMR audio) start from the same
prosody hook. Only `mod_participant_log`, `mod_jibri_autostart`, and `split-tracks.sh`
are ours; everything else is upstream Jitsi wired together via config.

## 3. Requirements

- **Linux host** (Jibri needs kernel audio loopback; not available on macOS/Windows).
- **`snd-aloop` kernel module** — install `linux-modules-extra-$(uname -r)` and load
  `snd-aloop`. Jibri uses ALSA loopback to capture the mixed meeting audio.
- **CPU/RAM**: budget **~2 vCPU + 3 GB RAM per concurrent 720p Jibri recording**
  (headless Chrome + ffmpeg). The JMR audio path is cheap by comparison (audio only,
  no browser) and scales to many concurrent meetings — so a host that can only afford
  one concurrent video recording still gets per-participant audio for every meeting.
- **Disk**: roughly 1–3 GB/hour per 720p video + ~30 MB/hour per participant of
  audio. Plan retention/rotation.
- **Firewall**: JVB media is UDP 10000, direct to the host (it does not traverse the
  reverse proxy).

## 4. Install (against docker-jitsi-meet stable-11031)

Paths below use `$JITSI` for the jitsi compose dir (e.g. `~/jitsi`), `$CONFIG` for
the jitsi config root (e.g. `~/.jitsi-meet-cfg`), and `/srv/jitsi-recordings` as the
host recordings root. Adjust to taste.

### 4.1 Host prep

```bash
# snd-aloop (once): install extra modules, load now + on boot
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo modprobe snd-aloop
echo snd-aloop | sudo tee /etc/modules-load.d/snd-aloop.conf

# recordings root + staging dirs (see ownership caveats in Gotchas)
sudo install -d -m 2775 /srv/jitsi-recordings
sudo install -d -m 0755 /srv/jitsi-recordings/_bin
```

### 4.2 Prosody modules

```bash
cp prosody-plugins-custom/*.lua $CONFIG/prosody/prosody-plugins-custom/
```

Enable them under the conference MUC component via `.env`:

```
XMPP_MUC_MODULES=jibri_autostart,participant_log
```

### 4.3 Environment

Merge `env.recording.example` into `$JITSI/.env` and set real values (Jibri/XMPP
passwords, resolution, `PROSODY_ENABLE_RECORDING_METADATA=1`, the `XMPP_MUC_MODULES`
line above, and `JIBRI_FINALIZE_RECORDING_SCRIPT_PATH` pointing at finalize.sh).

### 4.4 Jibri finalize script

```bash
cp jibri/finalize.sh $CONFIG/jibri/finalize.sh
chmod 0755 $CONFIG/jibri/finalize.sh
# .env: JIBRI_FINALIZE_RECORDING_SCRIPT_PATH=/config/finalize.sh
```

### 4.5 Jicofo: transcription URL template

Create `$CONFIG/jicofo/custom-jicofo.conf` (mounted into jicofo) with:

```hocon
jicofo {
  transcription {
    url-template = "ws://jmr:8989/record/{{MEETING_ID}}"
  }
}
```

This points jicofo's transcriber connect at JMR, so the videobridge exports each
participant's Opus stream to `ws://jmr:8989/record/<MEETING_ID>`.

### 4.6 JMR finalize splitter

```bash
sudo install -m 0755 jmr/split-tracks.sh /srv/jitsi-recordings/_bin/split-tracks.sh
# participant-log staging dir, writable by prosody's container uid (100)
sudo install -d -o 100 -g <RECORDINGS_GID> -m 2775 \
     /srv/jitsi-recordings/_multitrack/_meta
```

### 4.7 Compose override

The override is **not** auto-loaded — you must list it explicitly, and after the
base files so it wins:

```bash
cp compose/docker-compose.override.yml $JITSI/docker-compose.override.yml
cd $JITSI
docker compose -f docker-compose.yml -f jibri.yml \
               -f docker-compose.override.yml up -d
```

Edit the override first: rename the `proxy` external network to your reverse-proxy
network, and set the recordings root / `<RECORDINGS_GID>` to match your host.

### 4.8 Reverse proxy + recordings front

- Add the site blocks from `caddy/Caddyfile.example` (or the Traefik/nginx
  equivalent) — `meet.example.com` → `jitsi-web:80`, `rec.example.com` →
  `recfront:80` — on the shared proxy network.
- Deploy the recordings web UI: `cd recfront && docker compose up -d`. Log into
  Filebrowser once and change the default admin password immediately.

## 5. Gotchas (production lessons — read before you debug)

- **Jibri runs as uid 999.** The recordings dir it writes to must be owned
  `999:<RECORDINGS_GID>` with mode `2775` (setgid so subdirs inherit the group), or
  finalize fails to `mkdir`/`mv` and the mp4 is stranded in the session dir.
- **Prosody runs as uid 100.** The `_meta` staging dir must be writable by uid 100
  (`chown 100:<RECORDINGS_GID>`, group-writable), or `mod_participant_log` cannot
  write `participants.json` and speaker names silently fall back to endpoint IDs.
- **jicofo (build 1183) needs BOTH metadata flags.** The multitrack export starts
  only when `recording.isTranscribingEnabled` AND top-level `asyncTranscription` are
  both `true`. Setting only one is a **silent no-op** — no error, no export.
  `mod_jibri_autostart.lua` sets both; do not remove either.
- **Jitsi has no built-in auto-record.** There is no `autoRecord` option upstream
  (jicofo issue #344, intentionally unimplemented). `mod_jibri_autostart` sends the
  same `start` IQ the UI button would — that is the supported mechanism.
- **JMR image already ships ffmpeg** (plus ffprobe, jq, awk, bash). `split-tracks.sh`
  needs no extra packages and runs **as root** inside the JMR container.
- **finalize is invoked as `<MEETING_ID> <DIR> <FORMAT>`** by JMR (via
  `JMR_FINALIZE_SCRIPT`), e.g. `split-tracks.sh <id> /data/<id> MKA`.
- **The `_meta` staging dir avoids JMR's dir-suffix trap.** Prosody writes participant
  data before JMR necessarily creates its meeting dir, and JMR may suffix a
  pre-existing dir (`<id>-1`). Keying the staging file by `meetingId` and looking it
  up from the finalize script's `$1` makes the name→track join robust to any JMR dir
  naming; prosody never touches JMR's output tree.
- **Jibri finalize timestamps include seconds** (`%Y-%m-%d_%H%M%S`) to avoid
  collisions when the same room is recorded twice within the same minute.

## 6. On-disk output layout

```
/srv/jitsi-recordings/
├── <room>/
│   └── <YYYY-MM-DD_HHMMSS>/
│       └── combined/
│           ├── recording.mp4          # Jibri combined video (finalize.sh)
│           └── metadata.json          # Jibri session metadata
└── _multitrack/
    ├── _meta/
    │   └── <meetingId>.json           # live participants journal (mod_participant_log)
    └── <meetingId>/
        ├── recording.mka              # JMR multitrack (one Opus track per participant)
        ├── tracks/
        │   ├── 01_Alice.wav           # per-speaker WAV, aligned to t=0 (split-tracks.sh)
        │   └── 02_Bob.wav
        └── meeting.json               # summary: participants + tracks
```

## 7. Verification checklist

The exact log lines proving each link of the chain works:

- **prosody** (`docker compose logs prosody`):
  - `mod_jibri_autostart` loaded, and on a real meeting:
    `phase3: multitrack audio export enabled for <room>@...`
  - `mod_participant_log`: `participant_log loaded (output dir=/meta)` and per meeting
    it (re)writes `_meta/<meetingId>.json`.
- **jicofo** (`docker compose logs jicofo`):
  - `Setting enableTranscribing=true`
  - `Adding connect for transcriber` (the Colibri2 connect that starts the export).
- **JMR** (`docker compose logs jmr`):
  - one **track start** line per participant, then on session end
    `[split-tracks] ...` progress and `Finalize script completed`.
- **On disk**: `combined/recording.mp4` appears under `<room>/<ts>/`, and
  `_multitrack/<meetingId>/tracks/NN_Name.wav` + `meeting.json` appear after the
  meeting ends.

## Credits

Built on upstream Jitsi projects:

- [jitsi/jibri](https://github.com/jitsi/jibri) — combined recording.
- [jitsi/jitsi-multitrack-recorder](https://github.com/jitsi/jitsi-multitrack-recorder)
  — per-participant audio export.
- [jitsi-contrib/prosody-plugins](https://github.com/jitsi-contrib/prosody-plugins)
  — basis for `mod_jibri_autostart`.
- [filebrowser/filebrowser](https://github.com/filebrowser/filebrowser) — recordings
  web UI.

See `docs/PLAN.ru.md` for the original design rationale (Russian).
