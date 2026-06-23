local module_name = "RE_05_haptics"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_05_haptics.lua
-- Controller touch-haptics runtime. Vest/Haptic Feedback placeholders stay optional here.
local haptics = {}

local HapticsGroup = {}
HapticsGroup.__index = HapticsGroup

function HapticsGroup.new(enter, hold, leave, touch_enter, touch_hold, touch_leave)
    return setmetatable({
        -- enter/hold/leave are reserved vest channels. Keeping them nil is safe.
        enter = enter,
        hold = hold,
        leave = leave,
        touchEnter = touch_enter,
        touchHold = touch_hold,
        touchLeave = touch_leave,
    }, HapticsGroup)
end

local TouchHapticsSample = {}
TouchHapticsSample.__index = TouchHapticsSample

local DEFAULT_SAMPLE_DURATION = 0.02

local function clamp01(value)
    local numeric = tonumber(value) or 0.0
    if numeric < 0.0 then
        return 0.0
    end
    if numeric > 1.0 then
        return 1.0
    end
    return numeric
end

local function resolve_duration(value)
    local numeric = tonumber(value) or 0.0
    if numeric > 0.0 then
        return numeric
    end
    return DEFAULT_SAMPLE_DURATION
end

function TouchHapticsSample.new(duration, frequency, amplitude)
    return setmetatable({
        duration = resolve_duration(duration),
        frequency = frequency or 0.0,
        amplitude = clamp01(amplitude),
    }, TouchHapticsSample)
end

local SILENT_SAMPLE = TouchHapticsSample.new(DEFAULT_SAMPLE_DURATION, 1.0, 0.0)

local TouchHaptics = {}
TouchHaptics.__index = TouchHaptics

function TouchHaptics.new(left, samples, name)
    return setmetatable({
        left = left and true or false,
        samples = samples or {},
        name = name,
    }, TouchHaptics)
end

local function new_queue()
    return {
        samples = nil,
        index = 1,
        pending_stop = false,
        source = nil,
    }
end

local function reset_queue(queue)
    queue.samples = nil
    queue.index = 1
    queue.pending_stop = false
    queue.source = nil
end

local function queue_busy(queue)
    return queue.samples ~= nil or queue.pending_stop
end

local function queue_next_sample(queue)
    if queue.samples ~= nil then
        local sample = queue.samples[queue.index]
        if sample ~= nil then
            queue.index = queue.index + 1
            if queue.index > #queue.samples then
                queue.samples = nil
                queue.index = 1
            end
            return sample
        end
        queue.samples = nil
        queue.index = 1
    end

    if queue.pending_stop then
        queue.pending_stop = false
        return SILENT_SAMPLE
    end

    return nil
end

local function publish_last_haptic_source(source)
    if type(source) ~= "table" then
        return
    end

    local gesture_name = source.gestureName or "unknown"
    local pattern_name = source.patternName or "unknown"
    local phase_name = source.phase or "unknown"

    _G.lastGestureHaptic = gesture_name
    _G.lastHapticPatternName = pattern_name
    _G.lastHapticPhase = phase_name
end

local function clear_expired_haptic_playback(now)
    local expires_at = tonumber(rawget(_G, "currentHapticFeedbackExpiresAt")) or 0.0
    if expires_at <= 0.0 or now < expires_at then
        return
    end

    _G.currentHapticFeedbackPatternName = nil
    _G.currentHapticFeedbackGestureName = nil
    _G.currentHapticFeedbackPhaseName = nil
    _G.currentHapticFeedbackLeftHand = nil
    _G.currentHapticFeedbackExpiresAt = 0.0
end

local function mark_haptic_playback(source, duration)
    if type(source) ~= "table" then
        return
    end

    local now = os.clock()
    clear_expired_haptic_playback(now)

    local current_name = rawget(_G, "currentHapticFeedbackPatternName")
    if current_name ~= nil then
        _G.previousHapticFeedbackPatternName = current_name
    else
        _G.previousHapticFeedbackPatternName = rawget(_G, "lastPlayedHapticFeedbackPatternName")
    end

    local pattern_name = tostring(source.patternName or "unknown")
    _G.lastPlayedHapticFeedbackPatternName = pattern_name
    _G.currentHapticFeedbackPatternName = pattern_name
    _G.currentHapticFeedbackGestureName = tostring(source.gestureName or "unknown")
    _G.currentHapticFeedbackPhaseName = tostring(source.phase or "unknown")
    _G.currentHapticFeedbackLeftHand = source.leftHand and true or false
    _G.currentHapticFeedbackExpiresAt = now + math.max(DEFAULT_SAMPLE_DURATION, tonumber(duration) or 0.0)
end

-- Registered tact playback has highest priority: while active, block submit_frame to DLL.
local registered_playback_occupancy = {
    expires_at = 0.0,
}

local function is_registered_playback_occupying(now)
    now = tonumber(now) or os.clock()
    return now < (registered_playback_occupancy.expires_at or 0.0)
end

local function mark_registered_playback_occupancy(duration, now)
    now = tonumber(now) or os.clock()
    local expires_at = now + math.max(0.0, tonumber(duration) or 0.0)
    if expires_at > (registered_playback_occupancy.expires_at or 0.0) then
        registered_playback_occupancy.expires_at = expires_at
    end
end

local function get_haptic_playback_snapshot()
    clear_expired_haptic_playback(os.clock())
    return {
        currentPatternName = rawget(_G, "currentHapticFeedbackPatternName"),
        previousPatternName = rawget(_G, "previousHapticFeedbackPatternName") or rawget(_G, "lastPlayedHapticFeedbackPatternName"),
        currentGestureName = rawget(_G, "currentHapticFeedbackGestureName"),
        currentPhaseName = rawget(_G, "currentHapticFeedbackPhaseName"),
        currentLeftHand = rawget(_G, "currentHapticFeedbackLeftHand"),
        currentExpiresAt = rawget(_G, "currentHapticFeedbackExpiresAt"),
    }
end

local TouchHapticsPlayer = {}
TouchHapticsPlayer.__index = TouchHapticsPlayer

function TouchHapticsPlayer.new(runtime)
    return setmetatable({
        runtime = runtime,
        _left = new_queue(),
        _right = new_queue(),
    }, TouchHapticsPlayer)
end

function TouchHapticsPlayer:setRuntime(runtime)
    self.runtime = runtime
end

function TouchHapticsPlayer:play(pattern, gesture_name, phase_name)
    if type(pattern) ~= "table" or pattern.samples == nil then
        return false
    end

    local queue = pattern.left and self._left or self._right
    -- Match VRCompanion.py: only queue a new pulse after the previous one finished.
    if queue_busy(queue) then
        return false
    end

    queue.samples = pattern.samples
    queue.index = 1
    queue.pending_stop = true
    queue.source = {
        gestureName = gesture_name,
        patternName = pattern.name,
        phase = phase_name,
        leftHand = pattern.left and true or false,
    }
    return true
end

function TouchHapticsPlayer:clear()
    reset_queue(self._left)
    reset_queue(self._right)
end

function TouchHapticsPlayer:update(delta_time)
    local fallback_duration = tonumber(delta_time) or 0.0
    clear_expired_haptic_playback(os.clock())
    local left_sample = queue_next_sample(self._left)
    if left_sample ~= nil and self.runtime and self.runtime.applyTouchHaptics then
        if left_sample ~= SILENT_SAMPLE then
            publish_last_haptic_source(self._left.source)
        end
        self.runtime:applyTouchHaptics(true, left_sample.duration or fallback_duration, left_sample.frequency, left_sample.amplitude)
    end

    local right_sample = queue_next_sample(self._right)
    if right_sample ~= nil and self.runtime and self.runtime.applyTouchHaptics then
        if right_sample ~= SILENT_SAMPLE then
            publish_last_haptic_source(self._right.source)
        end
        self.runtime:applyTouchHaptics(false, right_sample.duration or fallback_duration, right_sample.frequency, right_sample.amplitude)
    end
end

local function append_touch_sample(samples, duration, frequency, amplitude)
    samples[#samples + 1] = TouchHapticsSample.new(duration, frequency, amplitude)
end

function TouchHapticsPlayer:pulse(length, intensity)
    local frequency = 1.0
    local pulse_length = resolve_duration(length)
    local peak_amplitude = clamp01(intensity)
    local count = math.max(1, math.floor((pulse_length / DEFAULT_SAMPLE_DURATION) + 0.5))
    local segment_duration = pulse_length / count
    local ramp_count = 0
    if count >= 3 then
        ramp_count = math.min(2, math.floor((count - 1) / 2))
    end
    local hold_count = math.max(1, count - (ramp_count * 2))
    local samples = {}
    for index = 1, ramp_count do
        append_touch_sample(samples, segment_duration, frequency, peak_amplitude * (index / (ramp_count + 1)))
    end
    for _ = 1, hold_count do
        append_touch_sample(samples, segment_duration, frequency, peak_amplitude)
    end
    for index = ramp_count, 1, -1 do
        append_touch_sample(samples, segment_duration, frequency, peak_amplitude * (index / (ramp_count + 1)))
    end
    return samples
end

function TouchHapticsPlayer:pulseWithPause(length, intensity, pause_length)
    local samples = self:pulse(length, intensity)
    local resolved_pause_length = tonumber(pause_length) or 0.0
    if resolved_pause_length > 0.0 then
        append_touch_sample(samples, resolved_pause_length, 1.0, 0.0)
    end
    return samples
end

local COMPANION_HAPTIC_FEEDBACK_PATTERN_KEYS = {
    "BackpackRetrieveClipLeft_1",
    "BackpackRetrieveClipRight_1",
    "BackpackStoreClipLeft_1",
    "BackpackStoreClipRight_1",
    "Bite_1",
    "Chainsword_L",
    "Cough_1",
    "DamageVestArrow_1",
    "DamageVestArrow_back",
    "DamageVestBluntLightningLarge_1",
    "DamageVestBluntLightningLarge_back",
    "Equip From Left to Left",
    "Equip From Left to Right",
    "Equip From Right to Left",
    "Equip From Right to Right",
    "Explosion_1",
    "Force Pull_L",
    "Force Pull_R",
    "Force Push_L",
    "Force Push_R",
    "GrabbedByBarnacle_1",
    "GreybeardPowerAbsorb_1",
    "HandGrenade_1",
    "HandGrenade_back",
    "Healing_1",
    "HeartBeat_1",
    "HeartBeatFast_1",
    "HealthPenUse_1",
    "HealthStationUse_1",
    "Holster Left",
    "Holster Right",
    "Laser",
    "Light Left",
    "Light Right",
    "MinigunVest_R",
    "PlayerTelekinesisPullRight_1",
    "PlayerTelekinesisRepelRight_1",
    "PoisonDrinking_1",
    "PotionDrinking_1",
    "RecoilMeleeVest_L",
    "RecoilMeleeVest_R",
    "RecoilShotgunVest_R",
    "Shout_1",
    "Shoulder Holster Left",
    "Shoulder Holster Right",
    "Slash Left to Right downward",
    "Slash Left to Right downward back",
    "Slash downward",
    "SlowMotion_1",
    "SoulTrapCaptured_1",
    "Stab back",
    "Stab chest",
    "SwimVest20_1",
    "Voice Feedback",
    "Wind_1",
    "Wind_back",
}

local function get_path_candidates(relative_path)
    local suffix = tostring(relative_path or ""):gsub("\\", "/")
    local candidates = {}

    if suffix ~= "" then
        -- io.open 工作目录是 reframework/data/，需要去掉 "data/" 前缀
        if string.sub(suffix, 1, 5) == "data/" then
            candidates[#candidates + 1] = string.sub(suffix, 6)
        else
            candidates[#candidates + 1] = suffix
        end
    end

    return candidates
end

local function is_blocked_binary_path(path)
    local normalized = tostring(path or ""):gsub("\\", "/"):lower()
    return normalized:match("%.dll$") ~= nil or normalized:match("%.exe$") ~= nil
end

local function safe_io_open(path, mode)
    if is_blocked_binary_path(path) then
        return nil, "io.open blocked for executables or DLLs"
    end

    if type(io) ~= "table" or type(io.open) ~= "function" then
        return nil, "io.open unavailable"
    end

    local ok, file_or_err = pcall(io.open, path, mode)
    if not ok then
        return nil, tostring(file_or_err)
    end

    return file_or_err, nil
end

local function read_all_text(file_path)
    local file = safe_io_open(file_path, "rb")
    if file == nil then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

local function read_first_available_text(paths)
    if type(paths) ~= "table" then
        return nil, nil
    end

    for _, path in ipairs(paths) do
        local content = read_all_text(path)
        if content ~= nil then
            return content, path
        end
    end

    return nil, nil
end

local function find_first_existing_path(paths)
    if type(paths) ~= "table" then
        return nil
    end

    for _, path in ipairs(paths) do
        local file = safe_io_open(path, "rb")
        if file ~= nil then
            file:close()
            return path
        end
    end

    return nil
end

local function append_first_available_line(paths, line)
    if type(paths) ~= "table" then
        return false, "path list missing"
    end

    local last_error = nil
    for _, path in ipairs(paths) do
        local ok, err = pcall(function()
            local file = safe_io_open(path, "ab")
            if file == nil then
                error("io.open failed for " .. tostring(path))
            end

            file:write(line, "\n")
            file:close()
        end)

        if ok then
            return true, path
        end

        last_error = err
    end

    return false, last_error
end

local function parse_key_value_text(text)
    local values = {}
    if type(text) ~= "string" then
        return values
    end

    for line in string.gmatch(text, "[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key ~= nil then
            values[key] = value
        end
    end

    return values
end

local function text_is_true(value)
    return value == "1" or value == "true" or value == "TRUE"
end

local function normalize_tact_name(value)
    local normalized = tostring(value or ""):gsub("\\", "/")
    if normalized == "" then
        return ""
    end
    if not normalized:lower():match("%.tact$") then
        normalized = normalized .. ".tact"
    end
    return normalized
end

local function get_tact_path_candidates(tact_name)
    local normalized = normalize_tact_name(tact_name)
    if normalized == "" then
        return {}
    end

    local candidates = {}
    if normalized:find("/", 1, true) ~= nil then
        candidates[#candidates + 1] = normalized
    end

    candidates[#candidates + 1] = "haptic_feedback/" .. normalized
    candidates[#candidates + 1] = normalized
    return candidates
end

local function json_skip_whitespace(text, index)
    local length = #text
    while index <= length do
        local ch = text:sub(index, index)
        if ch ~= " " and ch ~= "\t" and ch ~= "\r" and ch ~= "\n" then
            return index
        end
        index = index + 1
    end
    return index
end

local function json_string_end(text, index)
    if text:sub(index, index) ~= '"' then
        return nil
    end

    index = index + 1
    local length = #text
    while index <= length do
        local ch = text:sub(index, index)
        if ch == "\\" then
            index = index + 2
        elseif ch == '"' then
            return index
        else
            index = index + 1
        end
    end
    return nil
end

local function json_value_end(text, index)
    index = json_skip_whitespace(text, index)
    local first = text:sub(index, index)
    if first == '"' then
        return json_string_end(text, index)
    end

    if first == "{" or first == "[" then
        local stack = { first == "{" and "}" or "]" }
        index = index + 1
        local length = #text
        while index <= length do
            local ch = text:sub(index, index)
            if ch == '"' then
                local ending = json_string_end(text, index)
                if ending == nil then
                    return nil
                end
                index = ending + 1
            elseif ch == "{" then
                stack[#stack + 1] = "}"
                index = index + 1
            elseif ch == "[" then
                stack[#stack + 1] = "]"
                index = index + 1
            elseif ch == stack[#stack] then
                stack[#stack] = nil
                if #stack == 0 then
                    return index
                end
                index = index + 1
            else
                index = index + 1
            end
        end
        return nil
    end

    local length = #text
    while index <= length do
        local ch = text:sub(index, index)
        if ch == "," or ch == "}" or ch == "]" then
            return index - 1
        end
        index = index + 1
    end
    return length
end

local function extract_top_level_json_member(text, member_name)
    if type(text) ~= "string" or type(member_name) ~= "string" then
        return nil
    end

    local index = json_skip_whitespace(text, 1)
    if text:sub(index, index) ~= "{" then
        return nil
    end
    index = index + 1

    local length = #text
    while index <= length do
        index = json_skip_whitespace(text, index)
        local ch = text:sub(index, index)
        if ch == "," then
            index = index + 1
            index = json_skip_whitespace(text, index)
            ch = text:sub(index, index)
        end
        if ch == "}" then
            return nil
        end
        if ch ~= '"' then
            return nil
        end

        local key_end = json_string_end(text, index)
        if key_end == nil then
            return nil
        end
        local key = text:sub(index + 1, key_end - 1)

        index = json_skip_whitespace(text, key_end + 1)
        if text:sub(index, index) ~= ":" then
            return nil
        end

        local value_start = json_skip_whitespace(text, index + 1)
        local value_end = json_value_end(text, value_start)
        if value_end == nil then
            return nil
        end
        if key == member_name then
            return text:sub(value_start, value_end)
        end
        index = value_end + 1
    end

    return nil
end

local function encode_json_value(value)
    if type(value) == "string" then
        return value
    end

    if json ~= nil then
        if type(json.dump_string) == "function" then
            local ok, encoded = pcall(json.dump_string, value)
            if ok and type(encoded) == "string" then
                return encoded
            end
        end

        if type(json.encode) == "function" then
            local ok, encoded = pcall(json.encode, value)
            if ok and type(encoded) == "string" then
                return encoded
            end
        end
    end

    return nil
end

local function decode_json_value(value)
    if type(value) ~= "string" then
        return nil
    end

    if json ~= nil then
        if type(json.load_string) == "function" then
            local ok, decoded = pcall(json.load_string, value)
            if ok then
                return decoded
            end
        end

        if type(json.decode) == "function" then
            local ok, decoded = pcall(json.decode, value)
            if ok then
                return decoded
            end
        end
    end

    return nil
end

local function load_tact_project_json(tact_name)
    local content, resolved_path = read_first_available_text(get_tact_path_candidates(tact_name))
    if content == nil then
        return nil, nil, "tact file not found"
    end

    -- Legacy Alyx/Backpack tact files lose haptic data when re-encoded by Lua json.
    local raw_project_json = extract_top_level_json_member(content, "project")
    if type(raw_project_json) == "string" and raw_project_json:sub(1, 1) == "{" then
        local decoded_project = decode_json_value(raw_project_json)
        if type(decoded_project) == "table" then
            return raw_project_json, resolved_path, nil
        end
    end

    local decoded = decode_json_value(content)
    if type(decoded) ~= "table" or type(decoded.project) ~= "table" then
        return nil, resolved_path, "tact file missing project table"
    end

    local project_json = encode_json_value(decoded.project)
    if type(project_json) ~= "string" then
        return nil, resolved_path, "json encoder unavailable"
    end

    return project_json, resolved_path, nil
end

local function normalize_haptic_feedback_subdir(relative_path)
    local normalized = tostring(relative_path or ""):gsub("\\", "/")
    normalized = normalized:gsub("^/+", "")
    normalized = normalized:gsub("/+$", "")
    return normalized
end

local function get_haptic_feedback_folder_path(relative_path)
    local normalized = normalize_haptic_feedback_subdir(relative_path)
    if normalized == "" then
        return "haptic_feedback"
    end
    return "haptic_feedback/" .. normalized
end

local function quote_windows_cmd_arg(value)
    return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

local function list_tact_files_in_subdir(relative_path)
    local folder_path = get_haptic_feedback_folder_path(relative_path)
    if io == nil or type(io.popen) ~= "function" then
        return nil, "io.popen unavailable", folder_path
    end

    local windows_glob = (folder_path:gsub("/", "\\")) .. "\\*.tact"
    local command = "cmd /d /c dir /b /a-d " .. quote_windows_cmd_arg(windows_glob) .. " 2>nul"
    local pipe = io.popen(command)
    if pipe == nil then
        return nil, "io.popen failed", folder_path
    end

    local files = {}
    for line in pipe:lines() do
        local file_name = tostring(line or ""):gsub("\r", "")
        if file_name:lower():match("%.tact$") then
            files[#files + 1] = file_name
        end
    end
    pipe:close()

    table.sort(files, function(left, right)
        return left:lower() < right:lower()
    end)

    if #files == 0 then
        return nil, "no_tact_files_found", folder_path
    end

    return files, nil, folder_path
end

local function strip_tact_extension(value)
    return tostring(value or ""):gsub("%.tact$", "")
end

local function update_duration_from_table(value, state)
    if type(value) ~= "table" then
        return
    end

    local start_time = tonumber(value.startTime) or 0.0
    local end_time = tonumber(value.endTime)
    local offset_time = tonumber(value.offsetTime)

    if end_time ~= nil then
        state.maxMillis = math.max(state.maxMillis, end_time)
    end
    if offset_time ~= nil then
        state.maxMillis = math.max(state.maxMillis, offset_time, start_time + offset_time)
    end

    for _, child in pairs(value) do
        if type(child) == "table" then
            update_duration_from_table(child, state)
        end
    end
end

local function extract_tact_duration_seconds(project)
    if type(project) ~= "table" then
        return 0.0
    end

    local duration = tonumber(project.mediaFileDuration)
    if duration ~= nil and duration > 0.0 then
        return duration
    end

    local media_duration = tonumber(project.media and project.media.duration)
    if media_duration ~= nil and media_duration > 0.0 then
        return media_duration
    end

    local state = { maxMillis = 0.0 }
    update_duration_from_table(project.tracks, state)
    if state.maxMillis > 0.0 then
        return state.maxMillis / 1000.0
    end

    return 0.0
end

local function inspect_tact_project(tact_name)
    local project_json, resolved_path, load_error = load_tact_project_json(tact_name)
    if type(project_json) ~= "string" then
        return nil, load_error or "tact file not found", resolved_path
    end

    local decoded = decode_json_value(project_json)
    local project = type(decoded) == "table" and (decoded.project or decoded) or nil
    local display_name = strip_tact_extension(tact_name)
    if type(project) == "table" and type(project.name) == "string" and project.name ~= "" then
        display_name = project.name
    end

    return {
        tactFile = tact_name,
        resolvedPath = resolved_path,
        projectJson = project_json,
        project = project,
        displayName = display_name,
        duration = extract_tact_duration_seconds(project),
    }, nil, resolved_path
end

local HAPTICS_CONFIG_PATHS = {
    "re8_vr_haptic_feedback.json",
    "re8_vr/re8_vr_haptic_feedback.json",
}

local haptics_config_runtime = {
    enabled = false,
    device = "bhaptics",
    loaded = false,
    config_path = nil,
}

local haptics_service_state = {
    last_init = {
        success = false,
        reason = "not_initialized",
        device = nil,
    },
    last_device_change = nil,
}

local function normalize_haptics_device(value)
    local device = tostring(value or ""):lower()
    if device == "truegear" or device == "true_gear" then
        return "truegear"
    end
    if device == "bhaptics" or device == "bhpatics" then
        return "bhaptics"
    end
    return nil
end

local function load_haptics_config_file()
    if json == nil or type(json.load_file) ~= "function" then
        return nil, nil
    end

    for _, path in ipairs(HAPTICS_CONFIG_PATHS) do
        local ok, cfg = pcall(json.load_file, path)
        if ok and type(cfg) == "table" then
            return cfg, path
        end
    end

    local candidates = get_path_candidates("re8_vr/re8_vr_haptic_feedback.json")
    for _, path in ipairs(candidates) do
        local ok, cfg = pcall(json.load_file, path)
        if ok and type(cfg) == "table" then
            return cfg, path
        end
    end

    return nil, nil
end

local function find_haptics_config_write_path()
    local _, resolved_path = load_haptics_config_file()
    if type(resolved_path) == "string" and resolved_path ~= "" then
        return resolved_path
    end

    return HAPTICS_CONFIG_PATHS[2]
end

local function sync_global_haptics_enabled()
    _G.VR_HAPTIC_FEEDBACK_ENABLED = haptics_config_runtime.enabled == true
end

local function reload_haptics_config()
    local file_cfg, resolved_path = load_haptics_config_file()
    if type(file_cfg) == "table" then
        if file_cfg.enabled ~= nil then
            haptics_config_runtime.enabled = file_cfg.enabled == true
        end
        local device = normalize_haptics_device(file_cfg.device)
        if device ~= nil then
            haptics_config_runtime.device = device
        end
        haptics_config_runtime.config_path = resolved_path
    else
        haptics_config_runtime.config_path = find_haptics_config_write_path()
    end

    haptics_config_runtime.loaded = true
    sync_global_haptics_enabled()
    return haptics_config_runtime
end

local function save_haptics_config_to_disk()
    local path = haptics_config_runtime.config_path or find_haptics_config_write_path()
    if path == nil or json == nil or type(json.dump_file) ~= "function" then
        return false
    end

    local payload = {
        enabled = haptics_config_runtime.enabled == true,
        device = haptics_config_runtime.device,
    }
    local ok = pcall(json.dump_file, path, payload)
    if ok then
        haptics_config_runtime.config_path = path
    end
    return ok == true
end

local function invalidate_active_bridge_cache()
    bhaptics_bridge_cache = nil
    truegear_bridge_cache = nil
end

local function apply_haptics_config_change(source)
    sync_global_haptics_enabled()
    save_haptics_config_to_disk()
    invalidate_active_bridge_cache()
    haptics_service_state.last_init.success = false
    if haptics_config_runtime.enabled == true then
        haptics.init(source or "config_change")
    else
        haptics_service_state.last_init = {
            success = false,
            reason = "disabled",
            device = haptics_config_runtime.device,
        }
    end
end

function haptics.get_haptics_config()
    if haptics_config_runtime.loaded ~= true then
        reload_haptics_config()
    end
    return {
        enabled = haptics_config_runtime.enabled == true,
        device = haptics_config_runtime.device,
    }
end

function haptics.get_active_device()
    return haptics.get_haptics_config().device
end

function haptics.is_truegear_active()
    return haptics.get_active_device() == "truegear"
end

function haptics.is_haptics_enabled()
    return haptics.get_haptics_config().enabled == true
end

function haptics.set_haptics_config(cfg)
    if type(cfg) ~= "table" then
        return false
    end

    if haptics_config_runtime.loaded ~= true then
        reload_haptics_config()
    end

    local previous_device = haptics_config_runtime.device
    if cfg.enabled ~= nil then
        haptics_config_runtime.enabled = cfg.enabled == true
    end
    if cfg.device ~= nil then
        local device = normalize_haptics_device(cfg.device)
        if device ~= nil then
            haptics_config_runtime.device = device
        end
    end

    if previous_device ~= haptics_config_runtime.device then
        haptics_service_state.last_device_change = {
            from = previous_device,
            to = haptics_config_runtime.device,
            at = os.clock(),
        }
    end

    apply_haptics_config_change("set_haptics_config")
    return true
end

function haptics.set_haptics_enabled(enabled)
    return haptics.set_haptics_config({ enabled = enabled == true }) == true
end

function haptics.set_active_device(device)
    local normalized = normalize_haptics_device(device)
    if normalized == nil then
        return false
    end
    return haptics.set_haptics_config({ device = normalized }) == true
end

local function wrap_direct_lua_bridge(bridge, device_name)
    if type(bridge) ~= "table" then
        return nil
    end

    if type(bridge.register_project) ~= "function"
        or type(bridge.submit_registered) ~= "function"
        or type(bridge.submit_frame) ~= "function"
    then
        return nil
    end

    local bridge_device = normalize_haptics_device(device_name) or "bhaptics"
    local bridge_mode = bridge.mode
    if type(bridge_mode) ~= "string" or bridge_mode == "" then
        bridge_mode = bridge_device == "truegear" and "truegear_lua_bridge" or "lua_bridge"
    end

    return {
        device = bridge_device,
        name = bridge.name,
        mode = bridge_mode,
        ensure_connected = function()
            if type(bridge.ensure_connected) ~= "function" then
                return true
            end
            return bridge.ensure_connected() == true
        end,
        register_project = function(key, project_json, duration)
            return bridge.register_project(key, project_json, duration or 0.0) == true
        end,
        submit_registered = function(key)
            return bridge.submit_registered(key) == true
        end,
        submit_registered_with_options = function(key, alt_key, scale_json, rotation_json)
            if type(bridge.submit_registered_with_options) ~= "function" then
                return false
            end
            return bridge.submit_registered_with_options(key, alt_key or "", scale_json or "{}", rotation_json or "{}") == true
        end,
        submit_frame = function(key, frame_json)
            return bridge.submit_frame(key, frame_json) == true
        end,
        send_raw = function(payload)
            return type(bridge.send_raw) == "function" and bridge.send_raw(payload) == true or false
        end,
        trigger_connection_pulse = function()
            return type(bridge.trigger_connection_pulse) == "function" and bridge.trigger_connection_pulse() == true or false
        end,
        is_connected = function()
            return type(bridge.is_connected) == "function" and bridge.is_connected() == true or false
        end,
        get_status = function()
            if type(bridge.get_status) ~= "function" then
                return nil
            end
            local ok, status = pcall(bridge.get_status)
            if ok and type(status) == "table" then
                return status
            end
            return nil
        end,
    }
end

local function create_bhaptics_queue_bridge()
    local status_paths = get_path_candidates("data/bhpatics_bridge.status")
    local queue_paths = get_path_candidates("data/bhpatics_bridge.queue")

    local function get_status()
        local status_text, resolved_status_path = read_first_available_text(status_paths)
        if status_text == nil then
            return nil
        end

        local parsed = parse_key_value_text(status_text)
        return {
            ready = text_is_true(parsed.ready),
            connected = text_is_true(parsed.connected),
            directLua = text_is_true(parsed.directLua),
            phase = parsed.phase,
            mode = parsed.mode,
            lastError = parsed.lastError,
            lastCommand = parsed.lastCommand,
            statusPath = resolved_status_path,
            queuePath = parsed.queuePath or queue_paths[1],
        }
    end

    local function enqueue(parts)
        local ok = append_first_available_line(queue_paths, table.concat(parts, "\t"))
        return ok == true
    end

    return {
        device = "bhaptics",
        name = "bhaptics_queue_bridge",
        mode = "queue_bridge",
        ensure_connected = function()
            return enqueue({ "ENSURE_CONNECTED" })
        end,
        register_project = function(key, project_json, duration)
            return enqueue({ "REGISTER_PROJECT", tostring(key or ""), tostring(tonumber(duration) or 0.0), tostring(project_json or "") })
        end,
        submit_registered = function(key)
            return enqueue({ "SUBMIT_REGISTERED", tostring(key or "") })
        end,
        submit_registered_with_options = function(key, alt_key, scale_json, rotation_json)
            return enqueue({
                "SUBMIT_REGISTERED_WITH_OPTIONS",
                tostring(key or ""),
                tostring(alt_key or ""),
                tostring(scale_json or "{}"),
                tostring(rotation_json or "{}"),
            })
        end,
        submit_frame = function(key, frame_json)
            return enqueue({ "SUBMIT_FRAME", tostring(key or ""), tostring(frame_json or "") })
        end,
        send_raw = function(payload)
            return enqueue({ "SEND_RAW", tostring(payload or "") })
        end,
        trigger_connection_pulse = function()
            return enqueue({ "CONNECTION_PULSE" })
        end,
        is_connected = function()
            local status = get_status()
            return status ~= nil and status.connected == true
        end,
        get_status = get_status,
    }
end

local bhaptics_queue_bridge = nil
local bhaptics_bridge_cache = nil
local truegear_bridge_cache = nil

local function resolve_bhaptics_bridge()
    local direct = wrap_direct_lua_bridge(
        rawget(_G, "BhapticsBridge") or rawget(_G, "bhaptics_bridge"),
        "bhaptics"
    )
    if direct ~= nil then
        bhaptics_bridge_cache = direct
        return bhaptics_bridge_cache
    end

    if bhaptics_queue_bridge == nil then
        bhaptics_queue_bridge = create_bhaptics_queue_bridge()
    end

    bhaptics_bridge_cache = bhaptics_queue_bridge
    return bhaptics_bridge_cache
end

local function resolve_truegear_bridge()
    local direct = wrap_direct_lua_bridge(
        rawget(_G, "TrueGearBridge") or rawget(_G, "truegear_bridge"),
        "truegear"
    )
    if direct ~= nil then
        truegear_bridge_cache = direct
        return truegear_bridge_cache
    end

    return nil
end

local function resolve_active_bridge()
    if haptics.is_haptics_enabled() ~= true then
        return nil
    end

    if haptics.is_truegear_active() then
        return resolve_truegear_bridge()
    end

    return resolve_bhaptics_bridge()
end

local function init_bhaptics_bridge()
    local bridge = resolve_bhaptics_bridge()
    if bridge == nil then
        return false, "bhaptics_bridge_unavailable"
    end

    if type(bridge.ensure_connected) == "function" then
        bridge.ensure_connected()
    end

    return true, nil
end

local function init_truegear_bridge()
    local bridge = resolve_truegear_bridge()
    if bridge == nil then
        return false, "truegear_bridge_unavailable"
    end

    if type(bridge.ensure_connected) == "function" then
        bridge.ensure_connected()
    end

    return true, nil
end

function haptics.ensure_connected()
    if haptics.is_haptics_enabled() ~= true then
        return false
    end

    local bridge = resolve_active_bridge()
    if bridge == nil or type(bridge.ensure_connected) ~= "function" then
        return false
    end
    return bridge.ensure_connected() == true
end

function haptics.register_project(key, project_json, duration)
    if haptics.is_haptics_enabled() ~= true then
        return false
    end

    local bridge = resolve_active_bridge()
    if bridge == nil or type(bridge.register_project) ~= "function" then
        return false
    end
    if type(bridge.ensure_connected) == "function" then
        bridge.ensure_connected()
    end
    return bridge.register_project(key, project_json, duration or 0.0) == true
end

function haptics.submit_registered(key)
    if haptics.is_haptics_enabled() ~= true then
        return false
    end

    local bridge = resolve_active_bridge()
    if bridge == nil or type(bridge.submit_registered) ~= "function" then
        return false
    end
    return bridge.submit_registered(key) == true
end

function haptics.send_raw(payload)
    if haptics.is_haptics_enabled() ~= true then
        return false
    end

    local bridge = resolve_active_bridge()
    if bridge == nil or type(bridge.send_raw) ~= "function" then
        return false
    end
    return bridge.send_raw(payload) == true
end

function haptics.getBridgeMode()
    local bridge = resolve_active_bridge()
    return bridge ~= nil and bridge.mode or nil
end

function haptics.getBridgeStatus()
    local bridge = resolve_active_bridge()
    if bridge == nil or type(bridge.get_status) ~= "function" then
        return nil
    end
    return bridge.get_status()
end

function haptics.init(reason)
    if haptics_config_runtime.loaded ~= true then
        reload_haptics_config()
    end

    local cfg = haptics.get_haptics_config()
    if cfg.enabled ~= true then
        haptics_service_state.last_init = {
            success = false,
            reason = "disabled",
            device = cfg.device,
        }
        return true
    end

    if haptics_service_state.last_init.success == true
        and haptics_service_state.last_init.device == cfg.device
    then
        haptics.ensure_connected()
        return true
    end

    local init_ok = false
    local init_reason = "unknown"
    if cfg.device == "truegear" then
        init_ok, init_reason = init_truegear_bridge()
    else
        init_ok, init_reason = init_bhaptics_bridge()
    end

    if init_ok ~= true then
        haptics_service_state.last_init = {
            success = false,
            reason = init_reason or "bridge_init_failed",
            device = cfg.device,
        }
        return false
    end

    haptics_service_state.last_init = {
        success = true,
        reason = tostring(reason or "initialized"),
        device = cfg.device,
    }

    return true
end

local function build_bridge_service_view(bridge)
    local bridge_info = {
        available = bridge ~= nil,
        connected = false,
        phase = nil,
        mode = bridge ~= nil and bridge.mode or nil,
        lastError = nil,
        lastCommand = nil,
    }

    if bridge == nil then
        return bridge_info
    end

    bridge_info.device = bridge.device
    bridge_info.name = bridge.name

    local status = type(bridge.get_status) == "function" and bridge.get_status() or nil
    if type(status) == "table" then
        bridge_info.connected = status.connected == true
        bridge_info.phase = status.phase
        bridge_info.mode = status.mode or bridge_info.mode
        bridge_info.lastError = status.lastError
        bridge_info.lastCommand = status.lastCommand
        if status.ready ~= nil then
            bridge_info.ready = status.ready == true
        end
        if status.directLua ~= nil then
            bridge_info.directLua = status.directLua == true
        end
    elseif type(bridge.is_connected) == "function" then
        bridge_info.connected = bridge.is_connected() == true
    end

    return bridge_info
end

function haptics.getServiceStatus()
    local cfg = haptics.get_haptics_config()
    local bridge = resolve_active_bridge()
    return {
        config = {
            enabled = cfg.enabled == true,
            device = cfg.device,
            path = haptics_config_runtime.config_path,
        },
        activeDevice = cfg.enabled == true and cfg.device or nil,
        bridge = build_bridge_service_view(bridge),
        lastInit = haptics_service_state.last_init,
        lastDeviceChange = haptics_service_state.last_device_change,
        startup = {
            played = false,
            reason = "disabled_by_design",
        },
        driver = haptics_service_state.last_init.success == true,
        playback = get_haptic_playback_snapshot(),
    }
end

function haptics.resetBhapticsDriver()
    invalidate_active_bridge_cache()
    haptics_service_state.last_init = {
        success = false,
        reason = "not_initialized",
        device = haptics_config_runtime.device,
    }
end

local function create_haptic_feedback_registered_pattern(key, tact_file, duration, options)
    local pattern = {
        isHapticFeedback = true,
        key = key,
        tactFile = tact_file or key,
        duration = tonumber(duration) or 0.0,
    }

    if type(options) == "table" then
        for option_key, option_value in pairs(options) do
            pattern[option_key] = option_value
        end
    end

    return pattern
end

local function create_haptic_feedback_frame_pattern(key, frame, duration, options)
    local pattern = {
        isHapticFeedback = true,
        key = key,
        frame = frame,
        duration = tonumber(duration) or 0.0,
    }

    if type(options) == "table" then
        for option_key, option_value in pairs(options) do
            pattern[option_key] = option_value
        end
    end

    return pattern
end

local HapticPlayer = {}
HapticPlayer.__index = HapticPlayer

function HapticPlayer.new(touch_player)
    return setmetatable({
        touch_player = touch_player,
        bridge = nil,
        bridgeMode = nil,
        registry = {},
        registeredProjectTimings = {},
        _bridgeConnected = false,
        _startupProbeTime = 0.0,
        _startupVoiceFeedbackPlayed = false,
        _startupRequestReason = "startup",
    }, HapticPlayer)
end

function HapticPlayer:refreshBridge()
    local bridge = resolve_active_bridge()
    self.bridge = bridge
    self.bridgeMode = bridge ~= nil and bridge.mode or nil
    return bridge
end

function HapticPlayer:_isHapticFeedbackPattern(pattern)
    return type(pattern) == "table" and (
        pattern.isHapticFeedback == true
        or pattern.tactFile ~= nil
        or pattern.projectJson ~= nil
        or pattern.frame ~= nil
        or pattern.frameJson ~= nil
    )
end

function HapticPlayer:_resolveHapticFeedbackKey(name, pattern)
    if type(pattern) == "table" and type(pattern.key) == "string" and pattern.key ~= "" then
        return pattern.key
    end
    if type(name) == "string" and name ~= "" then
        return name
    end
    if type(pattern) == "table" and type(pattern.name) == "string" and pattern.name ~= "" then
        return pattern.name
    end
    return nil
end

function HapticPlayer:_syncBridgeStatus()
    local bridge = self:refreshBridge()
    if bridge == nil then
        self._bridgeConnected = false
        return nil, false, nil
    end

    local status = type(bridge.get_status) == "function" and bridge.get_status() or nil
    local connected = status ~= nil and status.connected == true or (type(bridge.is_connected) == "function" and bridge.is_connected() == true)

    if connected ~= self._bridgeConnected then
        for _, pattern in pairs(self.registry) do
            if type(pattern) == "table" and self:_isHapticFeedbackPattern(pattern) then
                pattern._registered = false
            end
        end
    end

    self._bridgeConnected = connected and true or false
    return bridge, self._bridgeConnected, status
end

function HapticPlayer:_ensureHapticFeedbackRegistered(name, pattern)
    if not self:_isHapticFeedbackPattern(pattern) then
        return false
    end

    local key = self:_resolveHapticFeedbackKey(name, pattern)
    if key == nil then
        pattern._lastRegisterError = "haptic_feedback_key_missing"
        pattern._registerFailed = true
        return false
    end

    pattern._hapticFeedbackKey = key

    if pattern.frame ~= nil or pattern.frameJson ~= nil then
        pattern._registerFailed = false
        return true
    end

    if pattern._registered == true then
        return true
    end

    if pattern._registerFailed == true then
        return false
    end

    local bridge = self:refreshBridge()
    if bridge == nil or type(bridge.register_project) ~= "function" then
        pattern._lastRegisterError = "bridge_unavailable"
        return false
    end

    local project_json = pattern.projectJson
    local resolved_path = pattern.tactPath
    local load_error = pattern._lastRegisterError

    if type(project_json) ~= "string" and pattern._projectLoadAttempted ~= true then
        project_json, resolved_path, load_error = load_tact_project_json(pattern.tactFile or key)
        pattern._projectLoadAttempted = true
        pattern.projectJson = project_json
        pattern.tactPath = resolved_path
    end

    if type(project_json) ~= "string" then
        pattern._lastRegisterError = load_error or "project_json_missing"
        pattern._registerFailed = true
        return false
    end

    local tact_duration = extract_tact_duration_seconds(decode_json_value(project_json))
    if tact_duration > 0.0 then
        pattern.duration = tact_duration
    end

    if bridge.register_project(key, project_json, tonumber(pattern.duration) or 0.0) ~= true then
        pattern._lastRegisterError = "register_project_failed"
        return false
    end

    pattern._lastRegisterError = nil
    pattern._registerFailed = false
    pattern._registered = true
    self.registeredProjectTimings[key] = self.registeredProjectTimings[key] or {
        duration = tonumber(pattern.duration) or 0.0,
        nextPossibleUpdate = 0.0,
    }
    self.registeredProjectTimings[key].duration = tonumber(pattern.duration) or 0.0
    return true
end

function HapticPlayer:registerAllPendingHapticFeedback()
    local bridge = self:refreshBridge()
    if bridge == nil then
        return false
    end

    local any_registered = false
    for name, pattern in pairs(self.registry) do
        if self:_isHapticFeedbackPattern(pattern)
            and pattern.frame == nil
            and pattern.frameJson == nil
            and pattern._registered ~= true
        then
            if self:_ensureHapticFeedbackRegistered(name, pattern) then
                any_registered = true
            end
        end
    end

    return any_registered
end

function HapticPlayer:_playHapticFeedbackPattern(gesture_name, pattern, phase_name)
    local key = self:_resolveHapticFeedbackKey(pattern.name, pattern)
    if key == nil then
        return false
    end

    -- Python HapticPlayer: canSend(currentTime, key) then submit_registered(key).
    -- Vest hold rhythm comes from registered tact duration only.
    local timing = self.registeredProjectTimings[key]
    if timing == nil then
        timing = {
            duration = tonumber(pattern.duration) or 0.0,
            nextPossibleUpdate = 0.0,
        }
        self.registeredProjectTimings[key] = timing
    end

    local now = os.clock()
    if now < (timing.nextPossibleUpdate or 0.0) then
        return false
    end

    local bridge = self:refreshBridge()
    if bridge == nil then
        return false
    end

    if type(bridge.ensure_connected) == "function" then
        bridge.ensure_connected()
    end

    local played = false
    if pattern.frame ~= nil or pattern.frameJson ~= nil then
        if is_registered_playback_occupying(now) then
            return false
        end

        local frame_json = pattern.frameJson
        if type(frame_json) ~= "string" then
            frame_json = encode_json_value(pattern.frame)
            pattern.frameJson = frame_json
        end
        if type(frame_json) == "string" and type(bridge.submit_frame) == "function" then
            played = bridge.submit_frame(key, frame_json) == true
        end
    else
        if not self:_ensureHapticFeedbackRegistered(pattern.name, pattern) then
            return false
        end

        key = pattern._hapticFeedbackKey or key
        if pattern.scaleOption ~= nil or pattern.rotationOption ~= nil or pattern.altKey ~= nil then
            local scale_json = encode_json_value(pattern.scaleOption or {})
            local rotation_json = encode_json_value(pattern.rotationOption or {})
            if type(scale_json) == "string"
                and type(rotation_json) == "string"
                and type(bridge.submit_registered_with_options) == "function"
            then
                played = bridge.submit_registered_with_options(key, pattern.altKey or "", scale_json, rotation_json) == true
            end
        else
            played = type(bridge.submit_registered) == "function" and bridge.submit_registered(key) == true or false
        end
    end

    if not played then
        if pattern.frame == nil and pattern.frameJson == nil then
            pattern._registered = false
        end
        return false
    end

    timing.duration = tonumber(pattern.duration) or timing.duration or 0.0
    timing.nextPossibleUpdate = now + math.max(0.0, timing.duration or 0.0)
    if pattern.frame == nil and pattern.frameJson == nil then
        mark_registered_playback_occupancy(timing.duration, now)
    end
    mark_haptic_playback({
        gestureName = gesture_name,
        patternName = pattern.name or key,
        phase = phase_name,
        leftHand = false,
    }, timing.duration)
    publish_last_haptic_source({
        gestureName = gesture_name,
        patternName = pattern.name or key,
        phase = phase_name,
        leftHand = false,
    })
    return true
end

function HapticPlayer:_tryStartupBridgeTest()
    if self._startupVoiceFeedbackPlayed then
        return false
    end

    self._startupVoiceFeedbackPlayed = true
    local bridge = self:refreshBridge()
    if bridge ~= nil and type(bridge.ensure_connected) == "function" then
        bridge.ensure_connected()
    end
    return bridge ~= nil
end

function HapticPlayer:requestStartupVoiceFeedback(reason)
    self._startupVoiceFeedbackPlayed = false
    self._startupProbeTime = 0.0
    self._startupRequestReason = tostring(reason or "startup")
    return self:_tryStartupBridgeTest()
end

function HapticPlayer:register(name, pattern)
    if name == nil then
        return false
    end
    if type(pattern) == "table" and pattern.name == nil then
        pattern.name = name
    end
    if type(pattern) == "table" then
        pattern._registered = false
        pattern._registerFailed = false
        pattern._projectLoadAttempted = type(pattern.projectJson) == "string"
        pattern._lastRegisterError = nil
    end
    self.registry[name] = pattern
    return true
end

function HapticPlayer:play_registered(gesture_name, pattern, phase_name)
    if pattern == nil then
        return false
    end

    local resolved = pattern
    if type(pattern) == "string" then
        resolved = self.registry[pattern]
    end

    if resolved == nil then
        return false
    end

    if resolved.samples ~= nil then
        if self.touch_player == nil then
            return false
        end
        return self.touch_player:play(resolved, gesture_name, phase_name)
    end

    if self:_isHapticFeedbackPattern(resolved) then
        return self:_playHapticFeedbackPattern(gesture_name, resolved, phase_name)
    end

    return false
end

function HapticPlayer:update(delta_time)
    if self.touch_player ~= nil then
        self.touch_player:update(delta_time)
    end
    clear_expired_haptic_playback(os.clock())
end

function HapticPlayer:clear()
    if self.touch_player ~= nil and self.touch_player.clear ~= nil then
        self.touch_player:clear()
    end
end

local function set_touch_feedback(gesture, touch_validating, touch_enter)
    if gesture == nil then
        return
    end
    gesture.touchValidating = touch_validating or gesture.touchValidating
    gesture.haptics.touchEnter = touch_enter or gesture.haptics.touchEnter
end

local function set_vest_feedback(gesture, validating, enter, hold, leave)
    if gesture == nil then
        return
    end
    if validating ~= nil then
        gesture.validating = validating
    end
    if enter ~= nil then
        gesture.haptics.enter = enter
    end
    if hold ~= nil then
        gesture.haptics.hold = hold
    end
    if leave ~= nil then
        gesture.haptics.leave = leave
    end
end

function haptics.registerCompanionHapticFeedback(haptic_player)
    if haptic_player == nil or type(haptic_player.register) ~= "function" then
        return false
    end

    for _, key in ipairs(COMPANION_HAPTIC_FEEDBACK_PATTERN_KEYS) do
        haptic_player:register(
            key,
            create_haptic_feedback_registered_pattern(key, key, 0.0, { name = key })
        )
    end

    return true
end

function haptics.createCompanionDefaults(touch_haptics_player)
    -- Touch haptics position and prefabs ported from VRCompanion.py.
    local defaults = {
        Touch_Left = true,
        Touch_Right = false,
    }

    defaults.Touch_Validating_Left = TouchHaptics.new(defaults.Touch_Left, touch_haptics_player:pulse(0.1, 0.25), "Touch_Validating_Left")
    defaults.Touch_Validating_Right = TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.1, 0.25), "Touch_Validating_Right")
    defaults.Touch_Enter_Left = TouchHaptics.new(defaults.Touch_Left, touch_haptics_player:pulse(0.25, 1.0), "Touch_Enter_Left")
    defaults.Touch_Enter_Right = TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.25, 1.0), "Touch_Enter_Right")
    defaults.Touch_Melee_Left = TouchHaptics.new(defaults.Touch_Left, touch_haptics_player:pulseWithPause(0.4, 1.0, 0.7), "Touch_Melee_Left")
    defaults.Touch_Melee_Right = TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulseWithPause(0.4, 1.0, 0.7), "Touch_Melee_Right")
    defaults.Touch_DoublePulse_Left = TouchHaptics.new(defaults.Touch_Left, touch_haptics_player:pulseWithPause(0.06, 1.0, 0.2), "Touch_DoublePulse_Left")
    defaults.Touch_DoublePulse_Right = TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulseWithPause(0.06, 1.0, 0.2), "Touch_DoublePulse_Right")
    defaults.Touch_Ancient_Cast_L = TouchHaptics.new(defaults.Touch_Left, touch_haptics_player:pulse(0.2, 1.0), "Touch_Ancient_Cast_L")
    defaults.Touch_Ancient_Cast_R = TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 1.0), "Touch_Ancient_Cast_R")
    defaults.Touch_Ancient_Impact_L = TouchHaptics.new(defaults.Touch_Left, touch_haptics_player:pulse(1.0, 1.0), "Touch_Ancient_Impact_L")
    defaults.Touch_Ancient_Impact_R = TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(1.0, 1.0), "Touch_Ancient_Impact_R")

    defaults.Haptics_Melee = HapticsGroup.new("RecoilMeleeVest_R", nil, nil, defaults.Touch_Melee_Right)
    defaults.Haptics_Pistol = HapticsGroup.new("MinigunVest_R", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 0.5), "Haptics_Pistol.touchEnter"))
    defaults.Haptics_AutoPistol = HapticsGroup.new(nil, "MinigunVest_R", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 0.5), "Haptics_AutoPistol.touchHold"))
    defaults.Haptics_Rifle = HapticsGroup.new("MinigunVest_R", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 1.0), "Haptics_Rifle.touchEnter"))
    defaults.Haptics_AutoRifle = HapticsGroup.new(nil, "MinigunVest_R", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 1.0), "Haptics_AutoRifle.touchHold"))
    defaults.Haptics_Shotgun = HapticsGroup.new("RecoilShotgunVest_R", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulseWithPause(0.4, 1.0, 0.7), "Haptics_Shotgun.touchEnter"))
    defaults.Haptics_AutoShotgun = HapticsGroup.new(nil, "RecoilShotgunVest_R", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulseWithPause(0.4, 1.0, 0.7), "Haptics_AutoShotgun.touchHold"))
    defaults.Haptics_Laser = HapticsGroup.new(nil, "Laser", nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(1.2, 0.5), "Haptics_Laser.touchHold"))

    return defaults
end

function haptics.applyCompanionGestureDefaults(gesture_tracker, defaults)
    if gesture_tracker == nil or defaults == nil then
        return false
    end

    -- Some default feedbacks from VRCompanion.py that only depend on controller vibration.
    set_touch_feedback(gesture_tracker.aimPistol, nil, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.triggerRight, nil, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.meleeLeft, nil, defaults.Touch_Melee_Left)
    set_touch_feedback(gesture_tracker.meleeLeftAlt, nil, defaults.Touch_Melee_Left)
    set_touch_feedback(gesture_tracker.meleeLeftAltPull, nil, defaults.Touch_Melee_Left)
    set_touch_feedback(gesture_tracker.meleeLeftAltPush, nil, defaults.Touch_Melee_Left)
    set_touch_feedback(gesture_tracker.meleeRight, nil, defaults.Touch_Melee_Right)
    set_touch_feedback(gesture_tracker.meleeRightAlt, nil, defaults.Touch_Melee_Right)
    set_touch_feedback(gesture_tracker.meleeRightAltPull, nil, defaults.Touch_Melee_Right)
    set_touch_feedback(gesture_tracker.meleeRightAltPush, nil, defaults.Touch_Melee_Right)
    set_touch_feedback(gesture_tracker.holsterInventoryLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.holsterInventoryRight, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.holsterWeaponLeft, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.holsterWeaponRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.shoulderInventoryLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.shoulderInventoryRight, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.shoulderWeaponLeft, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.shoulderWeaponRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.lightLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.lightRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.upperAreaLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.upperAreaRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.useLeftUp, nil, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.useRightUp, nil, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.useLeftDown, nil, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.useRightDown, nil, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.shakeLeft, nil, defaults.Touch_Ancient_Cast_L)
    set_touch_feedback(gesture_tracker.shakeRight, nil, defaults.Touch_Ancient_Cast_R)
    set_touch_feedback(gesture_tracker.thrustLeft, nil, defaults.Touch_Ancient_Cast_L)
    set_touch_feedback(gesture_tracker.thrustRight, nil, defaults.Touch_Ancient_Cast_R)
    set_touch_feedback(gesture_tracker.retractLeft, nil, defaults.Touch_Melee_Left)
    set_touch_feedback(gesture_tracker.retractRight, nil, defaults.Touch_Melee_Right)
    -- 左手划动方向
    set_touch_feedback(gesture_tracker.swipeLeftHandUp, nil, defaults.Touch_Ancient_Cast_L)
    set_touch_feedback(gesture_tracker.swipeLeftHandLeft, nil, defaults.Touch_Ancient_Impact_L)
    set_touch_feedback(gesture_tracker.swipeLeftHandRight, nil, defaults.Touch_Ancient_Impact_L)
    set_touch_feedback(gesture_tracker.swipeLeftHandDown, nil, defaults.Touch_Ancient_Cast_L)
    -- 右手划动方向
    set_touch_feedback(gesture_tracker.swipeRightHandUp, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.swipeRightHandLeft, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.swipeRightHandRight, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.swipeRightHandDown, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.pullPin, nil, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.holsterBackLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.holsterBackRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.chestLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.chestRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.injectSyringe, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.axeSharpen, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)

    --set_vest_feedback(gesture_tracker.triggerRight, nil, "MinigunVest_R")
    set_vest_feedback(gesture_tracker.meleeLeft, nil, "RecoilMeleeVest_L")
    set_vest_feedback(gesture_tracker.meleeLeftAlt, nil, "RecoilMeleeVest_L")
    set_vest_feedback(gesture_tracker.meleeLeftAltPull, nil, "Force Pull_L")
    set_vest_feedback(gesture_tracker.meleeLeftAltPush, nil, "Force Push_L")
    set_vest_feedback(gesture_tracker.meleeRight, nil, "RecoilMeleeVest_R")
    set_vest_feedback(gesture_tracker.meleeRightAlt, nil, "RecoilMeleeVest_R")
    set_vest_feedback(gesture_tracker.meleeRightAltPull, nil, "Force Pull_R")
    set_vest_feedback(gesture_tracker.meleeRightAltPush, nil, "Force Push_R")
    set_vest_feedback(gesture_tracker.thrustLeft, nil, "RecoilMeleeVest_L")
    set_vest_feedback(gesture_tracker.thrustRight, nil, "RecoilMeleeVest_R")    
    set_vest_feedback(gesture_tracker.holsterInventoryLeft, nil, "Equip From Left to Left")
    set_vest_feedback(gesture_tracker.holsterInventoryRight, "Holster Right", "Equip From Right to Left")
    set_vest_feedback(gesture_tracker.holsterWeaponLeft, "Holster Left", "Holster Left")
    set_vest_feedback(gesture_tracker.holsterWeaponRight, nil, "Holster Right")
    set_vest_feedback(gesture_tracker.shoulderInventoryLeft, "Shoulder Holster Left", "Shoulder Holster Left")
    set_vest_feedback(gesture_tracker.shoulderInventoryRight, "Shoulder Holster Right", "Equip From Right to Left")
    set_vest_feedback(gesture_tracker.shoulderWeaponLeft, "Shoulder Holster Left", "BackpackRetrieveClipLeft_1")
    set_vest_feedback(gesture_tracker.shoulderWeaponRight, "Shoulder Holster Right", "BackpackRetrieveClipRight_1")
    set_vest_feedback(gesture_tracker.lightRight, "Light Right")
    set_vest_feedback(gesture_tracker.chestLeft, nil, "Light Left")
    set_vest_feedback(gesture_tracker.chestRight, nil, "Light Left")
    set_vest_feedback(gesture_tracker.useLeftDown, nil, "BackpackStoreClipLeft_1")
    set_vest_feedback(gesture_tracker.useRightDown, nil, "BackpackStoreClipRight_1")    
    set_vest_feedback(gesture_tracker.injectSyringe, nil, "Healing_1")
    return true
end

haptics.HapticsGroup = HapticsGroup
haptics.TouchHapticsSample = TouchHapticsSample
haptics.TouchHaptics = TouchHaptics
haptics.TouchHapticsPlayer = TouchHapticsPlayer
haptics.createHapticFeedbackRegisteredPattern = create_haptic_feedback_registered_pattern
haptics.createHapticFeedbackFramePattern = create_haptic_feedback_frame_pattern
haptics.getHapticFeedbackPlaybackSnapshot = get_haptic_playback_snapshot
haptics.listHapticFeedbackTactFiles = list_tact_files_in_subdir
haptics.inspectHapticFeedbackTact = inspect_tact_project
haptics.getHapticFeedbackFolderPath = get_haptic_feedback_folder_path
-- Exporting the player class is just module wiring, not vest playback by itself.
haptics.HapticPlayer = HapticPlayer

local function register_haptics_config_ui()
    if not (re and re.on_draw_ui and imgui) then
        return
    end

    if rawget(_G, "__RE05_haptics_config_ui_registered") == true then
        return
    end
    _G.__RE05_haptics_config_ui_registered = true

    re.on_draw_ui(function()
        local ok_ui, ui_err = xpcall(function()
            imgui.separator()
            imgui.text_colored("Haptic Feedback (Vest)", 0xFF00FFFF)

            local cfg = haptics.get_haptics_config()
            local changed_enabled, enabled = imgui.checkbox("Enable Haptic Feedback", cfg.enabled == true)
            if changed_enabled then
                haptics.set_haptics_enabled(enabled and true or false)
                cfg = haptics.get_haptics_config()
            end

            -- REFramework imgui.combo uses 1-based indices.
            local device_choices = {"bHaptics", "TrueGear"}
            local device_index = cfg.device == "truegear" and 2 or 1
            local changed_device, new_index = imgui.combo("Device", device_index, device_choices)
            if changed_device then
                local selected = device_choices[new_index]
                haptics.set_active_device(selected == "TrueGear" and "truegear" or "bhaptics")
                cfg = haptics.get_haptics_config()
            end

            local service_status = type(haptics.getServiceStatus) == "function" and haptics.getServiceStatus() or nil
            local bridge_status = type(service_status) == "table" and service_status.bridge or nil
            if type(bridge_status) == "table" then
                imgui.text("Bridge connected: " .. tostring(bridge_status.connected == true))
                imgui.text("Bridge phase: " .. tostring(bridge_status.phase or "nil"))
                imgui.text("Bridge mode: " .. tostring(bridge_status.mode or "nil"))
                imgui.text("Bridge lastError: " .. tostring(bridge_status.lastError or "nil"))
            end
        end, function(err)
            return debug.traceback(tostring(err), 2)
        end)

        if not ok_ui then
            imgui.text_colored("Haptic UI error: " .. tostring(ui_err), 0xFFFF4444)
        end
    end)
end

reload_haptics_config()
register_haptics_config_ui()

if re and re.on_script_reset then
    re.on_script_reset(function()
        haptics.resetBhapticsDriver()
        reload_haptics_config()
    end)
end

package.loaded[module_name] = haptics

return haptics