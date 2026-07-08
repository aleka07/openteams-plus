# prosody-plugins-custom

Custom Prosody modules for the recording module, loaded under the conference MUC
component. See [`../README.md`](../README.md) for the full install flow.

## Files

| File | Purpose |
|------|---------|
| `mod_jibri_autostart.lua` | Auto-starts recording when the first authorized participant joins. |
| `mod_participant_log.lua` | Writes a live participants journal per meeting, keyed by `meetingId`. |

## mod_jibri_autostart.lua

On `muc-occupant-joined` (skipping healthcheck rooms and admins) it waits ~3s for
affiliation to settle, checks the `recording` feature permission, then sends the
same Jibri `start` IQ the "Start recording" UI button would (Jitsi has no upstream
auto-record option — jicofo #344). It also enables the JMR multitrack audio export
by setting the room metadata.

**Critical: it sets BOTH `recording.isTranscribingEnabled` AND top-level
`asyncTranscription` to `true`.** jicofo (build 1183) starts the multitrack export
only when both are set — setting only one is a silent no-op (no error, no export).
Do not remove either flag. See the Gotchas section of [`../README.md`](../README.md).

## mod_participant_log.lua

Hooks join / presence / leave / room-destroy and atomically (tmp+rename) writes
`<meetingId>.json` — `{ meeting_id, room, participants[] }` with per-participant
`endpointId`, `displayName`, `jid`, `joinedAt`, `leftAt`. Service occupants (focus,
jibri, transcriber, admin, healthcheck) are filtered out. The splitter
(`../jmr/split-tracks.sh`) uses this file to join speaker names to audio tracks;
without it, tracks fall back to `endpointId` names.

Output dir comes from `participant_log_dir` / `$PARTICIPANT_LOG_DIR`, default
`/meta`. Prosody runs as uid 100, so that host dir must be writable by uid 100.

## Install

```bash
cp *.lua $CONFIG/prosody/prosody-plugins-custom/
```

Enable via `.env`:

```
XMPP_MUC_MODULES=jibri_autostart,participant_log
```
