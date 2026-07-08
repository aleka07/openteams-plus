#!/bin/bash
# cleanup-recordings.sh  (OpenTeams+ Phase 5)
#
# Host-side retention sweep for the recordings tree, run from a root cron (see
# cron.example). Deletes recordings older than their class retention:
#   - video sessions : $ROOT/<room>/<ts>/         (Jibri combined mp4 dirs)
#   - audio meetings : $ROOT/_multitrack/<dir>/    (JMR tracks + meeting.json)
#                    + $ROOT/_multitrack/_meta/*.json  (participants journal)
#
# Config defaults below; override via $ROOT/_bin/retention.conf (see
# retention.conf.example). A class with *_RETENTION_DAYS <= 0 is kept forever.
#
# Usage:
#   cleanup-recordings.sh [--dry-run]
#     --dry-run   print what would be deleted, delete nothing.
#
# Logs ISO-timestamped lines to $ROOT/_status/cleanup.log (trimmed to 5000 lines).

set -u

# ---- config (defaults; retention.conf may override) --------------------------
ROOT="/srv/jitsi-recordings"
VIDEO_RETENTION_DAYS=14
AUDIO_RETENTION_DAYS=365

CONF="$ROOT/_bin/retention.conf"
[[ -f "$CONF" ]] && . "$CONF"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "unknown arg: $arg" >&2; echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
    esac
done

# ---- safety ------------------------------------------------------------------
if [[ ! -d "$ROOT" ]]; then
    echo "cleanup-recordings: ROOT is not a directory: $ROOT" >&2
    exit 1
fi
if [[ ! -d "$ROOT/_multitrack" ]]; then
    echo "cleanup-recordings: refusing to run, no _multitrack under $ROOT (not a recordings tree?)" >&2
    exit 1
fi

STATUS_DIR="$ROOT/_status"
LOG="$STATUS_DIR/cleanup.log"
mkdir -p "$STATUS_DIR"

log() {
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "$LOG"
}

del_video=0
del_audio=0
del_meta=0
del_rooms=0
freed_bytes=0

# du -s in bytes of a path (0 on any error); used for freed-space accounting.
size_of() {
    local kb
    kb="$(du -s -k "$1" 2>/dev/null | awk '{print $1*1024}')"
    echo "${kb:-0}"
}

remove_path() {
    # $1 = path, $2 = class label (for logging)
    local p="$1" label="$2" sz
    sz="$(size_of "$p")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY would remove $label: $p (${sz} bytes)"
        return 0
    fi
    if rm -rf -- "$p"; then
        freed_bytes=$((freed_bytes + sz))
        log "removed $label: $p (${sz} bytes)"
        return 0
    fi
    log "WARN failed to remove $label: $p"
    return 1
}

log "cleanup start (dry_run=$DRY_RUN video=${VIDEO_RETENTION_DAYS}d audio=${AUDIO_RETENTION_DAYS}d root=$ROOT)"

# ---- video sessions: $ROOT/<room>/<ts>/ , <room> not starting with _ ----------
if [[ "$VIDEO_RETENTION_DAYS" -gt 0 ]]; then
    while IFS= read -r -d '' d; do
        remove_path "$d" video && del_video=$((del_video + 1))
    done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -type d \
                 ! -path "$ROOT/_*/*" \
                 -mtime +"$VIDEO_RETENTION_DAYS" -print0 2>/dev/null)

    # prune now-empty room dirs (never the _* service dirs, only if truly empty)
    while IFS= read -r -d '' r; do
        # empty = no entries at all
        if [[ -z "$(find "$r" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY would remove empty room dir: $r"; del_rooms=$((del_rooms + 1))
            else
                rmdir "$r" 2>/dev/null && { log "removed empty room dir: $r"; del_rooms=$((del_rooms + 1)); }
            fi
        fi
    done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '_*' -print0 2>/dev/null)
else
    log "video retention disabled (VIDEO_RETENTION_DAYS<=0), skipping video"
fi

# ---- audio meetings: $ROOT/_multitrack/<dir>/ , not _meta --------------------
if [[ "$AUDIO_RETENTION_DAYS" -gt 0 ]]; then
    while IFS= read -r -d '' d; do
        remove_path "$d" audio && del_audio=$((del_audio + 1))
    done < <(find "$ROOT/_multitrack" -mindepth 1 -maxdepth 1 -type d ! -name '_meta' \
                 -mtime +"$AUDIO_RETENTION_DAYS" -print0 2>/dev/null)

    # participants journal files aged out
    if [[ -d "$ROOT/_multitrack/_meta" ]]; then
        while IFS= read -r -d '' f; do
            local_sz="$(size_of "$f")"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY would remove meta: $f (${local_sz} bytes)"
                del_meta=$((del_meta + 1))
            elif rm -f -- "$f"; then
                freed_bytes=$((freed_bytes + local_sz))
                log "removed meta: $f (${local_sz} bytes)"
                del_meta=$((del_meta + 1))
            else
                log "WARN failed to remove meta: $f"
            fi
        done < <(find "$ROOT/_multitrack/_meta" -mindepth 1 -maxdepth 1 -type f -name '*.json' \
                     -mtime +"$AUDIO_RETENTION_DAYS" -print0 2>/dev/null)
    fi
else
    log "audio retention disabled (AUDIO_RETENTION_DAYS<=0), skipping audio"
fi

log "cleanup done: video=$del_video audio=$del_audio meta=$del_meta empty_rooms=$del_rooms freed=${freed_bytes} bytes dry_run=$DRY_RUN"

# ---- trim log to last 5000 lines --------------------------------------------
if [[ -f "$LOG" ]]; then
    tmp="$(mktemp "${LOG}.XXXXXX")" && {
        tail -n 5000 "$LOG" > "$tmp" && mv "$tmp" "$LOG" || rm -f "$tmp"
    }
fi

exit 0
