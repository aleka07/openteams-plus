#!/bin/bash
# split-tracks.sh  (OpenTeams+ Phase 4)
#
# JMR finalize-script: turns a per-meeting multitrack recording.mka into one named
# OGG/Opus track per speaker, each aligned to the common meeting timeline
# (t=0 = recording start). Tracks are re-encoded to Opus (~64 kbps VoIP) — small and
# STT-friendly. As a last step it renames the meeting dir to <start>_<room> (the uuid
# lives on inside meeting.json for correlation).
#
# Invoked by JMR as:   split-tracks.sh <MEETING_ID> <DIR> <FORMAT>
#   $1 MEETING_ID : jicofo/prosody meetingId (also the participants.json key)
#   $2 DIR        : the meeting's recording dir (contains recording.mka)
#   $3 FORMAT     : "MKA" (uppercase)
#
# Runs inside jitsi/jitsi-multitrack-recorder (Debian 12, root). Deps present in the
# image: ffmpeg, ffprobe, jq, awk, bash. Names come from participants.json written by
# prosody mod_participant_log into the sibling _meta staging dir; if it is missing the
# script degrades gracefully to endpointId names.
#
# Outputs, under $DIR:
#   tracks/<NN>_<name>.ogg   one Opus track per audio track
#   meeting.json             summary (participants + tracks)

set -uo pipefail

MEETING_ID="${1:-}"
DIR="${2:-}"
FORMAT="${3:-MKA}"

if [[ -z "$MEETING_ID" || -z "$DIR" ]]; then
    echo "usage: $0 <MEETING_ID> <DIR> <FORMAT>" >&2
    exit 2
fi

MKA="$DIR/recording.mka"
if [[ ! -f "$MKA" ]]; then
    echo "[split-tracks] no recording.mka in $DIR - nothing to do" >&2
    exit 0
fi

# participants.json staging dir is a sibling of the meeting dir: <root>/_meta/<id>.json
META_DIR="$(dirname "$DIR")/_meta"
PJSON="$META_DIR/$MEETING_ID.json"

PART_JSON='null'
if [[ -f "$PJSON" ]]; then
    PART_JSON="$(cat "$PJSON")"
    echo "[split-tracks] using participants: $PJSON" >&2
else
    echo "[split-tracks] no participants.json ($PJSON) - falling back to endpointId names" >&2
fi

OUTDIR="$DIR/tracks"
mkdir -p "$OUTDIR"

# Filesystem-safe name: keep unicode letters, replace path/shell-hostile chars and
# whitespace with '_', collapse repeats, trim, cap length.
sanitize() {
    printf '%s' "$1" \
        | tr -d '\000-\037' \
        | sed -e 's#[/\\:*?"<>|]#_#g' \
              -e 's/[[:space:]]\{1,\}/_/g' \
              -e 's/_\{1,\}/_/g' \
              -e 's/^[._]\{1,\}//' \
              -e 's/[._]\{1,\}$//' \
        | cut -c1-64
}

lookup_name() {
    # $1 = endpointId -> displayName (or empty)
    [[ "$PART_JSON" == "null" ]] && return 0
    printf '%s' "$PART_JSON" \
        | jq -r --arg eid "$1" '(.participants // [])[] | select(.endpointId==$eid) | .displayName // empty' 2>/dev/null \
        | head -n1
}

probe="$(ffprobe -v quiet -print_format json -show_streams -select_streams a \
    -analyzeduration 9223372036854775807 "$MKA")"

n="$(printf '%s' "$probe" | jq '.streams | length')"
if [[ -z "$n" || "$n" -eq 0 ]]; then
    echo "[split-tracks] no audio streams in $MKA" >&2
    exit 0
fi

declare -A used
tracks_json='[]'

for ((ai = 0; ai < n; ai++)); do
    start_time="$(printf '%s' "$probe" | jq -r ".streams[$ai].start_time // \"0\"")"
    eid="$(printf '%s' "$probe" | jq -r ".streams[$ai].tags.endpoint_id // empty")"
    title="$(printf '%s' "$probe" | jq -r ".streams[$ai].tags.title // empty")"
    if [[ -z "$eid" && -n "$title" ]]; then eid="${title%%-*}"; fi
    [[ -z "$eid" ]] && eid="track$ai"

    dn="$(lookup_name "$eid")"
    base="$(sanitize "${dn:-$eid}")"
    [[ -z "$base" ]] && base="$eid"

    name="$base"; k=2
    while [[ -n "${used[$name]:-}" ]]; do name="${base}_${k}"; k=$((k + 1)); done
    used[$name]=1

    nn="$(printf '%02d' $((ai + 1)))"
    out="$OUTDIR/${nn}_${name}.ogg"

    # ms offset that aligns this track to the common meeting timeline
    delay="$(printf '%s\n' "$start_time" | awk '{printf "%d", ($1*1000)+0.5}')"
    [[ "$delay" -lt 0 ]] && delay=0

    echo "[split-tracks] a:$ai eid=$eid name=$name start=${start_time}s delay=${delay}ms -> $out" >&2

    # Always re-encode to Opus (~64 kbps VoIP); channel layout kept as-is.
    if [[ "$delay" -eq 0 ]]; then
        ffmpeg -hide_banner -loglevel error -y -i "$MKA" \
            -map "0:a:$ai" -c:a libopus -b:a 64k -vbr on -application voip "$out" \
            || { echo "[split-tracks] WARN ffmpeg failed for a:$ai" >&2; continue; }
    else
        ffmpeg -hide_banner -loglevel error -y -i "$MKA" \
            -filter_complex "[0:a:$ai]adelay=${delay}:all=1[a]" -map "[a]" \
            -c:a libopus -b:a 64k -vbr on -application voip "$out" \
            || { echo "[split-tracks] WARN ffmpeg failed for a:$ai" >&2; continue; }
    fi

    part="$(printf '%s' "$PART_JSON" | jq -c --arg eid "$eid" '(.participants // [])[] | select(.endpointId==$eid)' 2>/dev/null | head -n1)"
    [[ -z "$part" ]] && part='null'
    entry="$(jq -n \
        --arg file "tracks/${nn}_${name}.ogg" \
        --arg eid "$eid" \
        --arg dn "${dn:-}" \
        --arg st "$start_time" \
        --argjson part "$part" \
        '{file:$file, endpointId:$eid, displayName:$dn, startOffsetSec:($st|tonumber), participant:$part}')"
    tracks_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$tracks_json")"
done

dur="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$MKA" 2>/dev/null)"
[[ -z "$dur" ]] && dur=0

printf '%s' "$PART_JSON" | jq \
    --arg mid "$MEETING_ID" \
    --arg mka "recording.mka" \
    --arg dur "$dur" \
    --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson tracks "$tracks_json" \
    '{meeting_id:$mid,
      room: ((.room // "") // ""),
      source: $mka,
      durationSec: ($dur|tonumber),
      generatedAt: $gen,
      participants: ((.participants) // []),
      tracks: $tracks}' \
    > "$DIR/meeting.json"

echo "[split-tracks] done: $(find "$OUTDIR" -maxdepth 1 -name '*.ogg' | wc -l | tr -d ' ') track(s) in $OUTDIR" >&2

# --- best-effort: rename meeting dir to <YYYY-MM-DD_HHMMSS>_<room> (sibling of $DIR) --
# Purely cosmetic: the uuid stays inside meeting.json (meeting_id) for correlation, so
# any failure here must NOT fail the (already successful) split. WARN + exit 0.
rename_meeting_dir() {
    [[ -d "$DIR" ]] || { echo "[split-tracks] WARN dir gone, skip rename: $DIR" >&2; return 0; }

    # room: participants.json .room, strip any @-part, sanitize; fall back to id[:8].
    local room
    room="$(printf '%s' "$PART_JSON" | jq -r '(.room // "") | tostring' 2>/dev/null)"
    room="${room%%@*}"
    room="$(sanitize "$room")"
    [[ -z "$room" ]] && room="$(printf '%s' "$MEETING_ID" | cut -c1-8)"

    # meeting start = now - durationSec, local TZ (Asia/Almaty in the container).
    # Guard empty / non-integer dur; fall back to now on any date error.
    local secs start
    secs="${dur%.*}"
    [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
    start="$(date -d "@$(( $(date +%s) - secs ))" +%Y-%m-%d_%H%M%S 2>/dev/null)"
    [[ -z "$start" ]] && start="$(date +%Y-%m-%d_%H%M%S)"

    local parent base target k
    parent="$(dirname "$DIR")"
    if [[ -z "$parent" || "$parent" == "$DIR" ]]; then
        echo "[split-tracks] WARN cannot compute rename target for $DIR" >&2
        return 0
    fi
    base="${start}_${room}"
    target="$parent/$base"

    # collision -> _2, _3 ...
    k=2
    while [[ -e "$target" && "$target" != "$DIR" ]]; do
        target="$parent/${base}_${k}"; k=$((k + 1))
    done
    [[ "$target" == "$DIR" ]] && return 0

    if mv "$DIR" "$target"; then
        echo "[split-tracks] renamed $DIR -> $target" >&2
    else
        echo "[split-tracks] WARN rename failed: $DIR -> $target" >&2
    fi
    return 0
}
rename_meeting_dir
exit 0
