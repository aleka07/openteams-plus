#!/bin/bash
# Jibri finalize script (Phase 2, added 2026-07-07; hardened after first live test).
# Runs INSIDE the jibri container. Jibri invokes it with the recording
# session directory as $1. It takes the newest .mp4 in that directory,
# derives the room name from metadata.json (meeting_url), and moves the
# recording to /recordings-out/<room>/<YYYY-MM-DD_HHMM>/combined/recording.mp4
# with metadata.json copied alongside. /recordings-out is a bind mount of
# the host's /srv/jitsi-recordings.
set -uo pipefail

RECORDING_DIR="${1:-}"
OUT_ROOT="/recordings-out"

echo "[finalize] invoked for session dir: ${RECORDING_DIR}"

if [ -z "${RECORDING_DIR}" ] || [ ! -d "${RECORDING_DIR}" ]; then
    echo "[finalize] ERROR: session dir '${RECORDING_DIR}' missing or not a directory"
    exit 1
fi

# newest .mp4 in the session dir
MP4="$(ls -t "${RECORDING_DIR}"/*.mp4 2>/dev/null | head -n1 || true)"
if [ -z "${MP4}" ]; then
    echo "[finalize] ERROR: no .mp4 found in ${RECORDING_DIR}, nothing to finalize"
    exit 0
fi
echo "[finalize] newest mp4: ${MP4}"

META="${RECORDING_DIR}/metadata.json"

# derive <room> from metadata.json meeting_url, fallback to mp4 filename prefix
ROOM=""
if [ -f "${META}" ]; then
    URL="$(grep -oE '"meeting_url"[[:space:]]*:[[:space:]]*"[^"]+"' "${META}" | head -n1 \
        | sed -E 's/.*"meeting_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    echo "[finalize] meeting_url: ${URL:-<none>}"
    # last path segment of the URL, trailing slashes stripped
    ROOM="$(printf '%s' "${URL}" | sed -E 's#/+$##; s#.*/##')"
fi
if [ -z "${ROOM}" ]; then
    BASE="$(basename "${MP4}")"
    # jibri names files like <room>_<timestamp>.mp4 ; take prefix before first '_'
    ROOM="${BASE%%_*}"
    echo "[finalize] fell back to room from filename: ${ROOM}"
fi

# sanitize room for filesystem safety
ROOM="$(printf '%s' "${ROOM}" | tr -c 'A-Za-z0-9._-' '_')"
[ -z "${ROOM}" ] && ROOM="unknown"

STAMP="$(date +%Y-%m-%d_%H%M%S)"
DEST="${OUT_ROOT}/${ROOM}/${STAMP}/combined"

if ! mkdir -p "${DEST}"; then
    echo "[finalize] ERROR: cannot create ${DEST} (check /recordings-out mount and ownership for container uid $(id -u))"
    exit 1
fi

if ! mv "${MP4}" "${DEST}/recording.mp4"; then
    echo "[finalize] ERROR: failed to move ${MP4} -> ${DEST}/recording.mp4 (recording left in session dir)"
    exit 1
fi
echo "[finalize] moved recording -> ${DEST}/recording.mp4"

if [ -f "${META}" ]; then
    if cp "${META}" "${DEST}/metadata.json"; then
        echo "[finalize] copied metadata.json -> ${DEST}/metadata.json"
    else
        echo "[finalize] WARN: failed to copy metadata.json (recording itself is fine)"
    fi
else
    echo "[finalize] WARN: no metadata.json in session dir"
fi

echo "[finalize] done room=${ROOM} stamp=${STAMP}"
exit 0
