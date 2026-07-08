-- mod_participant_log.lua  (OpenTeams+ Phase 4)
-- Load under the conference MUC component (via XMPP_MUC_MODULES).
--
-- Writes a live participants.json for every real meeting into a staging dir that
-- is shared with the JMR multitrack recorder, keyed by the room's meetingId so
-- the Phase-4 splitter can join names to the recorded audio tracks.
--
-- Output (atomic tmp+rename, on every join / name-change / leave / room-destroy):
--   <participant_log_dir>/<meetingId>.json
--   {
--     "meeting_id": "<uuid>",
--     "room": "<room node>",
--     "participants": [
--       { "endpointId","displayName","jid","joinedAt","leftAt" }, ...
--     ]
--   }
--
-- The staging dir maps to /srv/jitsi-recordings/_multitrack/_meta on the host,
-- which the JMR container sees as /data/_meta. Prosody runs as uid 100, so that
-- host dir must be writable by uid 100 (see README / compose override).

local jid = require "util.jid";
local json = require "util.json";

local util = module:require "util";
local is_admin          = util.is_admin;
local is_focus          = util.is_focus;
local is_jibri          = util.is_jibri;
local is_transcriber    = util.is_transcriber;
local is_healthcheck_room = util.is_healthcheck_room;

local NICK_NS = "http://jabber.org/protocol/nick";

local OUTPUT_DIR = module:get_option_string("participant_log_dir")
    or os.getenv("PARTICIPANT_LOG_DIR")
    or "/meta";

module:log("info", "participant_log loaded (output dir=%s)", OUTPUT_DIR);

local function now_iso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ");
end

-- Best-effort current display name from the occupant's latest presence.
local function get_display_name(occupant)
    if not occupant or not occupant.get_presence then return nil; end
    local pr = occupant:get_presence();
    if not pr then return nil; end
    local n = pr:get_child_text("nick", NICK_NS);
    if n and n ~= "" then return n; end
    return nil;
end

-- True for anything that is not a real human participant.
local function is_service(room, occupant)
    if is_healthcheck_room(room.jid) then return true; end
    local ok, res;
    ok, res = pcall(is_admin, occupant.bare_jid);      if ok and res then return true; end
    ok, res = pcall(is_focus, occupant.nick);          if ok and res then return true; end
    ok, res = pcall(is_jibri, occupant);               if ok and res then return true; end
    ok, res = pcall(is_transcriber, occupant.jid);     if ok and res then return true; end
    return false;
end

local function endpoint_of(occupant)
    return jid.resource(occupant.nick);
end

-- Atomically (re)write the participants file for a room.
local function write_log(room)
    local log = room._plog;
    if not log then return; end
    local mid = room._data and room._data.meetingId;
    if not mid or mid == "" then
        module:log("warn", "participant_log: room %s has no meetingId yet, skipping write", room.jid);
        return;
    end

    local participants = {};
    for _, eid in ipairs(log.order) do
        participants[#participants + 1] = log.byId[eid];
    end

    local payload = {
        meeting_id = mid,
        room = jid.node(room.jid),
        participants = participants,
    };

    local body = json.encode(payload);
    if not body then
        module:log("error", "participant_log: json encode failed for %s", room.jid);
        return;
    end

    local path = OUTPUT_DIR .. "/" .. mid .. ".json";
    local tmp  = OUTPUT_DIR .. "/." .. mid .. ".json.tmp";
    local f, err = io.open(tmp, "w");
    if not f then
        module:log("error", "participant_log: cannot open %s: %s", tmp, tostring(err));
        return;
    end
    f:write(body);
    f:close();
    local ok, rerr = os.rename(tmp, path);
    if not ok then
        module:log("error", "participant_log: rename %s -> %s failed: %s", tmp, path, tostring(rerr));
        os.remove(tmp);
        return;
    end
    module:log("debug", "participant_log: wrote %s (%d participants)", path, #participants);
end

module:hook("muc-occupant-joined", function(event)
    local room, occupant = event.room, event.occupant;
    if is_service(room, occupant) then return; end
    local eid = endpoint_of(occupant);
    if not eid then return; end

    room._plog = room._plog or { order = {}, byId = {} };
    if not room._plog.byId[eid] then
        room._plog.order[#room._plog.order + 1] = eid;
        room._plog.byId[eid] = {
            endpointId  = eid,
            displayName = get_display_name(occupant),  -- may be nil at join; refreshed by presence
            jid         = occupant.bare_jid,
            joinedAt    = now_iso(),
            -- leftAt filled on leave / room-destroy
        };
        write_log(room);
    end
end);

-- Display name is usually set in a presence sent shortly after join; keep it current.
module:hook("muc-broadcast-presence", function(event)
    local room, occupant = event.room, event.occupant;
    if not room._plog or not occupant then return; end
    if is_service(room, occupant) then return; end
    local eid = endpoint_of(occupant);
    local entry = eid and room._plog.byId[eid];
    if not entry then return; end
    local n = get_display_name(occupant);
    if n and n ~= entry.displayName then
        entry.displayName = n;
        write_log(room);
    end
end);

module:hook("muc-occupant-left", function(event)
    local room, occupant = event.room, event.occupant;
    if not room._plog then return; end
    local eid = endpoint_of(occupant);
    local entry = eid and room._plog.byId[eid];
    if not entry then return; end
    if not entry.leftAt then entry.leftAt = now_iso(); end
    write_log(room);
end);

module:hook("muc-room-destroyed", function(event)
    local room = event.room;
    if not room._plog then return; end
    local t = now_iso();
    for _, eid in ipairs(room._plog.order) do
        local e = room._plog.byId[eid];
        if not e.leftAt then e.leftAt = t; end
    end
    write_log(room);
end);
