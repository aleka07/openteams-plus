local LOGLEVEL = "info"

local util = module:require 'util';
local is_admin = util.is_admin;
local is_feature_allowed = util.is_feature_allowed;
local is_healthcheck_room = util.is_healthcheck_room
local timer = require "util.timer"
local st = require "util.stanza"
local uuid = require "util.uuid".generate

-- Env toggles (read once at module load; changing them needs a prosody restart).
--   AUTOSTART_JIBRI=1      auto-start the combined jibri video recording (mp4)
--   AUTOSTART_MULTITRACK=1 auto-enable per-participant audio export to JMR
-- Both default to "1" (the original behaviour). With AUTOSTART_JIBRI=0 the manual
-- record button in the UI still works - only the automatic start is skipped.
local AUTOSTART_JIBRI = (os.getenv("AUTOSTART_JIBRI") or "1") == "1"
local AUTOSTART_MULTITRACK = (os.getenv("AUTOSTART_MULTITRACK") or "1") == "1"

module:log(LOGLEVEL, "loaded (autostart_jibri=%s, autostart_multitrack=%s)",
    tostring(AUTOSTART_JIBRI), tostring(AUTOSTART_MULTITRACK))

-- -----------------------------------------------------------------------------
-- Phase 3: enable per-participant multitrack (backend/async) audio recording (JMR).
-- Jicofo (ChatRoomImpl.doSetRoomMetadata, build 1183) fires transcribingEnabledChanged(true) only when
-- BOTH recording.isTranscribingEnabled AND top-level asyncTranscription are true. That then triggers
-- setTranscriberUrl -> Colibri2 connect -> JVB exports media-json to ws://jmr:8989/record/<MEETING_ID>.
-- If no bridge session exists yet jicofo remembers the flags and connects once one is created,
-- so it is safe to set them before the conference has media.
local function _enable_multitrack(room)
    pcall(function()
        room.jitsiMetadata = room.jitsiMetadata or {}
        room.jitsiMetadata.recording = room.jitsiMetadata.recording or {}
        if room.jitsiMetadata.recording.isTranscribingEnabled ~= true
            or room.jitsiMetadata.asyncTranscription ~= true then
            room.jitsiMetadata.recording.isTranscribingEnabled = true
            room.jitsiMetadata.asyncTranscription = true
            module:fire_event("room-metadata-changed", { room = room })
            module:log(LOGLEVEL, "phase3: multitrack audio export enabled for %s", room.jid)
        end
    end)
end

-- -----------------------------------------------------------------------------
local function _start_recording(room, session, occupant_jid)
    -- dont start recording if already triggered
    if room.is_recorder_triggered then
        return
    end

    -- get occupant current status
    local occupant = room:get_occupant_by_real_jid(occupant_jid)

    -- check recording permission
    local is_recording_allowed = is_feature_allowed(
      "recording",
      session.jitsi_meet_context_features,
      session.granted_jitsi_meet_context_features,
      occupant.role == "moderator"
    )

    -- if not allowed, skip.
    if not is_recording_allowed then
        return
    end

    if AUTOSTART_JIBRI then
        -- start the combined jibri video recording
        local iq = st.iq({
            type = "set",
            id = uuid() .. ":sendIQ",
            from = occupant_jid,
            to = room.jid .. "/focus"
            })
            :tag("jibri", {
                xmlns = "http://jitsi.org/protocol/jibri",
                action = "start",
                recording_mode = "file",
                app_data = '{"file_recording_metadata":{"share":true}}'})

        module:send(iq)
    end
    room.is_recorder_triggered = true

    if AUTOSTART_MULTITRACK then
        -- Guarded (pcall) so it can never interfere with the (already-sent) jibri recording IQ.
        _enable_multitrack(room)
    end
end

-- -----------------------------------------------------------------------------
if AUTOSTART_JIBRI or AUTOSTART_MULTITRACK then
    module:hook("muc-occupant-joined", function (event)
        local room = event.room
        local session = event.origin
        local occupant = event.occupant

        if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
            return
        end

        -- wait for the affiliation to set then start recording if applicable
        timer.add_task(3, function()
            _start_recording(room, session, occupant.jid)
        end)
    end)
end
