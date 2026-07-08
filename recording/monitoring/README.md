# monitoring

Host-side health snapshot (Phase 5). See [`../README.md`](../README.md) §4.9 for
the full install flow.

## Files

| File | Purpose |
|------|---------|
| `check-health.sh` | Collects a health snapshot of the recording stack. |
| `cron.example` | User crontab line running the check every 10 minutes. |

## check-health.sh

Every run atomically writes `$STATUS_DIR/status.json` and appends one line to
`$STATUS_DIR/health.log` (both under `$ROOT/_status/`, trimmed to 5000 lines).

Collected:

- each matching container (`jitsi|jmr|recfront`): name, `State.Status`,
  `Health.Status` (via `docker inspect`).
- Jibri: `docker exec` curl to its `/jibri/api/v1.0/health` endpoint (raw JSON).
- JMR: `docker exec` curl to `/metrics` -> `up`/`down`/`unknown`.
- disk: `df -P $ROOT` -> use% + available KB.
- counts: video sessions + audio dirs created in the last 24h.

Top-level `"ok"` is `false` if any container is not running/unhealthy, Jibri is
unreachable, or disk use is >90%. **No alerting** — it only refreshes the snapshot.
**Always exits 0.**

## Install

Runs from a plain **user cron**; the user must be in the `docker` group (needs
`docker inspect`/`exec`, no sudo). Install the script into the recordings `_bin/`
and add the cron line:

```bash
sudo install -m 0755 check-health.sh /srv/jitsi-recordings/_bin/
crontab -l 2>/dev/null | { cat; cat cron.example; } | crontab -
```
