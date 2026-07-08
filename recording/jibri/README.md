# jibri

Jibri finalize script. See [`../README.md`](../README.md) for the full install flow.

## Files

| File | Purpose |
|------|---------|
| `finalize.sh` | Jibri finalize-script: files the finished recording into the recordings tree. |

## finalize.sh

Runs **inside** the jibri container. Jibri invokes it with the recording session
directory as `$1` when a recording finishes. It takes the newest `.mp4` in that
dir, derives `<room>` from `metadata.json` (`meeting_url`, falling back to the mp4
filename prefix), and moves the file to:

```
/recordings-out/<room>/<YYYY-MM-DD_HHMMSS>/combined/recording.mp4
```

with `metadata.json` copied alongside. Timestamps include seconds to avoid
collisions when the same room is recorded twice within a minute.
`/recordings-out` is a bind mount of the host's `/srv/jitsi-recordings`.

**uid-999 nuance:** Jibri runs as uid 999. The recordings dir it writes to must be
owned `999:<RECORDINGS_GID>` with mode `2775` (setgid), or the `mkdir`/`mv` fails
and the mp4 is stranded in the session dir. See the Gotchas section of
[`../README.md`](../README.md).

## Install

```bash
cp finalize.sh $CONFIG/jibri/finalize.sh
chmod 0755 $CONFIG/jibri/finalize.sh
# .env: JIBRI_FINALIZE_RECORDING_SCRIPT_PATH=/config/finalize.sh
```
