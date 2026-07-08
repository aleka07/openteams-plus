# recfront

Recordings web front (Filebrowser). See [`../README.md`](../README.md) §4.8 for the
full install flow.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Filebrowser container serving the recordings tree read-only. |
| `.gitignore` | Excludes the runtime state (`data/`, `config/`) — the user DB holds password hashes. |

## What it is

A single `filebrowser/filebrowser` container that serves `/srv/jitsi-recordings`
**read-only** (`:/srv:ro`): browse folders, stream the combined mp4 in-browser,
download the per-speaker OGG/Opus tracks and json. It joins the shared reverse-proxy
network under the alias `recfront`, so a containerized proxy reaches it in-network
(see [`../caddy/Caddyfile.example`](../caddy/Caddyfile.example)); the loopback port
`127.0.0.1:13200` is for local debugging only.

Run it as its own stack next to the jitsi stack:

```bash
cd recfront && docker compose up -d
```

## Notes

- **Change the default admin.** First run creates `./data/filebrowser.db` with a
  default `admin`/`admin` login. Filebrowser's login is the only auth in front of
  every recording — log in once and change the password immediately.
- **Hide service dirs.** Add per-user Filebrowser rules for `/_bin`, `/_status`,
  `/_multitrack/_meta` so the internal dirs drop out of listings, search and
  downloads. See [`../README.md`](../README.md) §4.8 for the Web-UI and CLI ways to
  add them (a non-regex rule is a prefix match).

## Placeholders to adapt

- `proxy` — rename to your external reverse-proxy network (or
  `docker network create proxy`).
- `/srv/jitsi-recordings` — host recordings root, must match the jibri/jmr mounts.
