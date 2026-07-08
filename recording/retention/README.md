# retention

Host-side retention sweep (Phase 5). See [`../README.md`](../README.md) §4.9 for
the full install flow.

## Files

| File | Purpose |
|------|---------|
| `cleanup-recordings.sh` | Deletes recordings past their class retention window. |
| `retention.conf.example` | Optional config overriding the baked-in retention defaults. |
| `cron.example` | `/etc/cron.d` drop-in running the sweep daily at 04:30 as root. |

## cleanup-recordings.sh

Prunes two classes independently:

- **video** — `$ROOT/<room>/<ts>/` (Jibri combined mp4 dirs), default 14 days; then
  removes now-empty room dirs.
- **audio** — `$ROOT/_multitrack/<dir>/` (JMR tracks + `meeting.json`) and the aged
  `_multitrack/_meta/*.json` participants journal, default 365 days.

A class with `*_RETENTION_DAYS <= 0` is kept forever (`0` = never delete). Refuses
to run unless `$ROOT/_multitrack` exists (guards against a mispointed `$ROOT`).

`--dry-run` prints what would be deleted and deletes nothing. Every run logs
ISO-timestamped lines to `$ROOT/_status/cleanup.log` (trimmed to 5000 lines).

**Runs as root** because it must delete Jibri's uid-999-owned session dirs — an
unprivileged user cannot remove them. Hence the `/etc/cron.d` drop-in, not a user
crontab.

## Install

```bash
sudo install -m 0755 cleanup-recordings.sh /srv/jitsi-recordings/_bin/
# optional overrides (defaults are baked into the script):
sudo install -m 0644 retention.conf.example /srv/jitsi-recordings/_bin/retention.conf
# root cron for the daily sweep:
sudo install -m 0644 cron.example /etc/cron.d/jitsi-recordings-retention

# verify before trusting it:
sudo /srv/jitsi-recordings/_bin/cleanup-recordings.sh --dry-run
```
