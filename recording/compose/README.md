# compose

Docker Compose override for `docker-jitsi-meet` (stable-11031). See
[`../README.md`](../README.md) §4.7 for the full install flow.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.override.yml` | Wires the recording services onto the stock jitsi stack. |

## What it wires

- **web** — joins the shared reverse-proxy network under the alias `jitsi-web`.
- **jibri** — `/dev/snd` passthrough (needs host `snd-aloop`) + recordings bind
  mount (`/recordings-out`).
- **prosody** — the `_meta` staging dir (`/meta`) where `mod_participant_log`
  writes `participants.json`; maps to `_multitrack/_meta` on the host, seen by JMR
  as `/data/_meta`. Prosody runs as uid 100, so that host dir must be
  `chown 100:<RECORDINGS_GID>` and group-writable.
- **jmr** — the per-participant multitrack audio recorder + the `split-tracks.sh`
  finalize mount.

## Applying it

The override is **not** auto-loaded. With explicit `-f` flags it must be listed
explicitly, and **after** the base files so it wins:

```bash
docker compose -f docker-compose.yml -f jibri.yml \
               -f docker-compose.override.yml up -d
```

## Placeholders to adapt

- `proxy` — name of your external reverse-proxy network.
- `/srv/jitsi-recordings` — host recordings root (any path).
- `<RECORDINGS_GID>` — gid that owns the recordings tree (see ownership caveats in
  [`../README.md`](../README.md)).
