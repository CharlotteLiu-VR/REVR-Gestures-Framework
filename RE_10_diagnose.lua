local unpack_args = table.unpack or unpack

if _G.DIAG_MODULE ~= nil then
    return _G.DIAG_MODULE
end

local MAX_LOG_BYTES = 20 * 1024 * 1024
local DEFAULT_DIAG_ENABLED = false
local TELEMETRY_INTERVAL_SEC = 1.0
local DIAG_PANEL_NAME = "VR Gestures"
local DIAG_LOG_NAME = "diagnose_gestures.log"
local DIAG_LOG_PREFIX = "[VR_GESTURES] "
local log_path = DIAG_LOG_NAME

local diag = {
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
}

if diag.enabled == nil then
    diag.enabled = rawget(_G, "RE9_DIAG_ENABLED")
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
    local snapshot = {
        weaponName = rawget(_G, "__vr_weapon_name"),
        equipWeaponIdName = nil,
        equipWeaponIdRaw = nil,
    }

    pcall(function()
        local cm = sdk and sdk.get_managed_singleton and sdk.get_managed_singleton("app.CharacterManager") or nil
        if not cm then
            return
        end

        local ctx = cm:call("get_PlayerContextFast")
        if not ctx then
            return
        end

        local updater = ctx:call("get_Updater")
        if not updater then
            return
        end

        local equipment = updater:call("get_Equipment")
        if not equipment then
            return
        end

        local weapon_id = equipment:get_field("<EquipWeaponID>k__BackingField")
        if weapon_id == nil then
            return
        end

        snapshot.equipWeaponIdRaw = tostring(weapon_id)

        local ok_name, weapon_id_name = pcall(function()
            return weapon_id:call("ToString")
        end)
        if ok_name and weapon_id_name ~= nil then
            snapshot.equipWeaponIdName = tostring(weapon_id_name)
        end
    end)

    return snapshot
end

local function build_weapon_state_key(snapshot)
    snapshot = snapshot or get_weapon_diag_snapshot()
    return table.concat({
        tostring(snapshot.weaponName or "nil"),
        tostring(snapshot.equipWeaponIdName or "nil"),
        tostring(snapshot.equipWeaponIdRaw or "nil"),
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

local function append_line(level, message, force_write)

    if not diag.enabled and not force_write then
        return
    end

    local line = os.date("%Y-%m-%d %H:%M:%S") .. " [" .. tostring(level) .. "] " .. tostring(message)

    local open_mode = "ab"
    local current_size = get_log_size_bytes()
    if current_size >= MAX_LOG_BYTES then
        open_mode = "wb"
    end

    local ok_write, write_err = pcall(function()
        local file = io.open(log_path, open_mode)
        if file == nil then
            error("io.open failed for " .. tostring(log_path))
        end

        if open_mode == "wb" then
            file:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. DIAG_LOG_NAME .. " rollover\n")
        end

        file:write(line, "\n")
        file:close()
    end)

    diag.lastWriteError = ok_write and nil or tostring(write_err)
end

local function clear_log_file()
    local ok_clear, clear_err = pcall(function()
        local file = io.open(log_path, "wb")
        if file == nil then
            error("io.open failed for " .. tostring(log_path))
        end

        file:close()
    end)

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
    local last_input_aim_mode = rawget(_G, "RE9_LAST_SIMINPUT_AIM_MODE")
    local last_input_command = rawget(_G, "RE9_LAST_SIMINPUT_COMMAND")
    local aim_mode = diag.enhancer and diag.enhancer.aimMode or nil
    local weapon_state_key = build_weapon_state_key(weapon_snapshot)
    if weapon_state_key == diag.lastWeaponStateKey then
        return
    end

    diag.lastWeaponStateKey = weapon_state_key
    append_line("WEAPON", table.concat({
        "reason=" .. tostring(reason or "weapon_transition"),
        "weaponName=" .. tostring(weapon_snapshot.weaponName or "nil"),
        "equipWeaponIdName=" .. tostring(weapon_snapshot.equipWeaponIdName or "nil"),
        "equipWeaponIdRaw=" .. tostring(weapon_snapshot.equipWeaponIdRaw or "nil"),
    }, " | "), false)
end

probe_vrmod = function()
    local vr = rawget(_G, "vrmod")
    local snapshot = {
        hasVrmod = vr ~= nil,
        runtimeName = "unavailable",
        isOpenXR = false,
        hasVigem = rawget(_G, "vigem") ~= nil,
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
    local enhancer = rawget(_G, "RE9_VR_ENHANCER")
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
    local success = env:applyTouchHaptics(left_hand and true or false, 0.08, 160.0, 0.9)
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
    local vr = rawget(_G, "vrmod")
    local gui_visible = get_gui_visible_situation()
    local ok_pause_pending, pause_pending = safe_call(vr, "should_handle_pause")
    local probe_indices = probe and probe.controllers or nil
    local state_indices = state and state.controllerIndices or nil
    local head_pose = state and state.headPose or nil
    local left_pose = state and state.leftTouchPose or nil
    local right_pose = state and state.rightTouchPose or nil
    local support_docked = rawget(_G, "__vr_support_docked") == true
    local two_hand_aiming = rawget(_G, "__vr_two_hand_aiming_active") == true
    local weapon_snapshot = get_weapon_diag_snapshot()

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
        "secondaryBackend=" .. tostring(input and input.secondaryBackendName or "nil"),
        "secondaryBackendAvailable=" .. tostring(input and input.secondaryBackendAvailable or false),
        "secondaryBackendError=" .. summarize_error(input and input.secondaryBackendError or "nil"),
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
        "motionPaused=" .. tostring(rawget(_G, "__vr_motion_paused") == true),
        "supportDocked=" .. tostring(support_docked),
        "twoHandAiming=" .. tostring(two_hand_aiming),
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
        "weaponName=" .. tostring(weapon_snapshot.weaponName or "nil"),
        "equipWeaponIdName=" .. tostring(weapon_snapshot.equipWeaponIdName or "nil"),
        "equipWeaponIdRaw=" .. tostring(weapon_snapshot.equipWeaponIdRaw or "nil")
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

    if diag.enhancer._diagnose_wrapped then
        return true
    end

    local raw_tick = diag.enhancer.tick
    if type(raw_tick) ~= "function" then
        return true
    end

    diag.enhancer.tick = function(self, ...)
        local args = { ... }
        local ok_tick, result_or_err = xpcall(function()
            return raw_tick(self, unpack_args(args))
        end, with_traceback)

        if not ok_tick then
            diag.lastTickError = result_or_err
            append_line("TICK", result_or_err, true)
            return nil
        end

        diag.tickCount = diag.tickCount + 1
        maybe_log_runtime_transition("tick_transition")
        maybe_log_weapon_transition("tick_transition")
        maybe_log_periodic_telemetry()
        return result_or_err
    end

    diag.enhancer._diagnose_wrapped = true
    append_line("INFO", "diagnose wrapper installed: " .. log_path, true)
    return true
end

try_attach_enhancer()

if re and re.on_pre_application_entry then
    re.on_pre_application_entry("UpdateBehavior", function()
        try_attach_enhancer()
    end)
end

if re and re.on_frame then
    re.on_frame(function()
        try_attach_enhancer()
        refresh_environment_state()
        maybe_log_runtime_transition("frame_transition")
        maybe_log_weapon_transition("frame_transition")
        maybe_log_periodic_telemetry()
    end)
end

if re and re.on_draw_ui and imgui then
    re.on_draw_ui(function()
        local ok_ui, ui_err = xpcall(function()
            try_attach_enhancer()
            if not imgui.tree_node(DIAG_PANEL_NAME) then
                return
            end

            local env = diag.enhancer and diag.enhancer.environment or nil
            local state = env and env.state or nil
            local input = env and env.input or nil
            local probe = probe_vrmod()

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
                _G.RE9_DIAG_ENABLED = diag.enabled
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

                -- 2. 操作与调试按钮
                if imgui.tree_node("操作与调试按钮") then
                    imgui.text("Current Aim Mode: " .. tostring(diag.enhancer and diag.enhancer.aimMode and diag.enhancer.aimMode.current or "nil"))
                    imgui.text("Current Command: " .. tostring(diag.enhancer and diag.enhancer.getCurrentAimCommand and diag.enhancer:getCurrentAimCommand() or "nil"))
                    imgui.text("Last Aim Mode: " .. tostring(rawget(_G, "RE9_LAST_SIMINPUT_AIM_MODE") or "nil"))
                    imgui.text("Last Command: " .. tostring(rawget(_G, "RE9_LAST_SIMINPUT_COMMAND") or "nil"))
                    imgui.text("Last Command At: " .. tostring(rawget(_G, "RE9_LAST_SIMINPUT_COMMAND_AT") or "nil"))
                    imgui.text("Last Command Count: " .. tostring(rawget(_G, "RE9_SIMINPUT_COMMAND_COUNT") or 0))
                    imgui.tree_pop()
                end

                -- 3. 头盔/校准与手柄状态
                if imgui.tree_node("头盔/校准与手柄状态") then
                    if state ~= nil then
                        imgui.text("isMounted: " .. tostring(state.isMounted))
                        imgui.text("usingControllers: " .. tostring(state.usingControllers))
                        if imgui.button("Refresh Handles / State") then
                            local ok_refresh, refresh_result = refresh_environment_state()
                            append_line("REFRESH", ok_refresh and "ok" or tostring(refresh_result), true)
                        end
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
                    imgui.text("lastHaptic.gestureName: " .. tostring(rawget(_G, "lastGestureHaptic") or "nil"))
                    imgui.text("lastHaptic.patternName: " .. tostring(rawget(_G, "lastHapticPatternName") or "nil"))
                    imgui.text("lastHaptic.phase: " .. tostring(rawget(_G, "lastHapticPhase") or "nil"))
                    if imgui.button("Test Left Haptic") then
                        fire_test_haptic(true)
                    end
                    if imgui.button("Test Right Haptic") then
                        fire_test_haptic(false)
                    end
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
                    imgui.tree_pop()
                end

                -- 5. 摇杆与扳机/握把
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
                imgui.text("Secondary Backend: " .. tostring(input and input.secondaryBackendName or "nil"))
                imgui.text("Secondary Available: " .. tostring(input and input.secondaryBackendAvailable or false))
                imgui.text("Secondary Error: " .. summarize_error(input and input.secondaryBackendError or "nil"))
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

if diag.enabled then
    dump_snapshot("install_probe", true)
    dump_snapshot("install", false)
end


_G.DIAG_ENABLED = diag.enabled
_G.DIAG_MODULE = diag

return diag