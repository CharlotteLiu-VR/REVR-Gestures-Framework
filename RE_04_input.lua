local module_name = "RE_04_input"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_04_input.lua
-- Keyboard and mouse backend plus reusable input action classes.
local numerics = require("RE_01_numerics")
local keyboard_input = require("RE_02_Keyboard_input")
local KeyboardWrapper = require("RE_03_keyboard_wrapper")
local vr_globals = require("RE_00_vr_globals")

local input = {}

local VK = keyboard_input.VK
local Key = keyboard_input.Key
local MouseButton = keyboard_input.MouseButton
local MouseFlags = keyboard_input.MouseFlags
local resolve_key = keyboard_input.resolveKey
local resolve_virtual_key = keyboard_input.resolveVirtualKey
local describe_virtual_key = keyboard_input.describeVirtualKey
local describe_mouse_button = keyboard_input.describeMouseButton
local backend_init_error = nil
local backend_probe = {
    luaBridgeAvailable = false,
    luaBridgeGlobal = nil,
    luaBridgeError = nil,
    queueBridgeAvailable = false,
    queueBridgeReady = false,
    queueBridgeMode = nil,
    queueBridgePhase = nil,
    queueBridgeError = nil,
    queueBridgeLastError = nil,
    queueBridgeStatusPath = nil,
    queueBridgeQueuePath = nil,
}

local function set_backend_init_error(err)
    if err ~= nil then
        local message = tostring(err)
        if backend_init_error == nil then
            backend_init_error = message
        elseif not string.find(backend_init_error, message, 1, true) then
            backend_init_error = backend_init_error .. " | " .. message
        end
    end
end

local function create_noop_backend()
    return {
        keyDown = function(_, _)
            return false
        end,
        keyUp = function(_, _)
            return false
        end,
        tapKey = function(self, vk_code)
            self:keyDown(vk_code)
            self:keyUp(vk_code)
            return true
        end,
        mouseMove = function(_, _, _)
            return false
        end,
        mouseButton = function(_, _, _)
            return false
        end,
        mouseWheel = function(_, _)
            return false
        end,
    }
end

local function round_to_int(value)
    local numeric = tonumber(value) or 0.0
    if numeric >= 0.0 then
        return math.floor(numeric + 0.5)
    end
    return math.ceil(numeric - 0.5)
end

local function to_dword(value)
    local numeric = round_to_int(value)
    if numeric < 0 then
        return numeric + 4294967296
    end
    return numeric
end

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

local function get_current_aim_mode()
    local enhancer = rawget(_G, "VR_ENHANCER")
    local aim_mode = enhancer and enhancer.aimMode or nil
    if type(aim_mode) == "table" and aim_mode.current ~= nil then
        return aim_mode.current
    end
    return nil
end

local function publish_input_debug(line)
    _G.VR_LAST_SIMINPUT_COMMAND = line
    _G.VR_LAST_SIMINPUT_COMMAND_AT = os.date("%Y-%m-%d %H:%M:%S")
    _G.VR_LAST_SIMINPUT_AIM_MODE = get_current_aim_mode()
    _G.VR_SIMINPUT_COMMAND_COUNT = (_G.VR_SIMINPUT_COMMAND_COUNT or 0) + 1
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

local function create_lua_bridge_backend()
    local bridge = rawget(_G, "SimInputBridge") or rawget(_G, "sim_input_bridge")
    backend_probe.luaBridgeAvailable = type(bridge) == "table"
    backend_probe.luaBridgeGlobal = rawget(_G, "SimInputBridge") ~= nil and "SimInputBridge"
        or (rawget(_G, "sim_input_bridge") ~= nil and "sim_input_bridge" or nil)

    if type(bridge) ~= "table" then
        backend_probe.luaBridgeError = "lua bridge global not found"
        return nil
    end

    if type(bridge.keyDown) ~= "function"
        or type(bridge.keyUp) ~= "function"
        or type(bridge.tapKey) ~= "function"
        or type(bridge.mouseMove) ~= "function"
        or type(bridge.mouseButton) ~= "function"
        or type(bridge.mouseWheel) ~= "function"
    then
        backend_probe.luaBridgeError = "lua bridge missing required methods"
        return nil
    end

    backend_probe.luaBridgeError = nil

    return {
        name = "lua_sim_input_bridge",
        keyDown = function(_, key_code)
            local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
            if resolved_vk == nil then
                return false
            end
            return bridge.keyDown(resolved_vk) == true
        end,
        keyUp = function(_, key_code)
            local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
            if resolved_vk == nil then
                return false
            end
            return bridge.keyUp(resolved_vk) == true
        end,
        tapKey = function(_, key_code)
            local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
            if resolved_vk == nil then
                return false
            end
            return bridge.tapKey(resolved_vk) == true
        end,
        mouseMove = function(_, x, y)
            return bridge.mouseMove(round_to_int(x or 0), round_to_int(y or 0)) == true
        end,
        mouseButton = function(_, button, is_down)
            return bridge.mouseButton(button, is_down and true or false) == true
        end,
        mouseWheel = function(_, amount)
            return bridge.mouseWheel(round_to_int(amount or 0.0)) == true
        end,
    }
end

local function create_queue_bridge_backend()
    local status_paths = get_path_candidates("data/sim_input_bridge.status")
    local queue_paths = get_path_candidates("data/sim_input_bridge.queue")
    backend_probe.queueBridgeStatusPath = table.concat(status_paths, "|")
    backend_probe.queueBridgeQueuePath = table.concat(queue_paths, "|")

    local status_text, resolved_status_path = read_first_available_text(status_paths)
    if status_text == nil then
        backend_probe.queueBridgeError = "bridge status file not found"
        return nil
    end

    backend_probe.queueBridgeStatusPath = resolved_status_path or backend_probe.queueBridgeStatusPath

    local status = parse_key_value_text(status_text)
    backend_probe.queueBridgeMode = status.mode
    backend_probe.queueBridgePhase = status.phase
    backend_probe.queueBridgeLastError = status.lastError
    backend_probe.queueBridgeReady = status.ready == "1" or status.ready == "true"

    if not backend_probe.queueBridgeReady then
        backend_probe.queueBridgeError = status.lastError ~= nil and status.lastError ~= "" and status.lastError or "bridge status not ready"
        return nil
    end

    local function enqueue(command, description)
        local line = tostring(command)
        local aim_mode = get_current_aim_mode()
        if description ~= nil and description ~= "" then
            line = line .. " ; " .. tostring(description)
        end
        if aim_mode ~= nil then
            line = line .. " ; aimMode=" .. tostring(aim_mode)
        end

        local ok, result_or_err = append_first_available_line(queue_paths, line)
        if not ok then
            backend_probe.queueBridgeError = tostring(result_or_err)
            return false
        end

        backend_probe.queueBridgeQueuePath = tostring(result_or_err)
        publish_input_debug(line)

        return true
    end

    backend_probe.queueBridgeAvailable = true
    backend_probe.queueBridgeError = nil

    return {
        name = "sim_input_bridge_queue",
        keyDown = function(_, key_code)
            local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
            if resolved_vk == nil then
                return false
            end
            return enqueue(
                "KD " .. tostring(round_to_int(resolved_vk)),
                "key down \"" .. tostring(describe_virtual_key and describe_virtual_key(key_code) or resolved_vk) .. "\""
            )
        end,
        keyUp = function(_, key_code)
            local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
            if resolved_vk == nil then
                return false
            end
            return enqueue(
                "KU " .. tostring(round_to_int(resolved_vk)),
                "key up \"" .. tostring(describe_virtual_key and describe_virtual_key(key_code) or resolved_vk) .. "\""
            )
        end,
        tapKey = function(_, key_code)
            local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
            if resolved_vk == nil then
                return false
            end
            return enqueue(
                "TK " .. tostring(round_to_int(resolved_vk)),
                "key tap \"" .. tostring(describe_virtual_key and describe_virtual_key(key_code) or resolved_vk) .. "\""
            )
        end,
        mouseMove = function(_, x, y)
            return enqueue(
                "MM " .. tostring(round_to_int(x or 0)) .. " " .. tostring(round_to_int(y or 0)),
                "mouse move x=" .. tostring(round_to_int(x or 0)) .. " y=" .. tostring(round_to_int(y or 0))
            )
        end,
        mouseButton = function(_, button, is_down)
            return enqueue(
                "MB " .. tostring(round_to_int(button or 0)) .. " " .. tostring(is_down and 1 or 0),
                tostring(describe_mouse_button and describe_mouse_button(button) or button) .. (is_down and " down" or " up")
            )
        end,
        mouseWheel = function(_, amount)
            return enqueue(
                "MW " .. tostring(round_to_int(amount or 0)),
                "mouse wheel " .. tostring(round_to_int(amount or 0))
            )
        end,
    }
end

local function safe_find_type_definition(type_name)
    if sdk == nil or type(sdk.find_type_definition) ~= "function" then
        return nil
    end

    local ok, typedef_or_err = pcall(sdk.find_type_definition, type_name)
    if ok then
        return typedef_or_err
    end

    return nil
end

local function safe_get_native_singleton(singleton_name)
    if sdk == nil or type(sdk.get_native_singleton) ~= "function" then
        return nil
    end

    local ok, singleton_or_err = pcall(sdk.get_native_singleton, singleton_name)
    if ok then
        return singleton_or_err
    end

    return nil
end

local function has_typedef_method(typedef, method_name)
    if typedef == nil or type(typedef.get_method) ~= "function" then
        return false
    end

    local ok, method_or_err = pcall(typedef.get_method, typedef, method_name)
    return ok and method_or_err ~= nil
end

local function can_generate_global(type_name)
    if statics == nil or type(statics.generate_global) ~= "function" then
        return false
    end

    local ok = pcall(statics.generate_global, type_name)
    return ok
end

local function create_native_hid_probe()
    local probe = {
        sdkAvailable = sdk ~= nil
            and type(sdk.find_type_definition) == "function"
            and type(sdk.get_native_singleton) == "function"
            and type(sdk.call_native_func) == "function",
        staticsAvailable = statics ~= nil and type(statics.generate_global) == "function",
        error = nil,
        keyboard = {
            serviceType = false,
            serviceSingleton = false,
            getDevice = false,
            getConnectingDevices = false,
            deviceType = false,
            deviceObject = false,
            enumGlobal = false,
            methods = {
                get_DeviceState = false,
                get_Key = false,
                set_Key = false,
                set_KeyDown = false,
                set_KeyUp = false,
            },
        },
        mouse = {
            serviceType = false,
            serviceSingleton = false,
            getDevice = false,
            getConnectingDevices = false,
            deviceType = false,
            deviceObject = false,
            enumGlobal = false,
            methods = {
                get_Button = false,
                get_DeviceState = false,
                set_Button = false,
                set_ButtonDown = false,
                set_Position = false,
            },
        },
        summary = "native_hid_unavailable",
    }

    local ok_probe, probe_err = pcall(function()
        local keyboard_typedef = safe_find_type_definition("via.hid.Keyboard")
        if keyboard_typedef ~= nil then
            probe.keyboard.serviceType = true
            probe.keyboard.getDevice = has_typedef_method(keyboard_typedef, "get_Device")
            probe.keyboard.getConnectingDevices = has_typedef_method(keyboard_typedef, "get_ConnectingDevices")
                or has_typedef_method(keyboard_typedef, "getConnectingDevices")

            local keyboard_singleton = safe_get_native_singleton("via.hid.Keyboard")
            probe.keyboard.serviceSingleton = keyboard_singleton ~= nil

            if keyboard_singleton ~= nil and probe.keyboard.getDevice and probe.sdkAvailable then
                local ok_device, keyboard_device = pcall(sdk.call_native_func, keyboard_singleton, keyboard_typedef, "get_Device")
                probe.keyboard.deviceObject = ok_device and keyboard_device ~= nil
            end
        end

        local keyboard_device_typedef = safe_find_type_definition("via.hid.KeyboardDevice")
        if keyboard_device_typedef ~= nil then
            probe.keyboard.deviceType = true
            for method_name in pairs(probe.keyboard.methods) do
                probe.keyboard.methods[method_name] = has_typedef_method(keyboard_device_typedef, method_name)
            end
        end

        probe.keyboard.enumGlobal = can_generate_global("via.hid.KeyboardKey")

        local mouse_typedef = safe_find_type_definition("via.hid.Mouse")
        if mouse_typedef ~= nil then
            probe.mouse.serviceType = true
            probe.mouse.getDevice = has_typedef_method(mouse_typedef, "get_Device")
            probe.mouse.getConnectingDevices = has_typedef_method(mouse_typedef, "get_ConnectingDevices")
                or has_typedef_method(mouse_typedef, "getConnectingDevices")

            local mouse_singleton = safe_get_native_singleton("via.hid.Mouse")
            probe.mouse.serviceSingleton = mouse_singleton ~= nil

            if mouse_singleton ~= nil and probe.mouse.getDevice and probe.sdkAvailable then
                local ok_device, mouse_device = pcall(sdk.call_native_func, mouse_singleton, mouse_typedef, "get_Device")
                probe.mouse.deviceObject = ok_device and mouse_device ~= nil
            end
        end

        local mouse_device_typedef = safe_find_type_definition("via.hid.MouseDevice")
        if mouse_device_typedef ~= nil then
            probe.mouse.deviceType = true
            for method_name in pairs(probe.mouse.methods) do
                probe.mouse.methods[method_name] = has_typedef_method(mouse_device_typedef, method_name)
            end
        end

        probe.mouse.enumGlobal = can_generate_global("via.hid.MouseButton")
    end)

    if not ok_probe then
        probe.error = tostring(probe_err)
    end

    probe.summary = table.concat({
        "kbd=" .. tostring(probe.keyboard.serviceType and probe.keyboard.deviceType and probe.keyboard.serviceSingleton and probe.keyboard.deviceObject),
        "kbdSetKey=" .. tostring(probe.keyboard.methods.set_Key),
        "mouse=" .. tostring(probe.mouse.serviceType and probe.mouse.deviceType and probe.mouse.serviceSingleton and probe.mouse.deviceObject),
        "mouseSetButton=" .. tostring(probe.mouse.methods.set_Button),
        "mouseMove=" .. tostring(probe.mouse.methods.set_Position),
    }, " | ")

    return probe
end

local state = {
    time_provider = os.clock,
    throttle_enabled = false,
    debounce_enabled = false,
    throttle_interval = 0.0,
    debounce_interval = 0.0,
    key_times = {},
    mouse_times = {},
    pressed_keys = {},
    pressed_mouse_buttons = {},
    pending_key_releases = {},
    dominant_lock_order = 0,
    dominant_key_locks = {},
    dominant_mouse_locks = {},
}

local backend = create_noop_backend()
local lua_bridge_backend = nil
local queue_bridge_backend = nil
local preferred_backend = nil
local active_backend = nil

state.keyboard = KeyboardWrapper.new(backend)

local InputActionBase = {}
InputActionBase.__index = InputActionBase

local function new_input_action(base, values)
    local action = setmetatable({
        _values = values or {},
        _duration = 0.035,
        _time = 0.0,
        _need_update = false,
        _down = false,
        haptics = nil,
    }, base)
    return action
end

function InputActionBase:getCurrentHaptics()
    return self.haptics
end

function InputActionBase:update(_)
end

function InputActionBase:leave()
end

function InputActionBase:reset()
    self:leave()
end

local function normalize_key(value)
    if value == nil then
        return nil
    end
    if resolve_virtual_key ~= nil then
        return resolve_virtual_key(value)
    end
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return Key[value] or VK[value]
    end
    return nil
end

local function normalize_mouse_button(value)
    if value == nil then
        return nil
    end
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return MouseButton[value]
    end
    return nil
end

local function now()
    return state.time_provider()
end

local function create_lock_entry(owner_id, desired_state)
    state.dominant_lock_order = state.dominant_lock_order + 1
    return {
        owner = owner_id,
        desired_state = desired_state and true or false,
        order = state.dominant_lock_order,
    }
end

local function get_lock_bucket(kind)
    if kind == "mouse" then
        return state.dominant_mouse_locks
    end
    return state.dominant_key_locks
end

local function get_top_lock(lock_list)
    if type(lock_list) ~= "table" then
        return nil
    end

    local top_lock = nil
    for _, entry in ipairs(lock_list) do
        if top_lock == nil or (entry.order or 0) >= (top_lock.order or 0) then
            top_lock = entry
        end
    end
    return top_lock
end

local function get_effective_lock(kind, code)
    local bucket = get_lock_bucket(kind)
    local lock_list = bucket[code]
    return get_top_lock(lock_list)
end

local function set_locked_state(kind, code, desired_state)
    if kind == "mouse" then
        if desired_state then
            state.pressed_mouse_buttons[code] = true
            backend:mouseButton(code, true)
        else
            state.pressed_mouse_buttons[code] = nil
            backend:mouseButton(code, false)
        end
        return
    end

    if desired_state then
        state.pressed_keys[code] = true
        state.keyboard:setKeyDown(code)
    else
        state.pressed_keys[code] = nil
        state.keyboard:setKeyUp(code)
    end
end

local function add_dominant_lock(kind, code, owner_id, desired_state)
    if code == nil or owner_id == nil then
        return
    end

    local bucket = get_lock_bucket(kind)
    local lock_list = bucket[code]
    if lock_list == nil then
        lock_list = {}
        bucket[code] = lock_list
    end

    lock_list[#lock_list + 1] = create_lock_entry(owner_id, desired_state)
    local active_lock = get_top_lock(lock_list)
    if active_lock ~= nil then
        set_locked_state(kind, code, active_lock.desired_state)
    end
end

local function remove_dominant_lock(kind, code, owner_id)
    if code == nil or owner_id == nil then
        return
    end

    local bucket = get_lock_bucket(kind)
    local lock_list = bucket[code]
    if type(lock_list) ~= "table" then
        return
    end

    for index = #lock_list, 1, -1 do
        local entry = lock_list[index]
        if entry ~= nil and entry.owner == owner_id then
            table.remove(lock_list, index)
        end
    end

    if #lock_list == 0 then
        bucket[code] = nil
        return
    end

    local active_lock = get_top_lock(lock_list)
    if active_lock ~= nil then
        set_locked_state(kind, code, active_lock.desired_state)
    end
end

local function signal_matches_lock(requested_state, effective_lock)
    if effective_lock == nil then
        return true
    end
    return effective_lock.desired_state == (requested_state and true or false)
end

local function gate_event(bucket, code)
    local timestamp = now()
    local interval = state.debounce_enabled and state.debounce_interval or 0.0
    if state.throttle_enabled and state.throttle_interval > interval then
        interval = state.throttle_interval
    end
    if interval <= 0.0 then
        bucket[code] = timestamp
        return true
    end

    local previous = bucket[code]
    if previous ~= nil and (timestamp - previous) < interval then
        return false
    end

    bucket[code] = timestamp
    return true
end

local function set_backend(new_backend)
    if type(new_backend) ~= "table" then
        return false
    end

    if type(new_backend.keyDown) == "function" then
        backend.keyDown = new_backend.keyDown
    end
    if type(new_backend.keyUp) == "function" then
        backend.keyUp = new_backend.keyUp
    end
    if type(new_backend.tapKey) == "function" then
        backend.tapKey = new_backend.tapKey
    end
    if type(new_backend.mouseMove) == "function" then
        backend.mouseMove = new_backend.mouseMove
    end
    if type(new_backend.mouseButton) == "function" then
        backend.mouseButton = new_backend.mouseButton
    end
    if type(new_backend.mouseWheel) == "function" then
        backend.mouseWheel = new_backend.mouseWheel
    end

    state.keyboard:setBackend(backend)
    return true
end

function input.setBackend(new_backend)
    return set_backend(new_backend)
end

local function update_backend_metadata()
    input.backendAvailable = active_backend ~= nil
    input.backendName = active_backend ~= nil and (active_backend.name or "unknown") or "noop"
    input.backendError = active_backend ~= nil and nil or (backend_init_error or "input_backend_unavailable")
    input.preferredBackendName = "SimInputBridge"
    input.preferredBackendAvailable = preferred_backend ~= nil
    input.preferredBackendError = preferred_backend ~= nil and nil or (backend_probe.queueBridgeError or backend_probe.luaBridgeError)
    input.backendProbe = backend_probe
end

local function refresh_preferred_backend()
    local refreshed_lua_bridge = create_lua_bridge_backend()
    if refreshed_lua_bridge ~= nil then
        lua_bridge_backend = refreshed_lua_bridge
    end

    local refreshed_queue_bridge = create_queue_bridge_backend()
    if refreshed_queue_bridge ~= nil then
        queue_bridge_backend = refreshed_queue_bridge
    end

    preferred_backend = lua_bridge_backend or queue_bridge_backend

    if preferred_backend ~= nil and active_backend ~= preferred_backend then
        active_backend = preferred_backend
        set_backend(active_backend)
    end

    update_backend_metadata()
end

function input.setTimeProvider(provider)
    if type(provider) == "function" then
        state.time_provider = provider
        return true
    end
    return false
end

function input.setThrottleEnabled(enabled, interval_seconds)
    state.throttle_enabled = enabled and true or false
    if type(interval_seconds) == "number" then
        state.throttle_interval = interval_seconds
    end
end

function input.setDebounceEnabled(enabled, interval_seconds)
    state.debounce_enabled = enabled and true or false
    if type(interval_seconds) == "number" then
        state.debounce_interval = interval_seconds
    end
end

function input.pressKey(vk_code)
    refresh_preferred_backend()
    local resolved = normalize_key(vk_code)
    if resolved == nil then
        return false
    end
    if not signal_matches_lock(true, get_effective_lock("key", resolved)) then
        return false
    end
    if not gate_event(state.key_times, "kd_" .. tostring(resolved)) then
        return false
    end
    state.pressed_keys[resolved] = true
    return state.keyboard:setKeyDown(resolved) or true
end

function input.releaseKey(vk_code)
    refresh_preferred_backend()
    local resolved = normalize_key(vk_code)
    if resolved == nil then
        return false
    end
    if not signal_matches_lock(false, get_effective_lock("key", resolved)) then
        return false
    end
    state.pressed_keys[resolved] = nil
    return state.keyboard:setKeyUp(resolved) or true
end

function input.tapKey(vk_code)
    refresh_preferred_backend()
    local resolved = normalize_key(vk_code)
    if resolved == nil then
        return false
    end
    if get_effective_lock("key", resolved) ~= nil then
        return false
    end
    if not gate_event(state.key_times, "kp_" .. tostring(resolved)) then
        return false
    end
    state.keyboard:setPressed(resolved)
    return true
end

function input.pulseKey(vk_code, duration)
    local resolved = normalize_key(vk_code)
    if resolved == nil then
        return false
    end

    if not input.pressKey(resolved) then
        return false
    end

    state.pending_key_releases[#state.pending_key_releases + 1] = {
        key = resolved,
        releaseAt = now() + math.max(0.0, tonumber(duration) or 0.0),
    }
    return true
end

function input.updatePending(current_time)
    local timestamp = current_time or now()
    for index = #state.pending_key_releases, 1, -1 do
        local pending = state.pending_key_releases[index]
        if pending ~= nil and timestamp >= (pending.releaseAt or 0.0) then
            input.releaseKey(pending.key)
            table.remove(state.pending_key_releases, index)
        end
    end
    if state.keyboard and state.keyboard.update then
        state.keyboard:update(timestamp)
    end
end

function input.moveMouse(x, y)
    refresh_preferred_backend()
    if not gate_event(state.mouse_times, "move") then
        return false
    end
    return backend:mouseMove(x or 0.0, y or 0.0) or true
end

function input.pressMouseButton(button)
    refresh_preferred_backend()
    local resolved = normalize_mouse_button(button)
    if resolved == nil then
        return false
    end
    if not signal_matches_lock(true, get_effective_lock("mouse", resolved)) then
        return false
    end
    if not gate_event(state.mouse_times, "md_" .. tostring(resolved)) then
        return false
    end
    state.pressed_mouse_buttons[resolved] = true
    return backend:mouseButton(resolved, true) or true
end

function input.releaseMouseButton(button)
    refresh_preferred_backend()
    local resolved = normalize_mouse_button(button)
    if resolved == nil then
        return false
    end
    if not signal_matches_lock(false, get_effective_lock("mouse", resolved)) then
        return false
    end
    state.pressed_mouse_buttons[resolved] = nil
    return backend:mouseButton(resolved, false) or true
end

function input.clickMouseButton(button)
    refresh_preferred_backend()
    local resolved = normalize_mouse_button(button)
    if resolved == nil then
        return false
    end
    if get_effective_lock("mouse", resolved) ~= nil then
        return false
    end
    if not gate_event(state.mouse_times, "mc_" .. tostring(resolved)) then
        return false
    end
    backend:mouseButton(resolved, true)
    backend:mouseButton(resolved, false)
    return true
end

function input.scrollMouse(amount)
    refresh_preferred_backend()
    if not gate_event(state.mouse_times, "wheel") then
        return false
    end
    return backend:mouseWheel(amount or 0.0) or true
end

function input.releaseAll()
    for key_code in pairs(state.pressed_keys) do
        state.keyboard:setKeyUp(key_code)
    end
    state.pressed_keys = {}
    state.pending_key_releases = {}
    if state.keyboard and state.keyboard.pending_releases then
        state.keyboard.pending_releases = {}
    end

    for button in pairs(state.pressed_mouse_buttons) do
        backend:mouseButton(button, false)
    end
    state.pressed_mouse_buttons = {}
end

local function clear_simulated_channel()
    input.releaseAll()

    for kind, bucket in pairs({ key = state.dominant_key_locks, mouse = state.dominant_mouse_locks }) do
        for code, lock_list in pairs(bucket) do
            if type(lock_list) == "table" then
                for _, entry in ipairs(lock_list) do
                    if entry ~= nil and entry.desired_state == true then
                        set_locked_state(kind, code, false)
                    end
                end
            end
        end
    end

    state.dominant_key_locks = {}
    state.dominant_mouse_locks = {}

    if state.keyboard ~= nil and type(state.keyboard.reset) == "function" then
        state.keyboard:reset()
    end
end

-- Release simulated keyboard/mouse dominance; optional ctx is RE_08 environment.
function input.resetKB(ctx)
    clear_simulated_channel()
    vr_globals.resetRuntimeGlobals()

    if type(ctx) == "table" then
        if ctx.vrToMouse ~= nil then
            ctx.vrToMouse.mode.current = 0
            if ctx.vrToMouse.stickMode ~= nil then
                ctx.vrToMouse.stickMode.current = 0
            end
            if type(ctx.vrToMouse.reset) == "function" then
                ctx.vrToMouse:reset()
            end
        end

        if type(ctx.actions) == "table" and type(ctx.actions.resetActiveActions) == "function" then
            ctx.actions.resetActiveActions()
        end
    end

    _G.__vr_input_channel_restart_at = os.clock()
    _G.__vr_input_channel_restart_count = (_G.__vr_input_channel_restart_count or 0) + 1
    return true
end

function input.acquireDominantLock(specs)
    if type(specs) ~= "table" then
        return nil
    end

    local owner_id = tostring({})
    local handle = {
        owner = owner_id,
        specs = {},
        active = true,
    }

    for _, spec in ipairs(specs) do
        if type(spec) == "table" then
            local kind = spec.kind == "mouse" and "mouse" or "key"
            local resolved = kind == "mouse"
                and normalize_mouse_button(spec.code)
                or normalize_key(spec.code)
            if resolved ~= nil then
                local entry = {
                    kind = kind,
                    code = resolved,
                    desired_state = spec.desired_state and true or false,
                }
                handle.specs[#handle.specs + 1] = entry
                add_dominant_lock(kind, resolved, owner_id, entry.desired_state)
            end
        end
    end

    if #handle.specs == 0 then
        return nil
    end

    return handle
end

function input.releaseDominantLock(handle)
    if type(handle) ~= "table" or handle.active ~= true or handle.owner == nil then
        return false
    end

    for _, spec in ipairs(handle.specs or {}) do
        remove_dominant_lock(spec.kind, spec.code, handle.owner)
    end

    handle.active = false
    return true
end

local KeyAction = {}
KeyAction.__index = KeyAction
setmetatable(KeyAction, InputActionBase)

local function normalize_values(values, resolver)
    if values == nil then
        return {}
    end
    if type(values) ~= "table" then
        local resolved = resolver(values)
        return resolved ~= nil and { resolved } or {}
    end

    local normalized = {}
    for _, value in ipairs(values) do
        local resolved = resolver(value)
        if resolved ~= nil then
            normalized[#normalized + 1] = resolved
        end
    end
    return normalized
end

function KeyAction.new(keys)
    return new_input_action(KeyAction, normalize_values(keys, normalize_key))
end

function KeyAction:getDominantLockSpec(desired_state)
    local specs = {}
    for _, key_code in ipairs(self._values) do
        specs[#specs + 1] = {
            kind = "key",
            code = key_code,
            desired_state = desired_state and true or false,
        }
    end
    return specs
end

local RELEASE_REPEAT_COUNT = 3

function KeyAction:setKeyDown()
    for _, key_code in ipairs(self._values) do
        input.pressKey(key_code)
    end
end

function KeyAction:setKeyUp()
    for _, key_code in ipairs(self._values) do
        input.releaseKey(key_code)
    end
end

function KeyAction:setKeyPressed()
    for _, key_code in ipairs(self._values) do
        input.tapKey(key_code)
    end
end

local KeyQuickPress = {}
KeyQuickPress.__index = KeyQuickPress
setmetatable(KeyQuickPress, KeyAction)

function KeyQuickPress.new(keys)
    return setmetatable(KeyAction.new(keys), KeyQuickPress)
end

function KeyQuickPress:enter(_, _)
    self:setKeyPressed()
end

local KeyPress = {}
KeyPress.__index = KeyPress
setmetatable(KeyPress, KeyAction)

function KeyPress.new(keys)
    local action = setmetatable(KeyAction.new(keys), KeyPress)
    action._pressed = false
    return action
end

function KeyPress:enter(current_time, from_voice_recognition)
    self:setKeyDown()
    self._time = current_time or 0.0
    self._need_update = from_voice_recognition and true or false
    self._pressed = true
end

function KeyPress:update(current_time)
    if self._need_update and ((current_time or 0.0) - self._time) >= self._duration then
        self:leave()
    end
end

function KeyPress:getDominantLockSpec()
    return KeyAction.getDominantLockSpec(self, true)
end

function KeyPress:leave()
    if self._pressed then
        self:setKeyUp()
    end
    self._need_update = false
    self._pressed = false
end

function KeyPress:reset()
    -- Only emit key-up when this action previously pressed a key.
    if self._pressed then
        self:leave()
    else
        self._need_update = false
    end
end

local KeyToggle = {}
KeyToggle.__index = KeyToggle
setmetatable(KeyToggle, KeyAction)

function KeyToggle.new(keys, options)
    local action = setmetatable(KeyAction.new(keys), KeyToggle)
    action._edge_active = false
    action._tap_on_leave = options ~= nil and options.tapOnLeave == true
    action._pulse_duration = options ~= nil and tonumber(options.pulseDuration) or 0.08
    return action
end

function KeyToggle:_pulseKeys()
    for _, key_code in ipairs(self._values) do
        input.pulseKey(key_code, self._pulse_duration)
    end
end

function KeyToggle:enter(_, _)
    if self._edge_active then
        return true
    end

    self._edge_active = true
    self:_pulseKeys()
    return true
end

function KeyToggle:leave()
    if not self._edge_active then
        return
    end

    self._edge_active = false
    if self._tap_on_leave then
        self:_pulseKeys()
    end
end

function KeyToggle:reset()
    self._edge_active = false
end

local KeySwitchState = {}
KeySwitchState.__index = KeySwitchState
setmetatable(KeySwitchState, KeyAction)

function KeySwitchState.new(keys)
    return setmetatable(KeyAction.new(keys), KeySwitchState)
end

function KeySwitchState:enter(_, _)
    if self._down then
        self:setKeyUp()
        self._down = false
    else
        self:setKeyDown()
        self._down = true
    end
end

function KeySwitchState:reset()
    self:setKeyUp()
    self._down = false
end

local KeySetState = {}
KeySetState.__index = KeySetState
setmetatable(KeySetState, KeyAction)

function KeySetState.new(keys, state_to_set)
    local action = setmetatable(KeyAction.new(keys), KeySetState)
    action.stateToSet = state_to_set and true or false
    return action
end

function KeySetState:enter(_, _)
    if self.stateToSet then
        self:setKeyDown()
    else
        self:setKeyUp()
    end
end

function KeySetState:getDominantLockSpec()
    return KeyAction.getDominantLockSpec(self, self.stateToSet)
end

local MouseAction = {}
MouseAction.__index = MouseAction
setmetatable(MouseAction, InputActionBase)

function MouseAction.new(buttons)
    return new_input_action(MouseAction, normalize_values(buttons, normalize_mouse_button))
end

function MouseAction:getDominantLockSpec(desired_state)
    local specs = {}
    for _, button in ipairs(self._values) do
        if button ~= MouseButton.WheelDown and button ~= MouseButton.WheelUp then
            specs[#specs + 1] = {
                kind = "mouse",
                code = button,
                desired_state = desired_state and true or false,
            }
        end
    end
    return specs
end

function MouseAction:setKeyDown()
    for _, button in ipairs(self._values) do
        if button == MouseButton.WheelDown then
            input.scrollMouse(-1)
        elseif button == MouseButton.WheelUp then
            input.scrollMouse(1)
        else
            input.pressMouseButton(button)
        end
    end
end

function MouseAction:setKeyUp()
    for _, button in ipairs(self._values) do
        if button ~= MouseButton.WheelDown and button ~= MouseButton.WheelUp then
            -- Mirror keyboard release retries for held mouse buttons such as aim gestures.
            for _ = 1, RELEASE_REPEAT_COUNT do
                input.releaseMouseButton(button)
            end
        end
    end
end

function MouseAction:setKeyPressed()
    for _, button in ipairs(self._values) do
        if button == MouseButton.WheelDown then
            input.scrollMouse(-1)
        elseif button == MouseButton.WheelUp then
            input.scrollMouse(1)
        else
            input.clickMouseButton(button)
        end
    end
end

local MouseQuickPress = {}
MouseQuickPress.__index = MouseQuickPress
setmetatable(MouseQuickPress, MouseAction)

function MouseQuickPress.new(buttons)
    return setmetatable(MouseAction.new(buttons), MouseQuickPress)
end

function MouseQuickPress:enter(_, _)
    self:setKeyPressed()
end

local MousePress = {}
MousePress.__index = MousePress
setmetatable(MousePress, MouseAction)

function MousePress.new(buttons)
    local action = setmetatable(MouseAction.new(buttons), MousePress)
    action._pressed = false
    return action
end

function MousePress:enter(current_time, from_voice_recognition)
    self:setKeyDown()
    self._time = current_time or 0.0
    self._need_update = from_voice_recognition and true or false
    self._pressed = true
end

function MousePress:update(current_time)
    if self._need_update and ((current_time or 0.0) - self._time) >= self._duration then
        self:leave()
    end
end

function MousePress:getDominantLockSpec()
    return MouseAction.getDominantLockSpec(self, true)
end

function MousePress:leave()
    if self._pressed then
        self:setKeyUp()
    end
    self._need_update = false
    self._pressed = false
end

function MousePress:reset()
    -- Only emit mouse-up when this action previously pressed a button.
    if self._pressed then
        self:leave()
    else
        self._need_update = false
    end
end

local MouseToggle = {}
MouseToggle.__index = MouseToggle
setmetatable(MouseToggle, MouseAction)

function MouseToggle.new(buttons)
    return setmetatable(MouseAction.new(buttons), MouseToggle)
end

function MouseToggle:enter(_, _)
    -- Match KeyToggle semantics: toggle only on enter, do not toggle again on leave.
    self:setKeyPressed()
end

function MouseToggle:leave()
end

local MouseSwitchState = {}
MouseSwitchState.__index = MouseSwitchState
setmetatable(MouseSwitchState, MouseAction)

function MouseSwitchState.new(buttons)
    return setmetatable(MouseAction.new(buttons), MouseSwitchState)
end

function MouseSwitchState:enter(_, _)
    if self._down then
        self:setKeyUp()
        self._down = false
    else
        self:setKeyDown()
        self._down = true
    end
end

function MouseSwitchState:reset()
    self:setKeyUp()
    self._down = false
end

local MouseSetState = {}
MouseSetState.__index = MouseSetState
setmetatable(MouseSetState, MouseAction)

function MouseSetState.new(buttons, state_to_set)
    local action = setmetatable(MouseAction.new(buttons), MouseSetState)
    action.stateToSet = state_to_set and true or false
    return action
end

function MouseSetState:enter(_, _)
    if self.stateToSet then
        self:setKeyDown()
    else
        self:setKeyUp()
    end
end

function MouseSetState:getDominantLockSpec()
    return MouseAction.getDominantLockSpec(self, self.stateToSet)
end

local function create_mode(initial_value)
    return { current = initial_value }
end

local VRToMouse = {}
VRToMouse.__index = VRToMouse

local function get_runtime_vr_state(runtime)
    if type(runtime) ~= "table" then
        return nil
    end

    local getter = runtime.getVRState or runtime.get_vr_state
    if type(getter) == "function" then
        return getter(runtime)
    end

    return runtime.state or nil
end

function VRToMouse.new(runtime)
    return setmetatable({
        runtime = runtime,
        mode = create_mode(0),
        stickMode = create_mode(1),
        mouseSensitivityX = 800.0,
        mouseSensitivityY = 800.0,
        stickMultiplierX = 1.0,
        stickMultiplierY = 1.0,
        enableYawPitch = create_mode(true),
        enableRoll = create_mode(false),
        useControllerOrientation = true,
        useRightController = true,
        _yaw = 0.0,
        _pitch = 0.0,
        _lastMode = 0,
        _yawOffset = 0.0,
        _pitchOffset = 0.0,
        output = {
            yaw = 0.0,
            pitch = 0.0,
            roll = 0.0,
        },
    }, VRToMouse)
end

function VRToMouse:setRuntime(runtime)
    self.runtime = runtime
end

function VRToMouse:update(_, delta_time)
    local vr_state = get_runtime_vr_state(self.runtime)
    if vr_state == nil or vr_state.headPose == nil then
        return
    end

    if self.mode.current == 0 then
        if self._lastMode ~= 0 then
            self._lastMode = 0
            self._yawOffset = 0.0
            self._pitchOffset = 0.0
            self.output.yaw = 0.0
            self.output.pitch = 0.0
            self.output.roll = 0.0
        end
        return
    end

    local yaw_head, pitch_head, roll_head = numerics.get_yaw_pitch_roll(vr_state.headPose)
    local yaw_target = self._yaw
    local pitch_target = self._pitch

    if self.mode.current == 1 then
        yaw_target = yaw_head
        pitch_target = pitch_head
    elseif self.mode.current == 2 or self.mode.current == 3 then
        local pose = self.mode.current == 2 and vr_state.leftTouchPose or vr_state.rightTouchPose
        if pose ~= nil then
            if self.useControllerOrientation then
                local yaw, pitch = numerics.get_yaw_pitch(pose)
                yaw_target = yaw + self._yawOffset
                pitch_target = pitch + self._pitchOffset
            else
                local dx = (pose.position.x or 0.0) - (vr_state.headPose.position.x or 0.0)
                local dy = (pose.position.y or 0.0) - (vr_state.headPose.position.y or 0.0)
                local dz = (pose.position.z or 0.0) - (vr_state.headPose.position.z or 0.0)
                local dh = math.sqrt((dx * dx) + (dz * dz))
                yaw_target = math.pi + math.atan(dz, dx) + self._yawOffset
                pitch_target = -math.atan(dy, dh) + self._pitchOffset
            end
        end
    end

    local yaw_change = 0.0
    local pitch_change = 0.0

    if self._lastMode ~= self.mode.current then
        if self.mode.current == 1 and self._lastMode > 1 then
            self._yawOffset = 0.0
            self._pitchOffset = 0.0
            yaw_change = numerics.wrap_angle(yaw_head - self._yaw)
            pitch_change = pitch_head - self._pitch
            self._yaw = yaw_head
            self._pitch = pitch_head
        else
            self._yawOffset = yaw_head - yaw_target
            self._pitchOffset = pitch_head - pitch_target
            self._yaw = yaw_head
            self._pitch = pitch_head
        end
        self._lastMode = self.mode.current
    else
        yaw_change = numerics.wrap_angle(yaw_target - self._yaw)
        pitch_change = pitch_target - self._pitch
        self._yaw = yaw_target
        self._pitch = pitch_target
    end

    local delta_x = yaw_change * self.mouseSensitivityX
    local delta_y = pitch_change * self.mouseSensitivityY

    if self.stickMode.current == 1 then
        local stick_axes = self.useRightController and vr_state.rightStickAxes or vr_state.leftStickAxes
        if stick_axes ~= nil then
            delta_x = delta_x + ((stick_axes.x or 0.0) * self.mouseSensitivityX * self.stickMultiplierX * (delta_time or 0.0))
            delta_y = delta_y - ((stick_axes.y or 0.0) * self.mouseSensitivityY * self.stickMultiplierY * (delta_time or 0.0))
        end
    end

    input.moveMouse(delta_x, delta_y)

    if self.enableYawPitch.current then
        self.output.yaw = numerics.wrap_angle(yaw_head - self._yaw)
        self.output.pitch = self._pitch - pitch_head
    else
        self.output.yaw = 0.0
        self.output.pitch = 0.0
    end

    if self.enableRoll.current then
        self.output.roll = -roll_head
    else
        self.output.roll = 0.0
    end
end

function VRToMouse:reset()
    self.output.yaw = 0.0
    self.output.pitch = 0.0
    self.output.roll = 0.0
    self._lastMode = 0
end

lua_bridge_backend = create_lua_bridge_backend()
queue_bridge_backend = create_queue_bridge_backend()
preferred_backend = lua_bridge_backend or queue_bridge_backend
active_backend = preferred_backend

if active_backend ~= nil then
    input.setBackend(active_backend)
end
update_backend_metadata()

function input.refreshNativeHidProbe()
    input.nativeHidProbe = create_native_hid_probe()
    input.nativeHidSummary = input.nativeHidProbe.summary
    return input.nativeHidProbe
end

input.refreshNativeHidProbe()

input.VK = VK
input.ScanCode = keyboard_input.ScanCode or Key
input.Key = Key
input.MouseButton = MouseButton
input.KeyboardWrapper = KeyboardWrapper
input.KeyAction = KeyAction
input.KeyQuickPress = KeyQuickPress
input.KeyPress = KeyPress
input.KeyToggle = KeyToggle
input.KeySwitchState = KeySwitchState
input.KeySetState = KeySetState
input.MouseAction = MouseAction
input.MouseQuickPress = MouseQuickPress
input.MousePress = MousePress
input.MouseToggle = MouseToggle
input.MouseSwitchState = MouseSwitchState
input.MouseSetState = MouseSetState
input.VRToMouse = VRToMouse

_G.VRInput = input

package.loaded[module_name] = input

return input