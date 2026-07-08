# jmr

JMR (jitsi-multitrack-recorder) finalize script. See [`../README.md`](../README.md)
for the full install flow and architecture.

## Files

| File | Purpose |
|------|---------|
| `split-tracks.sh` | JMR finalize-script: splits a multitrack `recording.mka` into named per-speaker tracks. |

## split-tracks.sh

Invoked by JMR (via `JMR_FINALIZE_SCRIPT`) on session end as:

```
split-tracks.sh <MEETING_ID> <DIR> <FORMAT>
```

- `<MEETING_ID>` — jicofo/prosody meetingId (also the `participants.json` key).
- `<DIR>` — the meeting's recording dir (contains `recording.mka`).
- `<FORMAT>` — `MKA`.

What it does:

- `ffprobe`s the audio streams of `recording.mka` and re-encodes each to its own
  `tracks/<NN>_<name>.ogg` (Opus, ~64 kbps VoIP — small and STT-friendly).
- Aligns every track to the common meeting timeline (`t=0` = recording start) via
  `adelay` from each stream's `start_time`.
- Resolves speaker names from `participants.json` in the sibling `_meta/` staging
  dir (`<root>/_meta/<MEETING_ID>.json`). **If that file is missing it degrades
  gracefully to `endpointId` names** — the split still succeeds.
- Writes `meeting.json` (participants + tracks summary; the meeting uuid lives on
  in `meeting_id`).
- As a final, best-effort step renames the meeting dir to
  `<YYYY-MM-DD_HHMMSS>_<room>`. Any failure here is a cosmetic WARN and never fails
  the (already-successful) split.

Runs as root inside the `jitsi/jitsi-multitrack-recorder` image; needs no extra
packages (ffmpeg, ffprobe, jq, awk, bash ship in the image).

## Install

Installed on the host under the recordings `_bin/` and bind-mounted into the JMR
container as the finalize script:

```bash
sudo install -m 0755 split-tracks.sh /srv/jitsi-recordings/_bin/split-tracks.sh
```

The compose override mounts it read-only at `/finalize/split-tracks.sh`
(`JMR_FINALIZE_SCRIPT`); see [`../compose/docker-compose.override.yml`](../compose/docker-compose.override.yml).
