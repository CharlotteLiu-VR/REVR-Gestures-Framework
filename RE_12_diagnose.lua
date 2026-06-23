local vr_globals = require("RE_00_vr_globals")

-- 与 RE_09 武器槽位手势映射一致（抓握=内环 Equip_*，扳机=外环 Equip_*2）
local WEAPON_SLOT_EQUIP_SHORTCUT_BY_REGION_BINDING = {
    holsterWeaponRight = { grip = "Equip_Right", trigger = "Equip_Right2" },
    shoulderWeaponRight = { grip = "Equip_Down", trigger = "Equip_Down2" },
    chestRight = { grip = "Equip_Left", trigger = "Equip_Left2" },
}

local WEAPON_SLOT_REGION_LABELS = {
    holsterWeaponRight = "右胯",
    shoulderWeaponRight = "右肩",
    chestRight = "胸前",
}

local function resolve_weapon_slot_equip_shortcut(region, binding)
    local region_map = WEAPON_SLOT_EQUIP_SHORTCUT_BY_REGION_BINDING[region]
    if region_map == nil then
        return nil
    end
    return region_map[binding]
end

local function format_weapon_slot_region_label(region)
    local name = tostring(region or "nil")
    local label = WEAPON_SLOT_REGION_LABELS[region]
    if label ~= nil then
        return label .. " (" .. name .. ")"
    end
    return name
end

local function weapon_slot_equip_shortcut_display(slot_event)
    if type(slot_event) ~= "table" then
        return "nil"
    end
    local shortcut = slot_event.key
    if shortcut ~= nil and shortcut ~= "" and shortcut ~= "none" then
        return tostring(shortcut)
    end
    local resolved = resolve_weapon_slot_equip_shortcut(slot_event.region, slot_event.binding)
    if resolved ~= nil then
        return resolved
    end
    return "nil"
end

local haptics_driver = nil
local hapticFeedbackModule = nil
local eventFeedbackModule = nil -- 【临时诊断】RE_11 引擎振动转发，后续删除

local function loadHapticFeedbackModules()
    if haptics_driver == nil then
        local ok, mod = pcall(require, "RE_05_haptics")
        if ok and type(mod) == "table" then
            haptics_driver = mod
        end
    end
    if hapticFeedbackModule == nil then
        local ok, mod = pcall(require, "RE_10_HapticFeedback")
        if ok and type(mod) == "table" then
            hapticFeedbackModule = mod
        else
            hapticFeedbackModule = rawget(_G, "HAPTIC_FEEDBACK")
        end
    end
end

-- 【临时诊断】直接从 RE_11 读取引擎振动转发快照，不经过 RE_00
local function loadEventFeedbackModule()
    if eventFeedbackModule == nil then
        local ok, mod = pcall(require, "RE_11_EventFeedback")
        if ok and type(mod) == "table" then
            eventFeedbackModule = mod
        else
            eventFeedbackModule = rawget(_G, "EVENT_FEEDBACK")
        end
    end
    return eventFeedbackModule
end

local function get_engine_vibration_diag_snapshot()
    local event_feedback = loadEventFeedbackModule()
    if event_feedback ~= nil and type(event_feedback.getEngineVibrationDiagnose) == "function" then
        local ok, snapshot = pcall(event_feedback.getEngineVibrationDiagnose)
        if ok and type(snapshot) == "table" then
            return snapshot, nil
        end
        return nil, "getEngineVibrationDiagnose_failed"
    end
    return nil, "RE_11_EventFeedback_missing"
end

local function direction_verdict_color(verdict_text)
    local text = tostring(verdict_text or "")
    if text:find("真实判定: 前方", 1, true) then
        return 0xFF44FF44
    end
    if text:find("真实判定: 后方", 1, true) then
        return 0xFFFFAA44
    end
    if text:find("回退", 1, true) then
        return 0xFFFFFF44
    end
    return 0xFFAAAAAA
end

local function get_last_hit_direction_verdict_snapshot()
    local event_feedback = loadEventFeedbackModule()
    if event_feedback == nil then
        return nil, nil, nil, "RE_11_EventFeedback_missing"
    end
    if type(event_feedback.getHitDirectionDiagnose) ~= "function" then
        return nil, nil, nil, "getHitDirectionDiagnose_missing"
    end
    local ok, snapshot = pcall(event_feedback.getHitDirectionDiagnose)
    if not ok or type(snapshot) ~= "table" or type(snapshot.last) ~= "table" then
        return nil, nil, nil, "getHitDirectionDiagnose_failed"
    end
    local last = snapshot.last
    return last.direction_verdict, last.damage_kind, last.at, nil
end

local function fmt_hex32(value)
    local numeric = tonumber(value)
    if numeric == nil then
        return "nil"
    end
    return string.format("0x%08X", numeric & 0xFFFFFFFF)
end

local function fmt_seconds_ago(at_value)
    local at = tonumber(at_value)
    if at == nil or at <= 0 then
        return "从未"
    end
    local delta = os.clock() - at
    if delta < 0 then
        delta = 0
    end
    return string.format("%.2fs 前", delta)
end

local diag = _G.DIAG_MODULE
local diag_reloaded = type(diag) == "table"

local MAX_LOG_BYTES = 20 * 1024 * 1024
local DEFAULT_DIAG_ENABLED = false
local TELEMETRY_INTERVAL_SEC = 1.0
local DIAG_PANEL_NAME = "VR Gestures"
local DIAG_LOG_NAME = "diagnose_gestures.log"
local DIAG_LOG_PREFIX = "[VR_GESTURES] "
local TEST_HAPTIC_FEEDBACK_SUBDIR = "test"
local TEST_SEQUENCE_GAP_SEC = 0.2
local TEST_SEQUENCE_RETRY_SEC = 1.0
local log_path = DIAG_LOG_NAME

if not diag_reloaded then
diag = {
    enabled = rawget(_G, "RE_GESTURES_DIAG_ENABLED"),
    installedAt = os.date("%Y-%m-%d %H:%M:%S"),
    lastLogClearedAt = nil,
    tickCount = 0,
    lastLoadError = nil,
    lastTickError = nil,
    lastUiError = nil,
    lastWriteError = nil,
    enhancer = nil,
    lastManualHaptic = nil,
    lastRuntimeStateKey = nil,
    lastWeaponStateKey = nil,
    lastTelemetryAt = 0.0,
    logFile = nil,
    logBytes = 0,
    logWriteFailed = false,
    testSequence = {
        enabled = false,
        folder = TEST_HAPTIC_FEEDBACK_SUBDIR,
        folderPath = nil,
        entries = {},
        index = 1,
        nextAt = 0.0,
        lastError = nil,
        currentName = nil,
        playedCount = 0,
    },
}
end

if diag.enabled == nil then
    diag.enabled = rawget(_G, "VR_DIAG_ENABLED")
end

if diag.enabled == nil then
    diag.enabled = DEFAULT_DIAG_ENABLED
end

local function with_traceback(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function fmt_num(value, precision)
    if type(value) ~= "number" then
        return "nil"
    end
    precision = precision or 3
    return string.format("%." .. tostring(precision) .. "f", value)
end

local function fmt_vec3(value)
    if type(value) ~= "table" then
        return "nil"
    end
    return "(" .. fmt_num(value.x) .. ", " .. fmt_num(value.y) .. ", " .. fmt_num(value.z) .. ")"
end

local function fmt_quat(value)
    if type(value) ~= "table" then
        return "nil"
    end
    return "(" .. fmt_num(value.x) .. ", " .. fmt_num(value.y) .. ", " .. fmt_num(value.z) .. ", " .. fmt_num(value.w) .. ")"
end

local function safe_call(target, method_name, ...)
    if target ~= nil and type(target[method_name]) == "function" then
        local ok, result = pcall(target[method_name], target, ...)
        if ok then
            return true, result
        end
        return false, result
    end
    return false, nil
end

local function get_gui_visible_situation()
    local gui_mgr = sdk and sdk.get_managed_singleton and sdk.get_managed_singleton("app.GuiManager") or nil
    if not gui_mgr then
        return 0
    end

    local ok, value = pcall(gui_mgr.call, gui_mgr, "get_CurrentVisibleSituationType")
    if not ok or value == nil then
        return 0
    end

    return value
end

local function fmt_axes(axis)
    if type(axis) ~= "table" then
        return "(nil,nil)"
    end

    return "(" .. fmt_num(axis.x) .. ", " .. fmt_num(axis.y) .. ")"
end

local function fmt_indices(indices)
    if type(indices) ~= "table" then
        return "nil,nil"
    end

    return tostring(indices[1] or 0) .. "," .. tostring(indices[2] or 0)
end

local function fmt_handle_ref(value)
    if value == nil then
        return "nil"
    end

    return tostring(value)
end

local function summarize_error(value)
    if value == nil then
        return "nil"
    end

    local text = tostring(value)
    local first_line = text:match("([^\r\n]+)") or text
    if first_line:find("module 'ffi' not found", 1, true) then
        return "ffi unavailable"
    end
    if #first_line > 240 then
        return first_line:sub(1, 240) .. "..."
    end
    return first_line
end

local function get_weapon_diag_snapshot()
    local weapon_id = vr_globals.getWeaponId()
    local snapshot = {
        weaponId = weapon_id,
        weaponDisplayName = vr_globals.getCurrentWeaponDisplayName(),
    }

    if weapon_id == nil then
        -- 优先从 RE_10 的 probe 缓存触发更新，避免直接走 native
        local bh = rawget(_G, "HAPTIC_FEEDBACK")
        if type(bh) == "table" and type(bh.weaponProbeTick) == "function" then
            bh.weaponProbeTick()
            weapon_id = vr_globals.getWeaponId()
            if weapon_id ~= nil then
                snapshot.weaponId = weapon_id
                snapshot.weaponDisplayName = vr_globals.getCurrentWeaponDisplayName()
                snapshot.weaponSource = "probe_cache"
            end
        end
    end

    return snapshot
end

local function build_weapon_state_key(snapshot)
    snapshot = snapshot or get_weapon_diag_snapshot()
    return table.concat({
        tostring(snapshot.weaponId or "nil"),
        tostring(snapshot.weaponDisplayName or "nil"),
    }, " | ")
end

local function normalize_controller_indices(controller_indices)
    if controller_indices == nil then
        return nil, nil
    end

    if type(controller_indices) == "table" then
        return controller_indices[1], controller_indices[2]
    end

    local ok_first, first_index = pcall(function()
        return controller_indices[1]
    end)
    local ok_second, second_index = pcall(function()
        return controller_indices[2]
    end)

    if (ok_first and first_index ~= nil) or (ok_second and second_index ~= nil) then
        return first_index, second_index
    end

    local ok_iter, extracted = pcall(function()
        local values = {}
        for index, value in ipairs(controller_indices) do
            values[index] = value
            if index >= 2 then
                break
            end
        end
        return values
    end)

    if ok_iter and extracted ~= nil then
        return extracted[1], extracted[2]
    end

    return nil, nil
end


local function get_log_size_bytes()
    if type(diag.logBytes) == "number" and diag.logBytes > 0 then
        return diag.logBytes
    end

    local size = 0
    pcall(function()
        local file = io.open(log_path, "rb")
        if file ~= nil then
            size = file:seek("end") or 0
            file:close()
        end
    end)
    return size

end

local function close_log_file()
    if diag.logFile ~= nil then
        pcall(function()
            diag.logFile:close()
        end)
        diag.logFile = nil
    end
end

local function open_log_file(mode)
    local file, open_err = io.open(log_path, mode)
    if file == nil then
        diag.lastWriteError = tostring(open_err or ("io.open failed for " .. tostring(log_path)))
        diag.logWriteFailed = true
        return nil
    end

    diag.logFile = file
    diag.logWriteFailed = false
    diag.lastWriteError = nil
    return file
end

local function ensure_log_file(mode)
    if diag.logFile ~= nil then
        return diag.logFile
    end
    return open_log_file(mode or "ab")
end

local function append_line(level, message, force_write)

    if not diag.enabled and not force_write then
        return
    end

    local line = os.date("%Y-%m-%d %H:%M:%S") .. " [" .. tostring(level) .. "] " .. tostring(message)

    local payload = line .. "\n"

    if diag.logBytes == 0 then
        diag.logBytes = get_log_size_bytes()
    end

    local need_rollover = (diag.logBytes + #payload) >= MAX_LOG_BYTES
    if need_rollover then
        close_log_file()
        local file = open_log_file("wb")
        if file ~= nil then
            local rollover_line = "[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. DIAG_LOG_NAME .. " rollover\n"
            local ok_rollover, rollover_err = pcall(function()
                file:write(rollover_line)
                file:flush()
            end)
            if ok_rollover then
                diag.logBytes = #rollover_line
            else
                diag.lastWriteError = tostring(rollover_err)
                diag.logWriteFailed = true
                return
            end
        else
            return
        end
    end

    local file = ensure_log_file("ab")
    if file == nil then
        return
    end

    local ok_write, write_err = pcall(function()
        file:write(payload)
        file:flush()
    end)
    if ok_write then
        diag.logBytes = diag.logBytes + #payload
        diag.lastWriteError = nil
        diag.logWriteFailed = false
    else
        diag.lastWriteError = tostring(write_err)
        diag.logWriteFailed = true
        close_log_file()
    end
end

local function clear_log_file()
    close_log_file()

    local ok_clear, clear_err = pcall(function()
        local file = open_log_file("wb")
        if file == nil then
            error("io.open failed for " .. tostring(log_path))
        end
        file:flush()
    end)

    if ok_clear then
        diag.logBytes = 0
    end
    diag.lastWriteError = ok_clear and nil or tostring(clear_err)
    diag.lastLogClearedAt = ok_clear and os.date("%Y-%m-%d %H:%M:%S") or diag.lastLogClearedAt
    return ok_clear, clear_err
end

local function build_runtime_state_key(probe, state)
    local controllers = probe and probe.controllers or nil
    local controller_count = type(controllers) == "table" and #controllers or 0
    local tick_source = diag.enhancer and diag.enhancer._last_tick_source or "nil"
    local fallback_active = diag.enhancer and diag.enhancer._fallback_active or false

    return table.concat({
        "runtime=" .. tostring(probe and probe.runtimeName or "nil"),
        "hmdActive=" .. tostring(probe and probe.hmdActive or false),
        "usingControllers=" .. tostring(probe and probe.usingControllers or false),
        "controllerCount=" .. tostring(controller_count),
        "hmdPose=" .. tostring(probe and probe.hmdPos ~= nil or false),
        "leftPose=" .. tostring(probe and probe.leftPos ~= nil or false),
        "rightPose=" .. tostring(probe and probe.rightPos ~= nil or false),
        "stateMounted=" .. tostring(state and state.isMounted or false),
        "stateControllers=" .. tostring(state and state.usingControllers or false),
        "stateTriggerHandle=" .. tostring(state and state.handleStatus and state.handleStatus.trigger or false),
        "stateGripHandle=" .. tostring(state and state.handleStatus and state.handleStatus.grip or false),
        "tickSource=" .. tostring(tick_source),
        "fallbackActive=" .. tostring(fallback_active),
    }, " | ")
end

local try_attach_enhancer
local get_environment
local probe_vrmod
local dump_snapshot

local function maybe_log_runtime_transition(reason)
    if not diag.enabled then
        return
    end

    local env = diag.enhancer and diag.enhancer.environment or nil
    if env == nil then
        env = select(1, get_environment())
    end

    local state = env and env.state or nil
    local probe = probe_vrmod()
    local runtime_state_key = build_runtime_state_key(probe, state)
    if runtime_state_key == diag.lastRuntimeStateKey then
        return
    end

    diag.lastRuntimeStateKey = runtime_state_key
    dump_snapshot(reason or "runtime_transition", false)
end

local function maybe_log_periodic_telemetry()
    if not diag.enabled then
        return
    end

    local now = os.clock()
    if diag.lastTelemetryAt ~= nil and (now - diag.lastTelemetryAt) < TELEMETRY_INTERVAL_SEC then
        return
    end

    diag.lastTelemetryAt = now
    dump_snapshot("telemetry", false)
end

local function maybe_log_weapon_transition(reason)
    if not diag.enabled then
        return
    end

    local weapon_snapshot = get_weapon_diag_snapshot()
    local current_aim_mode = diag.enhancer and diag.enhancer.aimMode and diag.enhancer.aimMode.current or nil
    local current_aim_command = diag.enhancer and diag.enhancer.getCurrentAimCommand and diag.enhancer:getCurrentAimCommand() or "nil"
    local last_input_aim_mode = rawget(_G, "VR_LAST_SIMINPUT_AIM_MODE")
    local last_input_command = rawget(_G, "VR_LAST_SIMINPUT_COMMAND")
    local aim_mode = diag.enhancer and diag.enhancer.aimMode or nil
    local weapon_state_key = build_weapon_state_key(weapon_snapshot)
    if weapon_state_key == diag.lastWeaponStateKey then
        return
    end

    diag.lastWeaponStateKey = weapon_state_key
    append_line("WEAPON", table.concat({
        "reason=" .. tostring(reason or "weapon_transition"),
        "weaponId=" .. tostring(weapon_snapshot.weaponId or "nil"),
        "weaponDisplayName=" .. tostring(weapon_snapshot.weaponDisplayName or "nil"),
    }, " | "), false)
end

local MERGED_PAD_BUTTON_PROBE = {
    { code = 0x00100000, label = "EmuLup" },
    { code = 0x00200000, label = "EmuLright" },
    { code = 0x00400000, label = "EmuLdown" },
    { code = 0x00800000, label = "EmuLleft" },
    { code = 0x01000000, label = "EmuRup" },
    { code = 0x02000000, label = "EmuRright" },
    { code = 0x04000000, label = "EmuRdown" },
    { code = 0x08000000, label = "EmuRleft" },
    { code = 0x00001000, label = "LStickPush" },
    { code = 0x00002000, label = "RStickPush" },
    { code = 0x00020000, label = "Decide" },
    { code = 0x00040000, label = "Cancel" },
}

local MERGED_PAD_STICK_METHOD_PAIRS = {
    { "get_LStick", "get_RStick" },
    { "getLStick", "getRStick" },
    { "get_LStickRaw", "get_RStickRaw" },
}

local function try_pad_is_down(pad_device, is_down_method, code)
    if pad_device == nil or is_down_method == nil or code == nil then
        return false
    end
    local ok, result = pcall(function()
        return is_down_method:call(pad_device, code)
    end)
    return ok and result == true
end

local function try_read_merged_stick(pad_device, pad_device_td, method_name)
    if pad_device == nil or pad_device_td == nil or type(method_name) ~= "string" then
        return nil, nil
    end
    local method = pad_device_td:get_method(method_name)
    if method == nil then
        return nil, nil
    end
    local ok, value = pcall(function()
        return method:call(pad_device)
    end)
    if not ok or value == nil then
        return nil, tostring(value)
    end
    if type(value) == "number" then
        return { x = value, y = 0.0 }, method_name
    end
    if type(value) == "table" and (value.x ~= nil or value.y ~= nil) then
        return { x = tonumber(value.x) or 0.0, y = tonumber(value.y) or 0.0 }, method_name
    end
    return { raw = tostring(value) }, method_name
end

local function probe_merged_gamepad()
    local snapshot = {
        available = false,
        error = "not_probed",
        hasSingleton = false,
        hasMergedDevice = false,
        stickMethod = nil,
        lstick = nil,
        rstick = nil,
        buttons = {},
        activeButtonLabels = {},
        keyboardDevice = false,
        mouseDevice = false,
        mouseLeftDown = false,
        mouseRightDown = false,
    }

    if sdk == nil then
        snapshot.error = "no_sdk"
        return snapshot
    end

    local pad_singleton = sdk.get_native_singleton("via.hid.GamePad")
    local pad_typedef = sdk.find_type_definition("via.hid.GamePad")
    local pad_device_td = sdk.find_type_definition("via.hid.GamePadDevice")
    if pad_singleton == nil or pad_typedef == nil or pad_device_td == nil then
        snapshot.error = "typedef_missing"
        return snapshot
    end

    snapshot.hasSingleton = true
    local ok_pad, pad_device = pcall(sdk.call_native_func, pad_singleton, pad_typedef, "get_MergedDevice")
    if not ok_pad or pad_device == nil then
        snapshot.error = "merged_device_nil"
        return snapshot
    end

    snapshot.hasMergedDevice = true
    snapshot.available = true
    snapshot.error = nil

    local is_down_method = pad_device_td:get_method("isDown(via.hid.GamePadButton)")
    for _, entry in ipairs(MERGED_PAD_BUTTON_PROBE) do
        local down = try_pad_is_down(pad_device, is_down_method, entry.code)
        snapshot.buttons[entry.label] = down
        if down then
            snapshot.activeButtonLabels[#snapshot.activeButtonLabels + 1] = entry.label
        end
    end

    for _, pair in ipairs(MERGED_PAD_STICK_METHOD_PAIRS) do
        local lstick, lerr = try_read_merged_stick(pad_device, pad_device_td, pair[1])
        local rstick = try_read_merged_stick(pad_device, pad_device_td, pair[2])
        if lstick ~= nil or rstick ~= nil then
            snapshot.lstick = lstick
            snapshot.rstick = rstick
            snapshot.stickMethod = pair[1]
            break
        end
        if lerr ~= nil and snapshot.stickMethod == nil then
            snapshot.stickMethod = pair[1] .. ":" .. tostring(lerr)
        end
    end

    local keyboard_singleton = sdk.get_native_singleton("via.hid.Keyboard")
    local keyboard_typedef = sdk.find_type_definition("via.hid.Keyboard")
    local keyboard_device_td = sdk.find_type_definition("via.hid.KeyboardDevice")
    if keyboard_singleton ~= nil and keyboard_typedef ~= nil and keyboard_device_td ~= nil then
        local ok_kb, kb_device = pcall(sdk.call_native_func, keyboard_singleton, keyboard_typedef, "get_Device")
        snapshot.keyboardDevice = ok_kb and kb_device ~= nil
    end

    local mouse_singleton = sdk.get_native_singleton("via.hid.Mouse")
    local mouse_typedef = sdk.find_type_definition("via.hid.Mouse")
    local mouse_device_td = sdk.find_type_definition("via.hid.MouseDevice")
    if mouse_singleton ~= nil and mouse_typedef ~= nil and mouse_device_td ~= nil then
        local ok_mouse, mouse_device = pcall(sdk.call_native_func, mouse_singleton, mouse_typedef, "get_Device")
        snapshot.mouseDevice = ok_mouse and mouse_device ~= nil
        if ok_mouse and mouse_device ~= nil then
            local ok_left, left_down = pcall(function() return mouse_device:isDown(1) end)
            local ok_right, right_down = pcall(function() return mouse_device:isDown(2) end)
            snapshot.mouseLeftDown = ok_left and left_down == true
            snapshot.mouseRightDown = ok_right and right_down == true
        end
    end

    return snapshot
end

probe_vrmod = function()
    local vr = rawget(_G, "vrmod")
    local snapshot = {
        hasVrmod = vr ~= nil,
        runtimeName = "unavailable",
        isOpenXR = false,
        hasVigem = rawget(_G, "vigem") ~= nil,
        bindingsAlive = rawget(_G, "__vr_bindings_alive"),
        bindingsHasVigem = rawget(_G, "__vr_bindings_has_vigem"),
        bindingsInitOk = rawget(_G, "__vr_bindings_init_ok"),
        bindingsVigemInitOk = rawget(_G, "__vr_bindings_vigem_init_ok"),
        bindingsLastError = rawget(_G, "__vr_bindings_last_error"),
        bindingsAxisOkFrames = rawget(_G, "__vr_bindings_axis_ok_frames"),
        bindingsAxisFailFrames = rawget(_G, "__vr_bindings_axis_fail_frames"),
        bindingsAxisFailStreak = rawget(_G, "__vr_bindings_axis_fail_streak"),
        bindingsWriteFailed = rawget(_G, "__vr_bindings_write_failed"),
        bindingsAxisLastError = rawget(_G, "__vr_bindings_axis_last_error"),
        bindingsLastAxes = rawget(_G, "__vr_bindings_last_axes"),
        bindingsForceMenu = rawget(_G, "__vr_bindings_force_menu"),
        hmdActive = false,
        usingControllers = false,
        controllers = nil,
        leftJoystick = nil,
        rightJoystick = nil,
        actionTrigger = nil,
        actionGrip = nil,
        actionA = nil,
        actionB = nil,
        actionJoystickClick = nil,
        hasApplyHaptics = false,
        hmdPos = nil,
        hmdRot = nil,
        leftPos = nil,
        leftRot = nil,
        rightPos = nil,
        rightRot = nil,
        standingOrigin = nil,
        rotationOffset = nil,

    }

    if vr == nil then
        return snapshot
    end

    local ok_xr, is_xr = safe_call(vr, "is_openxr_loaded")
    snapshot.isOpenXR = ok_xr and is_xr or false
    snapshot.runtimeName = snapshot.isOpenXR and "openxr" or "openvr"

    local ok_hmd, hmd_active = safe_call(vr, "is_hmd_active")
    snapshot.hmdActive = ok_hmd and hmd_active or false

    local ok_ctrls_active, using_controllers = safe_call(vr, "is_using_controllers")
    snapshot.usingControllers = ok_ctrls_active and using_controllers or false

    local ok_ctrls, controllers = safe_call(vr, "get_controllers")
    if ok_ctrls then
        local left_index, right_index = normalize_controller_indices(controllers)
        if left_index ~= nil or right_index ~= nil then
            snapshot.controllers = { left_index, right_index }
        end
    end

    local ok_left_js, left_js = safe_call(vr, "get_left_joystick")
    snapshot.leftJoystick = ok_left_js and left_js or nil

    local ok_right_js, right_js = safe_call(vr, "get_right_joystick")
    snapshot.rightJoystick = ok_right_js and right_js or nil

    local ok_trigger, action_trigger = safe_call(vr, "get_action_trigger")
    snapshot.actionTrigger = ok_trigger and action_trigger or nil

    local ok_grip, action_grip = safe_call(vr, "get_action_grip")
    snapshot.actionGrip = ok_grip and action_grip or nil

    local ok_a, action_a = safe_call(vr, "get_action_a_button")
    snapshot.actionA = ok_a and action_a or nil

    local ok_b, action_b = safe_call(vr, "get_action_b_button")
    snapshot.actionB = ok_b and action_b or nil

    local ok_js_click, action_js_click = safe_call(vr, "get_action_joystick_click")
    snapshot.actionJoystickClick = ok_js_click and action_js_click or nil

    snapshot.hasApplyHaptics = type(vr.apply_haptic_vibration) == "function"

    local ok_hmd_pos, hmd_pos = safe_call(vr, "get_position", 0)
    if ok_hmd_pos then
        snapshot.hmdPos = hmd_pos
    end

    local ok_hmd_rot, hmd_rot = safe_call(vr, "get_rotation", 0)
    if ok_hmd_rot then
        snapshot.hmdRot = hmd_rot
    end

    local ok_so, standing_origin = safe_call(vr, "get_standing_origin")
    if ok_so then
        snapshot.standingOrigin = standing_origin
    end

    local ok_ro, rotation_offset = safe_call(vr, "get_rotation_offset")
    if ok_ro then
        snapshot.rotationOffset = rotation_offset
    end

    if snapshot.controllers ~= nil then
        local left_index = snapshot.controllers[1]
        local right_index = snapshot.controllers[2]

        if left_index ~= nil then
            local ok_left_pos, left_pos = safe_call(vr, "get_position", left_index)
            local ok_left_rot, left_rot = safe_call(vr, "get_rotation", left_index)
            if ok_left_pos then
                snapshot.leftPos = left_pos
            end
            if ok_left_rot then
                snapshot.leftRot = left_rot
            end
        end

        if right_index ~= nil then
            local ok_right_pos, right_pos = safe_call(vr, "get_position", right_index)
            local ok_right_rot, right_rot = safe_call(vr, "get_rotation", right_index)
            if ok_right_pos then
                snapshot.rightPos = right_pos
            end
            if ok_right_rot then
                snapshot.rightRot = right_rot

            end
        end
    end

    return snapshot
end


local function find_loaded_enhancer()
    local enhancer = rawget(_G, "VR_ENHANCER")
    if type(enhancer) == "table" then
        return enhancer
    end

    enhancer = rawget(_G, "RE_GESTURES_ENHANCER")
    if type(enhancer) == "table" then
        return enhancer
    end

    return nil
end
get_environment = function()
    if try_attach_enhancer ~= nil then
        try_attach_enhancer()
    end

    local enhancer = diag.enhancer or find_loaded_enhancer()
    if type(enhancer) == "table" then
        return enhancer.environment, enhancer
    end
    return nil, nil
end

local function get_haptics_runtime()
    loadHapticFeedbackModules()
    if haptics_driver == nil then
        return nil, nil, "RE_05_haptics_missing"
    end
    return haptics_driver, hapticFeedbackModule, nil
end

local function getHapticFeedbackServiceStatus()
    loadHapticFeedbackModules()
    if haptics_driver ~= nil and type(haptics_driver.getServiceStatus) == "function" then
        local ok, status = pcall(haptics_driver.getServiceStatus)
        if ok and type(status) == "table" then
            return status
        end
    end
    return {
        startup = { played = false, reason = "disabled_by_design" },
        playback = {},
        bridge = { available = false, connected = false, phase = "missing" },
        driver = false,
    }
end

local function getHapticFeedbackRoutingState()
    loadHapticFeedbackModules()
    if hapticFeedbackModule ~= nil and type(hapticFeedbackModule.getState) == "function" then
        local ok, state = pcall(hapticFeedbackModule.getState)
        if ok and type(state) == "table" then
            return state
        end
    end
    local snapshot = rawget(_G, "HAPTIC_FEEDBACK_STATE")
    if type(snapshot) == "table" then
        return {
            weaponId = snapshot.weaponId,
            weaponDisplayName = snapshot.weaponDisplayName,
            weaponClass = snapshot.weaponClass,
            groupKey = snapshot.groupKey,
            weaponSource = snapshot.weaponSource,
            classSource = snapshot.classSource,
            hapticRoutingMode = snapshot.hapticRoutingMode,
            lastSlotHapticClass = snapshot.lastSlotHapticClass,
        }
    end
    return {
        hapticRoutingMode = vr_globals.getHapticRoutingMode(),
        lastSlotHapticClass = vr_globals.getLastSlotHapticClass(),
    }
end

local function get_haptic_playback_snapshot()
    local service_status = getHapticFeedbackServiceStatus()
    if type(service_status.playback) == "table" then
        return service_status.playback
    end
    return {
        currentPatternName = rawget(_G, "currentHapticFeedbackPatternName"),
        previousPatternName = rawget(_G, "previousHapticFeedbackPatternName") or rawget(_G, "lastPlayedHapticFeedbackPatternName"),
    }
end

local function load_test_sequence_entries()
    local haptics, _, reason = get_haptics_runtime()
    if reason ~= nil then
        return nil, reason
    end

    if type(haptics.listTactFiles) ~= "function" then
        return nil, "listTactFiles_missing"
    end

    local files, list_error, folder_path = haptics.listTactFiles(diag.testSequence.folder)
    diag.testSequence.folderPath = folder_path
    if type(files) ~= "table" then
        return nil, list_error or "no_tact_files_found"
    end

    local entries = {}
    for _, file_name in ipairs(files) do
        local relative_tact = diag.testSequence.folder .. "/" .. file_name
        local info = nil
        if type(haptics.inspectTact) == "function" then
            local ok, inspected = pcall(haptics.inspectTact, relative_tact)
            if ok and type(inspected) == "table" then
                info = inspected
            end
        end

        entries[#entries + 1] = {
            key = "__diag_test__/" .. relative_tact,
            tactFile = relative_tact,
            displayName = type(info) == "table" and info.displayName or tostring(file_name):gsub("%.tact$", ""),
            duration = type(info) == "table" and (tonumber(info.duration) or 0.0) or 0.0,
            projectJson = type(info) == "table" and info.projectJson or nil,
        }
    end

    if #entries == 0 then
        return nil, "no_tact_files_found"
    end

    return entries, nil
end

local function play_test_sequence_entry(entry)
    local haptics, _, reason = get_haptics_runtime()
    if reason ~= nil then
        return false, reason
    end

    if type(haptics.play) ~= "function" then
        return false, "play_missing"
    end

    local play_key = tostring(entry.tactFile or entry.key or "")
    if play_key == "" then
        return false, "tact_key_missing"
    end

    if haptics.play(play_key, "enter") ~= true then
        return false, "play_failed"
    end

    local wait_duration = tonumber(entry.duration) or 0.0
    if wait_duration <= 0.0 then
        wait_duration = TEST_SEQUENCE_RETRY_SEC
    end

    diag.testSequence.currentName = entry.displayName
    diag.testSequence.playedCount = (diag.testSequence.playedCount or 0) + 1
    diag.testSequence.nextAt = os.clock() + wait_duration + TEST_SEQUENCE_GAP_SEC
    return true, nil
end

local function set_test_sequence_enabled(enabled)
    local sequence = diag.testSequence
    if not enabled then
        sequence.enabled = false
        sequence.currentName = nil
        sequence.nextAt = 0.0
        sequence.lastError = nil
        append_line("HAPTIC", "test tact sequence disabled", true)
        return false
    end

    local entries, load_error = load_test_sequence_entries()
    sequence.entries = entries or {}
    sequence.index = 1
    sequence.nextAt = 0.0
    sequence.currentName = nil
    sequence.playedCount = 0
    sequence.lastError = load_error
    sequence.enabled = entries ~= nil

    if sequence.enabled then
        append_line("HAPTIC", "test tact sequence enabled count=" .. tostring(#sequence.entries), true)
    else
        append_line("HAPTIC", "test tact sequence unavailable reason=" .. tostring(load_error), true)
    end

    return sequence.enabled
end

local function step_test_sequence()
    local sequence = diag.testSequence
    if sequence.enabled ~= true then
        return
    end

    local now = os.clock()
    if now < (sequence.nextAt or 0.0) then
        return
    end

    if type(sequence.entries) ~= "table" or #sequence.entries == 0 then
        local entries, load_error = load_test_sequence_entries()
        if entries == nil then
            sequence.lastError = load_error
            sequence.nextAt = now + TEST_SEQUENCE_RETRY_SEC
            return
        end
        sequence.entries = entries
        sequence.index = 1
        sequence.lastError = nil
    end

    local entry = sequence.entries[sequence.index]
    if entry == nil then
        sequence.index = 1
        entry = sequence.entries[1]
    end
    if entry == nil then
        sequence.lastError = "no_tact_files_found"
        sequence.nextAt = now + TEST_SEQUENCE_RETRY_SEC
        return
    end

    local played, play_error = play_test_sequence_entry(entry)
    if not played then
        sequence.lastError = play_error
        sequence.nextAt = now + TEST_SEQUENCE_RETRY_SEC
        return
    end

    sequence.lastError = nil
    sequence.index = sequence.index + 1
    if sequence.index > #sequence.entries then
        sequence.index = 1
    end
end

local function refresh_environment_state()
    local env = diag.enhancer and diag.enhancer.environment or nil
    if env == nil then
        env = select(1, get_environment())
    end
    if env == nil then
        return false, "environment_missing"
    end

    env:refreshHandles()
    env:sampleVRState()
    return true, env
end

local function fire_test_haptic(left_hand)
    local ok, env_or_reason = refresh_environment_state()
    if not ok then
        diag.lastManualHaptic = {
            success = false,
            leftHand = left_hand and true or false,
            reason = env_or_reason,
        }
        append_line("HAPTIC", env_or_reason, true)
        return false
    end

    local env = env_or_reason
    local success = env:applyControllerVibration(left_hand and true or false, 0.08, 160.0, 0.9)
    diag.lastManualHaptic = {
        success = success and true or false,
        leftHand = left_hand and true or false,
        reason = env.state.lastHaptic and env.state.lastHaptic.reason or "unknown",
    }
    append_line("HAPTIC", "manual pulse left=" .. tostring(left_hand and true or false) .. " success=" .. tostring(success) .. " reason=" .. tostring(diag.lastManualHaptic.reason), true)
    return success
end

dump_snapshot = function(reason, force_write)
    local env = diag.enhancer and diag.enhancer.environment or nil
    if env == nil then
        env = select(1, get_environment())
    end

    local state = env and env.state or nil
    local input = env and env.input or nil
    local probe = probe_vrmod()
    local merged = probe_merged_gamepad()
    local vr = rawget(_G, "vrmod")
    local gui_visible = get_gui_visible_situation()
    local ok_pause_pending, pause_pending = safe_call(vr, "should_handle_pause")
    local probe_indices = probe and probe.controllers or nil
    local state_indices = state and state.controllerIndices or nil
    local head_pose = state and state.headPose or nil
    local left_pose = state and state.leftTouchPose or nil
    local right_pose = state and state.rightTouchPose or nil
    local support_docked = vr_globals.isSupportDocked()
    local two_hand_aiming = vr_globals.isTwoHandAimingActive()
    local pullpin_active = vr_globals.isPullpinActive()
    local weapon_snapshot = get_weapon_diag_snapshot()
    local haptic_service_status = getHapticFeedbackServiceStatus()
    local haptic_config = type(haptic_service_status.config) == "table" and haptic_service_status.config or {}
    local haptic_bridge = type(haptic_service_status.bridge) == "table" and haptic_service_status.bridge or {}
    local haptic_startup = type(haptic_service_status.startup) == "table" and haptic_service_status.startup or {}
    local haptic_last_init = type(haptic_service_status.lastInit) == "table" and haptic_service_status.lastInit or {}
    local last_slot_event = vr_globals.getLastWeaponSlotEvent()
    local current_aim_mode = diag.enhancer and diag.enhancer.aimMode and diag.enhancer.aimMode.current or nil
    local current_aim_command = diag.enhancer and diag.enhancer.getCurrentAimCommand and diag.enhancer:getCurrentAimCommand() or "nil"
    local last_input_aim_mode = rawget(_G, "VR_LAST_SIMINPUT_AIM_MODE")
    local last_input_command = rawget(_G, "VR_LAST_SIMINPUT_COMMAND")

    local message = table.concat({
        "reason=" .. tostring(reason),
        "enabled=" .. tostring(diag.enabled),
        "vrmod=" .. tostring(probe.hasVrmod),
        "runtime=" .. tostring(probe.runtimeName),
        "hmdActive=" .. tostring(probe.hmdActive),
        "usingControllers=" .. tostring(probe.usingControllers),
        "rawControllerIndices=" .. fmt_indices(probe_indices),
        "stateControllerIndices=" .. fmt_indices(state_indices),
        "leftJoystickRef=" .. fmt_handle_ref(probe.leftJoystick),
        "rightJoystickRef=" .. fmt_handle_ref(probe.rightJoystick),
        "actionTriggerRef=" .. fmt_handle_ref(probe.actionTrigger),
        "actionGripRef=" .. fmt_handle_ref(probe.actionGrip),
        "actionARef=" .. fmt_handle_ref(probe.actionA),
        "actionBRef=" .. fmt_handle_ref(probe.actionB),
        "actionStickClickRef=" .. fmt_handle_ref(probe.actionJoystickClick),
        "leftJoystickHandle=" .. tostring(probe.leftJoystick ~= nil),
        "rightJoystickHandle=" .. tostring(probe.rightJoystick ~= nil),
        "actionTriggerHandle=" .. tostring(probe.actionTrigger ~= nil),
        "actionGripHandle=" .. tostring(probe.actionGrip ~= nil),
        "actionAHandle=" .. tostring(probe.actionA ~= nil),
        "actionBHandle=" .. tostring(probe.actionB ~= nil),
        "actionStickClickHandle=" .. tostring(probe.actionJoystickClick ~= nil),
        "backend=" .. tostring(input and input.backendName or "nil"),
        "backendAvailable=" .. tostring(input and input.backendAvailable or false),
        "backendError=" .. summarize_error(input and input.backendError or "nil"),
        "preferredBackend=" .. tostring(input and input.preferredBackendName or "nil"),
        "preferredBackendAvailable=" .. tostring(input and input.preferredBackendAvailable or false),
        "preferredBackendError=" .. summarize_error(input and input.preferredBackendError or "nil"),
        "backendProbe.luaBridgeAvailable=" .. tostring(input and input.backendProbe and input.backendProbe.luaBridgeAvailable or false),
        "backendProbe.luaBridgeGlobal=" .. tostring(input and input.backendProbe and input.backendProbe.luaBridgeGlobal or "nil"),
        "backendProbe.luaBridgeError=" .. summarize_error(input and input.backendProbe and input.backendProbe.luaBridgeError or "nil"),
        "backendProbe.queueBridgeAvailable=" .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeAvailable or false),
        "backendProbe.queueBridgeReady=" .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeReady or false),
        "backendProbe.queueBridgeMode=" .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeMode or "nil"),
        "backendProbe.queueBridgePhase=" .. tostring(input and input.backendProbe and input.backendProbe.queueBridgePhase or "nil"),
        "backendProbe.queueBridgeError=" .. summarize_error(input and input.backendProbe and input.backendProbe.queueBridgeError or "nil"),
        "backendProbe.queueBridgeLastError=" .. summarize_error(input and input.backendProbe and input.backendProbe.queueBridgeLastError or "nil"),
        "backendProbe.queueBridgeStatusPath=" .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeStatusPath or "nil"),
        "backendProbe.queueBridgeQueuePath=" .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeQueuePath or "nil"),
        "backendProbe.simInputDllPath=" .. tostring(input and input.backendProbe and input.backendProbe.simInputDllPath or "nil"),
        "backendProbe.simInputLoadMode=" .. tostring(input and input.backendProbe and input.backendProbe.simInputLoadMode or "nil"),
        "backendProbe.simInputLoadError=" .. summarize_error(input and input.backendProbe and input.backendProbe.simInputLoadError or "nil"),
        "guiVisible=" .. tostring(gui_visible),
        "pausePending=" .. tostring(ok_pause_pending and pause_pending or false),
        "motionPaused=" .. tostring(vr_globals.isMotionPaused()),
        "supportDocked=" .. tostring(support_docked),
        "twoHandAiming=" .. tostring(two_hand_aiming),
        "pullpinActive=" .. tostring(pullpin_active),
        "stateMounted=" .. tostring(state and state.isMounted or false),
        "stateCalibrated=" .. tostring(state and state.calibrated or false),
        "stateHandleTrigger=" .. tostring(state and state.handleStatus and state.handleStatus.trigger or false),
        "stateHandleGrip=" .. tostring(state and state.handleStatus and state.handleStatus.grip or false),
        "stateHandleA=" .. tostring(state and state.handleStatus and state.handleStatus.aButton or false),
        "stateHandleB=" .. tostring(state and state.handleStatus and state.handleStatus.bButton or false),
        "stateHandleStickClick=" .. tostring(state and state.handleStatus and state.handleStatus.joystickClick or false),
        "tickSource=" .. tostring(diag.enhancer and diag.enhancer._last_tick_source or "nil"),
        "fallbackActive=" .. tostring(diag.enhancer and diag.enhancer._fallback_active or false),
        "aimModeCurrent=" .. tostring(current_aim_mode or "nil"),
        "currentAimCommand=" .. tostring(current_aim_command),
        "lastInputAimMode=" .. tostring(last_input_aim_mode or "nil"),
        "lastInputCommand=" .. tostring(last_input_command or "nil"),
        "stateControllers=" .. tostring(state and state.usingControllers or false),
        "hmdPos=" .. fmt_vec3(probe.hmdPos),
        "leftPos=" .. fmt_vec3(probe.leftPos),
        "rightPos=" .. fmt_vec3(probe.rightPos),
        "envHeadPos=" .. fmt_vec3(head_pose and head_pose.position),
        "envLeftPos=" .. fmt_vec3(left_pose and left_pose.position),
        "envRightPos=" .. fmt_vec3(right_pose and right_pose.position),
        "envHeadRot=" .. fmt_quat(head_pose and head_pose.rotation),
        "envLeftRot=" .. fmt_quat(left_pose and left_pose.rotation),
        "envRightRot=" .. fmt_quat(right_pose and right_pose.rotation),
        "leftStickAxes=" .. fmt_axes(state and state.leftStickAxes),
        "rightStickAxes=" .. fmt_axes(state and state.rightStickAxes),
        "leftTrigger=" .. fmt_num(state and state.leftTrigger or nil),
        "rightTrigger=" .. fmt_num(state and state.rightTrigger or nil),
        "leftGrip=" .. fmt_num(state and state.leftGrip or nil),
        "rightGrip=" .. fmt_num(state and state.rightGrip or nil),
        "leftStickClick=" .. fmt_num(state and state.leftStick or nil),
        "rightStickClick=" .. fmt_num(state and state.rightStick or nil),
        "xButton=" .. fmt_num(state and state.x or nil),
        "yButton=" .. fmt_num(state and state.y or nil),
        "aButton=" .. fmt_num(state and state.a or nil),
        "bButton=" .. fmt_num(state and state.b or nil),
        "weaponId=" .. tostring(weapon_snapshot.weaponId or "nil"),
        "weaponDisplayName=" .. tostring(weapon_snapshot.weaponDisplayName or "nil"),
        "hapticRoutingMode=" .. tostring(vr_globals.getHapticRoutingMode()),
        "lastSlotHapticClass=" .. tostring(vr_globals.getLastSlotHapticClass() or "nil"),
        "hapticDriverLoaded=" .. tostring(haptic_service_status.driver == true),
        "hapticEnabled=" .. tostring(haptic_config.enabled == true),
        "hapticDevice=" .. tostring(haptic_config.device or "nil"),
        "hapticActiveDevice=" .. tostring(haptic_service_status.activeDevice or "nil"),
        "hapticLastInitSuccess=" .. tostring(haptic_last_init.success == true),
        "hapticLastInitReason=" .. tostring(haptic_last_init.reason or "nil"),
        "hapticLastInitDevice=" .. tostring(haptic_last_init.device or "nil"),
        "hapticBridgeAvailable=" .. tostring(haptic_bridge.available),
        "hapticBridgeDevice=" .. tostring(haptic_bridge.device or "nil"),
        "hapticBridgeName=" .. tostring(haptic_bridge.name or "nil"),
        "hapticBridgeConnected=" .. tostring(haptic_bridge.connected),
        "hapticBridgePhase=" .. tostring(haptic_bridge.phase or "nil"),
        "hapticBridgeMode=" .. tostring(haptic_bridge.mode or "nil"),
        "hapticStartupPlayed=" .. tostring(haptic_startup.played),
        "hapticStartupReason=" .. tostring(haptic_startup.reason or "nil"),
        "weaponSlotRegion=" .. tostring(last_slot_event.region or "nil"),
        "weaponSlotBinding=" .. tostring(last_slot_event.binding or "nil"),
        "equipShortcut=" .. weapon_slot_equip_shortcut_display(last_slot_event),
        "weaponSlotSource=" .. tostring(last_slot_event.source or "nil"),
        "weaponSlotAt=" .. fmt_num(last_slot_event.at),
        "hasVigem=" .. tostring(probe.hasVigem),
        "bindingsAlive=" .. tostring(probe.bindingsAlive),
        "bindingsHasVigem=" .. tostring(probe.bindingsHasVigem),
        "bindingsInitOk=" .. tostring(probe.bindingsInitOk),
        "bindingsVigemInitOk=" .. tostring(probe.bindingsVigemInitOk),
        "bindingsLastError=" .. tostring(probe.bindingsLastError or "nil"),
        "bindingsAxisOkFrames=" .. tostring(probe.bindingsAxisOkFrames or 0),
        "bindingsAxisFailFrames=" .. tostring(probe.bindingsAxisFailFrames or 0),
        "bindingsAxisFailStreak=" .. tostring(probe.bindingsAxisFailStreak or 0),
        "bindingsWriteFailed=" .. tostring(probe.bindingsWriteFailed),
        "bindingsAxisLastError=" .. tostring(probe.bindingsAxisLastError or "nil"),
        "bindingsForceMenu=" .. tostring(probe.bindingsForceMenu),
        "mergedAvailable=" .. tostring(merged.available),
        "mergedError=" .. tostring(merged.error or "nil"),
        "mergedStickMethod=" .. tostring(merged.stickMethod or "nil"),
        "mergedLStick=" .. fmt_axes(merged.lstick),
        "mergedRStick=" .. fmt_axes(merged.rstick),
        "mergedEmuActive=" .. table.concat(merged.activeButtonLabels or {}, ","),
        "mergedMouseLeft=" .. tostring(merged.mouseLeftDown),
        "mergedMouseRight=" .. tostring(merged.mouseRightDown),
        "inputChannelRestartCount=" .. tostring(rawget(_G, "__vr_input_channel_restart_count") or 0)
    }, " | ")

    append_line("SNAPSHOT", message, force_write)
end

try_attach_enhancer = function()
    local enhancer = find_loaded_enhancer()
    if type(enhancer) ~= "table" then
        if type(diag.enhancer) ~= "table" then
            diag.enhancer = nil
        end
        return false
    end

    diag.enhancer = enhancer
    diag.lastLoadError = nil
    return true
end

try_attach_enhancer()

if re and re.on_draw_ui and imgui then
    if not rawget(_G, "VR_DIAG_UI_REGISTERED") then
        _G.VR_DIAG_UI_REGISTERED = true
        re.on_draw_ui(function()
        local ok_ui, ui_err = xpcall(function()
            try_attach_enhancer()
            diag.tickCount = diag.tickCount + 1
            maybe_log_runtime_transition("ui_tick")
            maybe_log_weapon_transition("ui_tick")
            maybe_log_periodic_telemetry()
            if not imgui.tree_node(DIAG_PANEL_NAME) then
                return
            end

            local env = diag.enhancer and diag.enhancer.environment or nil
            local state = env and env.state or nil
            local input = env and env.input or nil
            local probe = probe_vrmod()
            local playback_snapshot = get_haptic_playback_snapshot()

            imgui.text("Installed At: " .. tostring(diag.installedAt))
            imgui.text("Log Path: " .. tostring(log_path))
            imgui.text("Tick Count: " .. tostring(diag.tickCount))
            imgui.text("Tick Source: " .. tostring(diag.enhancer and diag.enhancer._last_tick_source or "nil"))
            imgui.text("Fallback Active: " .. tostring(diag.enhancer and diag.enhancer._fallback_active or false))
            imgui.text("Log Enabled: " .. tostring(diag.enabled))
            imgui.text("Log Size: " .. tostring(get_log_size_bytes()) .. " / " .. tostring(MAX_LOG_BYTES))
            imgui.text("Last Write Error: " .. tostring(diag.lastWriteError or "nil"))
            imgui.text("Last Log Cleared: " .. tostring(diag.lastLogClearedAt or "nil"))

            if imgui.button(diag.enabled and "Disable Logging" or "Enable Logging") then
                diag.enabled = not diag.enabled
                _G.RE_GESTURES_DIAG_ENABLED = diag.enabled
                _G.VR_DIAG_ENABLED = diag.enabled
                append_line("INFO", "logging toggled to " .. tostring(diag.enabled), true)
                if diag.enabled then
                    dump_snapshot("toggle_enabled", true)
                end
            end

            if imgui.button("Dump Snapshot") then
                dump_snapshot("button", true)
            end

            if imgui.button("Clear Log") then
                clear_log_file()
            end

            if imgui.button("Log Package Path") then
                append_line("PATH", tostring(package and package.path or "nil"), true)
            end

            

            -- Load / Errors section removed to reduce noise; errors are still logged to file.

            -- VR prob (vrmod Raw Probe) 分支已移除，避免冗余和空值干扰

            if imgui.tree_node("Environment State") then
                -- 1. 环境/命令信息
                if imgui.tree_node("环境/命令信息") then
                    imgui.text("Environment: " .. tostring(env ~= nil))
                    if state ~= nil then
                        imgui.text("hasVrmod: " .. tostring(state.hasVrmod))
                        imgui.text("runtimeName: " .. tostring(state.runtimeName))
                        imgui.text("isOpenXR: " .. tostring(state.isOpenXR))
                    end
                    imgui.tree_pop()
                end

                -- 2. 全局变量 (RE_00_vr_globals 发布的布尔值状态)
                if imgui.tree_node("全局变量") then
                    -- 布尔值全局变量
                    local two_handing = vr_globals.isTwoHandingWeapon()
                    local heal_active = vr_globals.isHealActive()
                    local pullpin_active = vr_globals.isPullpinActive()

                    imgui.text("two_handing_weapon: " .. tostring(two_handing))
                    imgui.text("heal_active: " .. tostring(heal_active))
                    imgui.text("pullpin_active: " .. tostring(pullpin_active))

                    imgui.tree_pop()
                end

                -- 3. 操作与调试按钮
                if imgui.tree_node("操作与调试按钮") then
                    imgui.text("Current Aim Mode: " .. tostring(diag.enhancer and diag.enhancer.aimMode and diag.enhancer.aimMode.current or "nil"))
                    imgui.text("Current Command: " .. tostring(diag.enhancer and diag.enhancer.getCurrentAimCommand and diag.enhancer:getCurrentAimCommand() or "nil"))
                    imgui.text("Last Aim Mode: " .. tostring(rawget(_G, "VR_LAST_SIMINPUT_AIM_MODE") or "nil"))
                    imgui.text("Last Command: " .. tostring(rawget(_G, "VR_LAST_SIMINPUT_COMMAND") or "nil"))
                    imgui.text("Last Command At: " .. tostring(rawget(_G, "VR_LAST_SIMINPUT_COMMAND_AT") or "nil"))
                    imgui.text("Last Command Count: " .. tostring(rawget(_G, "VR_SIMINPUT_COMMAND_COUNT") or 0))
                    imgui.tree_pop()
                end

                -- 4. 头盔/校准与手柄状态
                if imgui.tree_node("头盔/校准与手柄状态") then
                    if state ~= nil then
                        imgui.text("isMounted: " .. tostring(state.isMounted))
                        imgui.text("usingControllers: " .. tostring(state.usingControllers))
                        imgui.text("Observer mode: runtime controls disabled")
                        imgui.text("calibrated: " .. tostring(state.calibrated))
                        imgui.text("standingHeight: " .. fmt_num(state.standingHeight))
                        imgui.text("rollCenter: " .. fmt_num(state.rollCenter))
                        imgui.text("headPose.position: " .. fmt_vec3(state.headPose and state.headPose.position))
                        imgui.text("leftTouchPose.position: " .. fmt_vec3(state.leftTouchPose and state.leftTouchPose.position))
                        imgui.text("rightTouchPose.position: " .. fmt_vec3(state.rightTouchPose and state.rightTouchPose.position))
                    end
                    imgui.tree_pop()
                end

                -- 4. 震动反馈
                if imgui.tree_node("震动反馈") then
                    local service_status = getHapticFeedbackServiceStatus()
                    local routing_state = getHapticFeedbackRoutingState()
                    local config_status = type(service_status.config) == "table" and service_status.config or {}
                    local bridge_status = type(service_status.bridge) == "table" and service_status.bridge or {}
                    local startup_status = type(service_status.startup) == "table" and service_status.startup or {}
                    local last_init = type(service_status.lastInit) == "table" and service_status.lastInit or {}
                    local last_device_change = type(service_status.lastDeviceChange) == "table" and service_status.lastDeviceChange or nil
                    local routing_mode = vr_globals.getHapticRoutingMode()
                    local routing_mode_label = routing_mode == 1 and "slot" or "id"

                    imgui.text("Haptic Feedback enabled: " .. tostring(config_status.enabled == true))
                    imgui.text("Configured device: " .. tostring(config_status.device or "nil"))
                    imgui.text("Active device: " .. tostring(service_status.activeDevice or "nil"))
                    imgui.text("Config path: " .. tostring(config_status.path or "nil"))
                    imgui.text("RE_05 driver.loaded: " .. tostring(service_status.driver == true))
                    imgui.text("lastInit.success: " .. tostring(last_init.success == true))
                    imgui.text("lastInit.reason: " .. tostring(last_init.reason or "nil"))
                    imgui.text("lastInit.device: " .. tostring(last_init.device or "nil"))
                    if type(last_device_change) == "table" then
                        imgui.text("lastDeviceChange: " .. tostring(last_device_change.from or "nil") .. " -> " .. tostring(last_device_change.to or "nil"))
                    end
                    imgui.text("bridge.device: " .. tostring(bridge_status.device or "nil"))
                    imgui.text("bridge.name: " .. tostring(bridge_status.name or "nil"))
                    imgui.text("hapticRoutingMode: " .. tostring(routing_mode) .. " (" .. routing_mode_label .. ")")
                    imgui.text("lastSlotHapticClass: " .. tostring(vr_globals.getLastSlotHapticClass() or "nil"))
                    imgui.text("bridge.available: " .. tostring(bridge_status.available))
                    imgui.text("bridge.connected: " .. tostring(bridge_status.connected))
                    imgui.text("bridge.phase: " .. tostring(bridge_status.phase or "nil"))
                    imgui.text("bridge.mode: " .. tostring(bridge_status.mode or "nil"))
                    imgui.text("bridge.lastError: " .. tostring(bridge_status.lastError or "nil"))
                    imgui.text("bridge.lastCommand: " .. tostring(bridge_status.lastCommand or "nil"))
                    imgui.text("startup.played: " .. tostring(startup_status.played) .. " (init playback off)")
                    imgui.text("startup.reason: " .. tostring(startup_status.reason or "disabled_by_design"))
                    imgui.text("Observer mode: haptic test controls disabled (vest uses currentHapticFeedback above)")
                    if state ~= nil then
                        imgui.text("lastHaptic.success: " .. tostring(state.lastHaptic and state.lastHaptic.success or false))
                        imgui.text("lastHaptic.reason: " .. tostring(state.lastHaptic and state.lastHaptic.reason or "nil"))
                        imgui.text("lastHaptic.leftHand: " .. tostring(state.lastHaptic and state.lastHaptic.leftHand or false))
                        imgui.text("lastHaptic.frequency: " .. fmt_num(state.lastHaptic and state.lastHaptic.frequency or nil))
                        imgui.text("lastHaptic.amplitude: " .. fmt_num(state.lastHaptic and state.lastHaptic.amplitude or nil))
                    end
                    if diag.lastManualHaptic ~= nil then
                        imgui.text("manualHaptic.success: " .. tostring(diag.lastManualHaptic.success))
                        imgui.text("manualHaptic.leftHand: " .. tostring(diag.lastManualHaptic.leftHand))
                        imgui.text("manualHaptic.reason: " .. tostring(diag.lastManualHaptic.reason))
                    end
                    if imgui.tree_node("Last Equip Shortcut") then
                        local slot_event = vr_globals.getLastWeaponSlotEvent()
                        local equip_shortcut = weapon_slot_equip_shortcut_display(slot_event)
                        local expected_shortcut = resolve_weapon_slot_equip_shortcut(slot_event.region, slot_event.binding)
                        imgui.text("gesture_region: " .. format_weapon_slot_region_label(slot_event.region))
                        imgui.text("gesture_binding: " .. tostring(slot_event.binding or "nil"))
                        imgui.text("equip_shortcut: " .. equip_shortcut)
                        if expected_shortcut ~= nil then
                            imgui.text("expected_equip_shortcut: " .. expected_shortcut)
                        end
                        imgui.text("weapon_slot_source: " .. tostring(slot_event.source or "nil"))
                        imgui.text("weapon_slot_at: " .. fmt_num(slot_event.at))
                        if imgui.tree_node("Equip shortcut map") then
                            for _, region_name in ipairs({ "holsterWeaponRight", "shoulderWeaponRight", "chestRight" }) do
                                local bindings = WEAPON_SLOT_EQUIP_SHORTCUT_BY_REGION_BINDING[region_name]
                                if bindings ~= nil then
                                    imgui.text(format_weapon_slot_region_label(region_name))
                                    imgui.indent()
                                    imgui.text("grip -> " .. bindings.grip)
                                    imgui.text("trigger -> " .. bindings.trigger)
                                    imgui.unindent()
                                end
                            end
                            imgui.tree_pop()
                        end
                        imgui.tree_pop()
                    end
                    if imgui.tree_node("Weapon ID router") then
                        if type(routing_state) == "table" then
                            imgui.text("weaponId: " .. tostring(routing_state.weaponId or "nil"))
                            imgui.text("weaponName: " .. tostring(routing_state.weaponDisplayName or vr_globals.getCurrentWeaponDisplayName() or "nil"))
                            imgui.text("weaponClass: " .. tostring(routing_state.weaponClass or "nil"))
                            imgui.text("groupKey: " .. tostring(routing_state.groupKey or "nil"))
                            imgui.text("weaponSource: " .. tostring(routing_state.weaponSource or "nil"))
                            imgui.text("classSource: " .. tostring(routing_state.classSource or "nil"))
                        else
                            imgui.text("routing state: nil")
                        end
                        imgui.text("currentHapticFeedback.patternName: " .. tostring(playback_snapshot.currentPatternName or "nil"))
                        imgui.text("previousHapticFeedback.patternName: " .. tostring(playback_snapshot.previousPatternName or "nil"))
                        imgui.text("lastTouchHaptic.gestureName: " .. tostring(rawget(_G, "lastGestureHaptic") or "nil"))
                        imgui.text("lastTouchHaptic.patternName: " .. tostring(rawget(_G, "lastHapticPatternName") or "nil"))
                        imgui.text("lastTouchHaptic.phase: " .. tostring(rawget(_G, "lastHapticPhase") or "nil"))
                        imgui.tree_pop()
                    end
                    if imgui.tree_node("Damage") then
                        local last_damage = vr_globals.getLastPlayerDamage()
                        imgui.text("damage_kind: " .. tostring(last_damage.damage_kind or "nil"))
                        imgui.text("damage_value: " .. fmt_num(last_damage.damage_value))
                        imgui.text("damage_type: " .. tostring(last_damage.attack_attr or "nil"))
                        local direction_verdict, verdict_kind, verdict_at, verdict_err = get_last_hit_direction_verdict_snapshot()
                        if verdict_err ~= nil then
                            imgui.text_colored("方位结论: 不可用 (" .. tostring(verdict_err) .. ")", 0xFFFF4444)
                        elseif direction_verdict == nil or direction_verdict == "" then
                            imgui.text("方位结论: — (尚无爆炸/钝击记录)")
                        else
                            local verdict_label = tostring(direction_verdict)
                                .. "  [" .. tostring(verdict_kind or "nil") .. ", "
                                .. fmt_seconds_ago(verdict_at) .. "]"
                            imgui.text_colored("方位结论: " .. verdict_label, direction_verdict_color(direction_verdict))
                        end
                        imgui.tree_pop()
                    end

                    if imgui.tree_node("引擎震动") then
                        local engine_vib_diag, engine_vib_reason = get_engine_vibration_diag_snapshot()
                        if engine_vib_diag == nil then
                            imgui.text_colored("RE_11 诊断快照不可用: " .. tostring(engine_vib_reason or "unknown"), 0xFFFF4444)
                        else
                            local counters = type(engine_vib_diag.counters) == "table" and engine_vib_diag.counters or {}
                            local last_event = type(engine_vib_diag.last) == "table" and engine_vib_diag.last or {}

                            imgui.text("Gameplay 镜头白名单门控 (RE_00 <- bindings):")
                            do
                                local gate_toggle_enabled = engine_vib_diag.gameplay_whitelist_gate_enabled ~= false
                                local gate = type(engine_vib_diag.gameplay_gate) == "table" and engine_vib_diag.gameplay_gate or {}
                                local gameplay_active = gate.gameplay_active == true
                                local ks_active = gate.ks_active == true
                                local in_table = gate.controller_in_table == true
                                imgui.text("  RE_11 gate toggle: " .. tostring(gate_toggle_enabled))
                                imgui.text("  ks_ctrl: " .. tostring(gate.ks_ctrl or "nil"))
                                imgui.text("  controller_in_gameplay_table: " .. tostring(in_table))
                                imgui.text("  killswitch_active (参考): " .. tostring(ks_active))
                                imgui.text("  bindings_force_menu: " .. tostring(gate.force_menu == true))
                                if not gate_toggle_enabled then
                                    imgui.text_colored("  gameplay_camera_active: n/a (门控开关已关闭，全部放行)", 0xFFFFAA44)
                                elseif gameplay_active then
                                    imgui.text_colored("  gameplay_camera_active: true (白名单门控生效)", 0xFF44FF44)
                                else
                                    imgui.text_colored("  gameplay_camera_active: false (引擎震动全部放行)", 0xFFFFAA44)
                                end
                            end

                            imgui.separator()
                            local engine_seen = (counters.hook_called or 0) > 0
                            local dll_sent = (counters.submit_frame_ok or 0) > 0
                            if engine_seen and dll_sent then
                                imgui.text_colored("结论: 引擎有发信号，且 RE_11 已向 DLL 成功提交 frame", 0xFF44FF44)
                            elseif engine_seen then
                                imgui.text_colored("结论: 引擎有发信号，但尚未成功 submit_frame", 0xFFFFAA44)
                            else
                                imgui.text_colored("结论: 暂未观察到引擎 playVibration 信号", 0xFFFF8888)
                            end

                            imgui.separator()
                            imgui.text("最近一次事件:")
                            imgui.text("  node: " .. tostring(last_event.node or "none"))
                            imgui.text("  reason: " .. tostring(last_event.reason or ""))
                            imgui.text("  at: " .. fmt_seconds_ago(last_event.at))
                            imgui.text("  hash: " .. fmt_hex32(last_event.hash))
                            imgui.text("  hash_arg_index: " .. tostring(last_event.hash_arg_index or "nil"))
                            imgui.text("  raw_duration_ms: " .. fmt_num(last_event.raw_duration_ms))
                            imgui.text("  duration_ms: " .. fmt_num(last_event.duration_ms))
                            imgui.text("  PowerCurveGain: " .. fmt_num(last_event.power_curve_gain or last_event.gain))
                            imgui.text("  loop: " .. tostring(last_event.loop))
                            imgui.text("  intensity_0_1: " .. fmt_num(last_event.intensity_0_1))
                            imgui.text("  hypocenter_x: " .. fmt_num(last_event.hypocenter_x))
                            imgui.text("  args6_has_value: " .. tostring(last_event.args6_has_value or "nil"))
                            imgui.text("  args6_valid: " .. tostring(last_event.args6_valid or "nil"))
                            imgui.text("  args6_hypocenter_pos: " .. tostring(last_event.args6_hypocenter_pos or "nil"))
                            imgui.text("  gate_reason: " .. tostring(last_event.gate_reason or "nil"))
                            imgui.text("  front_key: " .. tostring(last_event.front_key or "nil"))
                            imgui.text("  back_key: " .. tostring(last_event.back_key or "nil"))
                            imgui.text("  payload_bytes: " .. tostring(last_event.payload_bytes or 0))
                            imgui.text("  submit_frame_ok: " .. tostring(last_event.submit_frame_ok == true))
                            imgui.text("  submit_frame_error: " .. tostring(last_event.submit_frame_error or "nil"))
                            imgui.text("  payload_preview: " .. tostring(last_event.payload_preview or "nil"))
                        end
                        imgui.tree_pop()
                    end

                    imgui.tree_pop()
                end

                -- 6. ViGEm / Bindings
                if imgui.tree_node("ViGEm / Bindings") then
                    imgui.text("hasVigem (global): " .. tostring(probe.hasVigem))
                    imgui.text("bindings_alive: " .. tostring(probe.bindingsAlive))
                    imgui.text("bindings_has_vigem: " .. tostring(probe.bindingsHasVigem))
                    imgui.text("bindings_init_ok: " .. tostring(probe.bindingsInitOk))
                    imgui.text("bindings_vigem_init_ok: " .. tostring(probe.bindingsVigemInitOk))
                    imgui.text("bindings_last_error: " .. tostring(probe.bindingsLastError or "nil"))
                    imgui.text("bindings_axis_ok_frames: " .. tostring(probe.bindingsAxisOkFrames or 0))
                    imgui.text("bindings_axis_fail_frames: " .. tostring(probe.bindingsAxisFailFrames or 0))
                    imgui.text("bindings_axis_fail_streak: " .. tostring(probe.bindingsAxisFailStreak or 0))
                    imgui.text("bindings_write_failed: " .. tostring(probe.bindingsWriteFailed))
                    imgui.text("bindings_axis_last_error: " .. tostring(probe.bindingsAxisLastError or "nil"))
                    imgui.text("bindings_force_menu: " .. tostring(probe.bindingsForceMenu))
                    local axes = probe.bindingsLastAxes
                    if type(axes) == "table" then
                        imgui.text(string.format(
                            "bindings_last_axes: LX=%s LY=%s RX=%s RY=%s",
                            tostring(axes.LX),
                            tostring(axes.LY),
                            tostring(axes.RX),
                            tostring(axes.RY)
                        ))
                    else
                        imgui.text("bindings_last_axes: nil")
                    end
                    if probe.bindingsWriteFailed == true then
                        imgui.text_colored("Virtual gamepad axis write failed", 0xFFFF4444)
                    end
                    imgui.tree_pop()
                end

                -- 5b. MergedDevice（引擎侧合并手柄，只读）
                if imgui.tree_node("MergedDevice (engine)") then
                    local merged = probe_merged_gamepad()
                    imgui.text("available: " .. tostring(merged.available))
                    imgui.text("error: " .. tostring(merged.error or "nil"))
                    imgui.text("hasSingleton: " .. tostring(merged.hasSingleton))
                    imgui.text("hasMergedDevice: " .. tostring(merged.hasMergedDevice))
                    imgui.text("stickMethod: " .. tostring(merged.stickMethod or "nil"))
                    if merged.lstick ~= nil then
                        imgui.text(string.format(
                            "merged LStick: (%.3f, %.3f)",
                            merged.lstick.x or 0,
                            merged.lstick.y or 0
                        ))
                    else
                        imgui.text("merged LStick: nil")
                    end
                    if merged.rstick ~= nil then
                        imgui.text(string.format(
                            "merged RStick: (%.3f, %.3f)",
                            merged.rstick.x or 0,
                            merged.rstick.y or 0
                        ))
                    else
                        imgui.text("merged RStick: nil")
                    end
                    local axes = probe.bindingsLastAxes
                    if type(axes) == "table" then
                        imgui.text(string.format(
                            "compare bindings_last_axes: LX=%s LY=%s RX=%s RY=%s",
                            tostring(axes.LX),
                            tostring(axes.LY),
                            tostring(axes.RX),
                            tostring(axes.RY)
                        ))
                    end
                    if #merged.activeButtonLabels > 0 then
                        imgui.text("active emu buttons: " .. table.concat(merged.activeButtonLabels, ", "))
                    else
                        imgui.text("active emu buttons: (none)")
                    end
                    imgui.text("keyboardDevice: " .. tostring(merged.keyboardDevice))
                    imgui.text("mouseDevice: " .. tostring(merged.mouseDevice))
                    imgui.text("mouseLeftDown: " .. tostring(merged.mouseLeftDown))
                    imgui.text("mouseRightDown: " .. tostring(merged.mouseRightDown))
                    imgui.text("inputChannelRestartCount: " .. tostring(rawget(_G, "__vr_input_channel_restart_count") or 0))
                    imgui.tree_pop()
                end

                -- 7. 摇杆与扳机/握把
                if imgui.tree_node("摇杆与扳机/握把") then
                    if state ~= nil then
                        imgui.text("leftStickAxes: (" .. fmt_num(state.leftStickAxes.x) .. ", " .. fmt_num(state.leftStickAxes.y) .. ")")
                        imgui.text("rightStickAxes: (" .. fmt_num(state.rightStickAxes.x) .. ", " .. fmt_num(state.rightStickAxes.y) .. ")")
                        imgui.text("leftTrigger: " .. fmt_num(state.leftTrigger))
                        imgui.text("rightTrigger: " .. fmt_num(state.rightTrigger))
                        imgui.text("leftGrip: " .. fmt_num(state.leftGrip))
                        imgui.text("rightGrip: " .. fmt_num(state.rightGrip))
                        imgui.text("controllerIndices: " .. tostring(state.controllerIndices[1]) .. ", " .. tostring(state.controllerIndices[2]))
                        imgui.text("handleStatus.leftJoystick: " .. tostring(state.handleStatus and state.handleStatus.leftJoystick or false))
                        imgui.text("handleStatus.rightJoystick: " .. tostring(state.handleStatus and state.handleStatus.rightJoystick or false))
                        imgui.text("handleStatus.trigger: " .. tostring(state.handleStatus and state.handleStatus.trigger or false))
                        imgui.text("handleStatus.grip: " .. tostring(state.handleStatus and state.handleStatus.grip or false))
                        imgui.text("handleStatus.aButton: " .. tostring(state.handleStatus and state.handleStatus.aButton or false))
                        imgui.text("handleStatus.bButton: " .. tostring(state.handleStatus and state.handleStatus.bButton or false))
                        imgui.text("handleStatus.joystickClick: " .. tostring(state.handleStatus and state.handleStatus.joystickClick or false))
                    end
                    imgui.tree_pop()
                end

                imgui.tree_pop()
            end

            if imgui.tree_node("Backend / Input") then
                imgui.text("Input Backend: " .. tostring(input and input.backendName or "nil"))
                imgui.text("Backend Available: " .. tostring(input and input.backendAvailable or false))
                imgui.text("Backend Error: " .. summarize_error(input and input.backendError or "nil"))
                imgui.text("Preferred Backend: " .. tostring(input and input.preferredBackendName or "nil"))
                imgui.text("Preferred Available: " .. tostring(input and input.preferredBackendAvailable or false))
                imgui.text("Preferred Error: " .. summarize_error(input and input.preferredBackendError or "nil"))
                imgui.text("backendProbe.luaBridgeAvailable: " .. tostring(input and input.backendProbe and input.backendProbe.luaBridgeAvailable or false))
                imgui.text("backendProbe.queueBridgeReady: " .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeReady or false))
                imgui.text("backendProbe.queueBridgeMode: " .. tostring(input and input.backendProbe and input.backendProbe.queueBridgeMode or "nil"))
                imgui.text("backendProbe.queueBridgePhase: " .. tostring(input and input.backendProbe and input.backendProbe.queueBridgePhase or "nil"))
                imgui.text("backendProbe.queueBridgeError: " .. summarize_error(input and input.backendProbe and input.backendProbe.queueBridgeError or "nil"))
                imgui.text("backendProbe.simInputDllPath: " .. tostring(input and input.backendProbe and input.backendProbe.simInputDllPath or "nil"))
                imgui.text("backendProbe.simInputLoadMode: " .. tostring(input and input.backendProbe and input.backendProbe.simInputLoadMode or "nil"))
                imgui.tree_pop()
            end

            imgui.tree_pop()
        end, with_traceback)

        if not ok_ui and diag.lastUiError ~= ui_err then
            diag.lastUiError = ui_err
            append_line("UI", ui_err, true)
        end
    end)
    end
end

if re and re.on_script_reset then
    re.on_script_reset(function()
        close_log_file()
    end)
end

if diag.enabled then
    dump_snapshot("install_probe", true)
    dump_snapshot("install", false)
end


_G.DIAG_ENABLED = diag.enabled
_G.DIAG_MODULE = diag

return diag