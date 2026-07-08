#!/bin/bash
# check-health.sh  (OpenTeams+ Phase 5)
#
# Host-side health snapshot for the recording stack, run from a plain user cron
# (user must be in the docker group; no sudo, no alerting). Every run atomically
# writes $STATUS_DIR/status.json and appends one line to $STATUS_DIR/health.log.
#
# Collected:
#   - each matching container: name, State.Status, Health.Status (docker inspect)
#   - Jibri:  docker exec <jibri> curl .../jibri/api/v1.0/health  (raw JSON)
#   - JMR:    docker exec <jmr>   curl .../metrics -> up/down/unknown
#   - disk:   df -P $ROOT -> use% + avail
#   - counts: video sessions + audio dirs created in the last 24h
#
# Top-level "ok" is false if any container is not running / unhealthy, Jibri is
# unreachable, or disk use is >90%. Always exits 0.

set -u

# ---- config ------------------------------------------------------------------
ROOT="/srv/jitsi-recordings"
STATUS_DIR="$ROOT/_status"
CONTAINER_MATCH='jitsi|jmr|recfront'

mkdir -p "$STATUS_DIR" 2>/dev/null || true

GEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- helpers -----------------------------------------------------------------
# first container id whose name matches a regex (empty if none)
find_container() {
    docker ps --filter "name=$1" --format '{{.Names}}' 2>/dev/null | head -n1
}

# ---- containers --------------------------------------------------------------
# one "name\tstatus\thealth" line per matching container; health="" if none.
containers_tsv=""
overall_ok=1

while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    cstate="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)"
    chealth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cname" 2>/dev/null)"
    [[ -z "$cstate" ]] && cstate="unknown"
    containers_tsv+="${cname}"$'\t'"${cstate}"$'\t'"${chealth}"$'\n'
    [[ "$cstate" != "running" ]] && overall_ok=0
    [[ -n "$chealth" && "$chealth" != "healthy" && "$chealth" != "starting" ]] && overall_ok=0
done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "$CONTAINER_MATCH")

# ---- Jibri health ------------------------------------------------------------
jibri_c="$(find_container jibri)"
jibri_health='unreachable'
if [[ -n "$jibri_c" ]]; then
    raw="$(docker exec "$jibri_c" curl -sf \
            http://localhost:2222/jibri/api/v1.0/health 2>/dev/null)"
    if [[ -n "$raw" ]]; then
        jibri_health="$raw"
    else
        overall_ok=0
    fi
else
    overall_ok=0
fi

# ---- JMR metrics -------------------------------------------------------------
jmr_c="$(find_container jmr)"
jmr_metrics='unknown'
if [[ -n "$jmr_c" ]]; then
    code="$(docker exec "$jmr_c" curl -sf -o /dev/null -w '%{http_code}' \
            http://localhost:8989/metrics 2>/dev/null)"
    if [[ -z "$code" ]]; then
        # no curl in image? try wget
        if docker exec "$jmr_c" wget -q -O /dev/null \
               http://localhost:8989/metrics 2>/dev/null; then
            jmr_metrics='up'
        else
            jmr_metrics='unknown'
        fi
    elif [[ "$code" == "200" ]]; then
        jmr_metrics='up'
    else
        jmr_metrics='down'
    fi
fi

# ---- disk --------------------------------------------------------------------
disk_use=0
disk_avail=''
read -r disk_use disk_avail < <(
    df -P "$ROOT" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5, $4}'
)
[[ -z "$disk_use" ]] && disk_use=0
[[ "$disk_use" -gt 90 ]] && overall_ok=0

# ---- 24h counts --------------------------------------------------------------
video_24h="$(find "$ROOT" -mindepth 2 -maxdepth 2 -type d \
                ! -path "$ROOT/_*/*" -mtime -1 2>/dev/null | wc -l | tr -d ' ')"
audio_24h="$(find "$ROOT/_multitrack" -mindepth 1 -maxdepth 1 -type d ! -name '_meta' \
                -mtime -1 2>/dev/null | wc -l | tr -d ' ')"

# ---- render JSON via python3 (data passed through env, no manual escaping) ----
TMP="$(mktemp "${STATUS_DIR}/.status.json.XXXXXX")" || TMP="$STATUS_DIR/.status.json.$$"

H_GEN="$GEN" \
H_OK="$overall_ok" \
H_CONTAINERS="$containers_tsv" \
H_JIBRI="$jibri_health" \
H_JMR="$jmr_metrics" \
H_DISK_USE="$disk_use" \
H_DISK_AVAIL="$disk_avail" \
H_VIDEO24="$video_24h" \
H_AUDIO24="$audio_24h" \
python3 - > "$TMP" <<'PY'
import json, os

def parse_jibri(raw):
    raw = raw.strip()
    if raw in ("", "unreachable"):
        return "unreachable"
    try:
        return json.loads(raw)
    except Exception:
        return raw

containers = []
for line in os.environ.get("H_CONTAINERS", "").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    name = parts[0] if len(parts) > 0 else ""
    status = parts[1] if len(parts) > 1 else "unknown"
    health = parts[2] if len(parts) > 2 else ""
    entry = {"name": name, "status": status}
    if health:
        entry["health"] = health
    containers.append(entry)

def to_int(v, d=0):
    try:
        return int(v)
    except Exception:
        return d

out = {
    "generatedAt": os.environ.get("H_GEN", ""),
    "ok": os.environ.get("H_OK", "0") == "1",
    "containers": containers,
    "jibri": parse_jibri(os.environ.get("H_JIBRI", "unreachable")),
    "jmrMetrics": os.environ.get("H_JMR", "unknown"),
    "disk": {
        "usePercent": to_int(os.environ.get("H_DISK_USE", "0")),
        "availKb": to_int(os.environ.get("H_DISK_AVAIL", "0")),
    },
    "counts24h": {
        "videoSessions": to_int(os.environ.get("H_VIDEO24", "0")),
        "audioDirs": to_int(os.environ.get("H_AUDIO24", "0")),
    },
}
print(json.dumps(out, indent=2, ensure_ascii=False))
PY

if [[ -s "$TMP" ]]; then
    mv "$TMP" "$STATUS_DIR/status.json"
else
    rm -f "$TMP"
fi

# ---- append one-line summary to health.log (trim to 5000 lines) --------------
LOG="$STATUS_DIR/health.log"
ok_str='ok'; [[ "$overall_ok" -ne 1 ]] && ok_str='DEGRADED'
printf '%s %s disk=%s%% avail=%sKB jmr=%s video24h=%s audio24h=%s\n' \
    "$GEN" "$ok_str" "$disk_use" "${disk_avail:-?}" "$jmr_metrics" \
    "$video_24h" "$audio_24h" >> "$LOG"

if [[ -f "$LOG" ]]; then
    tmp="$(mktemp "${LOG}.XXXXXX")" && {
        tail -n 5000 "$LOG" > "$tmp" && mv "$tmp" "$LOG" || rm -f "$tmp"
    }
fi

exit 0
