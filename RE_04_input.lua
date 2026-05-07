local module_name = "RE_04_input"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_04_input.lua
-- Keyboard and mouse backend plus reusable input action classes.
local numerics = require("RE_01_numerics")
local keyboard_input = require("RE_02_Keyboard_input")
local KeyboardWrapper = require("RE_03_keyboard_wrapper")

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
    ffiAvailable = false,
    ffiError = nil,
    simInputDllPath = nil,
    simInputLoadMode = nil,
    simInputLoadError = nil,
    simInputCdefError = nil,
    windowsLoadMode = nil,
    windowsLoadError = nil,
    windowsCdefError = nil,
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

local function build_reframework_path(relative_path)
    local suffix = tostring(relative_path or ""):gsub("\\", "/")
    if suffix == "" then
        return "reframework"
    end
    return "reframework/" .. suffix
end

local function get_path_candidates(relative_path)
    local suffix = tostring(relative_path or ""):gsub("\\", "/")
    local candidates = {}

    if suffix ~= "" then
        if string.sub(suffix, 1, 5) == "data/" then
            candidates[#candidates + 1] = string.sub(suffix, 6)
        end

        candidates[#candidates + 1] = "reframework/" .. suffix
        candidates[#candidates + 1] = suffix
    end

    return candidates
end

local function read_all_text(file_path)
    local file = io.open(file_path, "rb")
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
            local file = io.open(path, "ab")
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
    local enhancer = rawget(_G, "RE9_VR_ENHANCER")
    local aim_mode = enhancer and enhancer.aimMode or nil
    if type(aim_mode) == "table" and aim_mode.current ~= nil then
        return aim_mode.current
    end
    return nil
end

local function publish_input_debug(line)
    _G.RE9_LAST_SIMINPUT_COMMAND = line
    _G.RE9_LAST_SIMINPUT_COMMAND_AT = os.date("%Y-%m-%d %H:%M:%S")
    _G.RE9_LAST_SIMINPUT_AIM_MODE = get_current_aim_mode()
    _G.RE9_SIMINPUT_COMMAND_COUNT = (_G.RE9_SIMINPUT_COMMAND_COUNT or 0) + 1
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

local function create_siminput_backend()
    local ok_ffi, ffi = pcall(require, "ffi")
    backend_probe.ffiAvailable = ok_ffi and ffi ~= nil
    backend_probe.ffiError = ok_ffi and nil or tostring(ffi)
    if not ok_ffi then
        set_backend_init_error(ffi)
        return nil
    end

    local ok_cdef, cdef_err = pcall(ffi.cdef, [[
        void mouseInput(long x, long y, unsigned int dwFlags, unsigned int mouseData);
        void keyboardInput(short virtualKey, unsigned int dwFlags);
        void keyboardKeyPress(short virtualKey, unsigned int timeMs);
    ]])
    if not ok_cdef then
        backend_probe.simInputCdefError = tostring(cdef_err)
        set_backend_init_error(cdef_err)
        return nil
    end

    local dll_path = build_reframework_path("plugins/simInputLib.dll")
    backend_probe.simInputDllPath = dll_path
    local ok_load, sim_input = pcall(ffi.load, dll_path)
    if not ok_load or sim_input == nil then
        backend_probe.simInputLoadError = ok_load and "ffi.load returned nil" or tostring(sim_input)
        local ok_name_load, loaded_by_name = pcall(ffi.load, "simInputLib")
        if not ok_name_load or loaded_by_name == nil then
            set_backend_init_error(ok_load and "ffi.load(simInputLib) returned nil" or sim_input)
            set_backend_init_error(ok_name_load and "ffi.load(simInputLib) returned nil" or loaded_by_name)
            return nil
        end
        backend_probe.simInputLoadMode = "name"
        sim_input = loaded_by_name
    else
        backend_probe.simInputLoadMode = "path"
    end

    local KEYEVENTF_KEYUP = 0x0002
    local WHEEL_DELTA = 120
    local XBUTTON1 = 0x0001
    local XBUTTON2 = 0x0002

    local function send_keyboard(key_code, is_down)
        local resolved_vk = resolve_virtual_key ~= nil and resolve_virtual_key(key_code) or key_code
        if resolved_vk == nil then
            return false
        end

        local flags = 0
        if not is_down then
            flags = flags + KEYEVENTF_KEYUP
        end

        sim_input.keyboardInput(resolved_vk, flags)
        return true
    end

    local function send_mouse(flags, x, y, mouse_data)
        sim_input.mouseInput(round_to_int(x or 0), round_to_int(y or 0), flags or 0, to_dword(mouse_data or 0))
        return true
    end

    local function send_mouse_button(button, is_down)
        if button == MouseButton.Left then
            return send_mouse(is_down and MouseFlags.LEFTDOWN or MouseFlags.LEFTUP, 0, 0, 0)
        end
        if button == MouseButton.Right then
            return send_mouse(is_down and MouseFlags.RIGHTDOWN or MouseFlags.RIGHTUP, 0, 0, 0)
        end
        if button == MouseButton.Middle then
            return send_mouse(is_down and MouseFlags.MIDDLEDOWN or MouseFlags.MIDDLEUP, 0, 0, 0)
        end
        if button == MouseButton.X1 then
            return send_mouse(is_down and MouseFlags.XDOWN or MouseFlags.XUP, 0, 0, XBUTTON1)
        end
        if button == MouseButton.X2 then
            return send_mouse(is_down and MouseFlags.XDOWN or MouseFlags.XUP, 0, 0, XBUTTON2)
        end
        return false
    end

    return {
        name = "simInputLib",
        keyDown = function(_, key_code)
            return send_keyboard(key_code, true)
        end,
        keyUp = function(_, key_code)
            return send_keyboard(key_code, false)
        end,
        tapKey = function(self, key_code)
            local down_ok = self:keyDown(key_code)
            local up_ok = self:keyUp(key_code)
            return down_ok and up_ok
        end,
        mouseMove = function(_, x, y)
            return send_mouse(MouseFlags.MOVE, x, y, 0)
        end,
        mouseButton = function(_, button, is_down)
            return send_mouse_button(button, is_down)
        end,
        mouseWheel = function(_, amount)
            local wheel_amount = round_to_int((amount or 0.0) * WHEEL_DELTA)
            return send_mouse(MouseFlags.WHEEL, 0, 0, wheel_amount)
        end,
    }
end

local function create_windows_backend()
    local ok_ffi, ffi = pcall(require, "ffi")
    backend_probe.ffiAvailable = ok_ffi and ffi ~= nil
    backend_probe.ffiError = ok_ffi and nil or tostring(ffi)
    if not ok_ffi then
        set_backend_init_error(ffi)
        return nil
    end

    local ok_cdef, cdef_err = pcall(ffi.cdef, [[ 
        typedef long LONG;
        typedef unsigned short WORD;
        typedef unsigned int DWORD;
        typedef unsigned int UINT;
        typedef unsigned long long ULONG_PTR;
        typedef struct tagMOUSEINPUT {
            LONG dx;
            LONG dy;
            DWORD mouseData;
            DWORD dwFlags;
            DWORD time;
            ULONG_PTR dwExtraInfo;
        } MOUSEINPUT;
        typedef struct tagKEYBDINPUT {
            WORD wVk;
            WORD wScan;
            DWORD dwFlags;
            DWORD time;
            ULONG_PTR dwExtraInfo;
        } KEYBDINPUT;
        typedef struct tagHARDWAREINPUT {
            DWORD uMsg;
            WORD wParamL;
            WORD wParamH;
        } HARDWAREINPUT;
        typedef union tagINPUTUNION {
            MOUSEINPUT mi;
            KEYBDINPUT ki;
            HARDWAREINPUT hi;
        } INPUTUNION;
        typedef struct tagINPUT {
            DWORD type;
            INPUTUNION u;
        } INPUT;
        UINT SendInput(UINT cInputs, INPUT* pInputs, int cbSize);
    ]])
    if not ok_cdef then
        backend_probe.windowsCdefError = tostring(cdef_err)
        set_backend_init_error(cdef_err)
        return nil
    end

    local user32 = ffi.C
    local backend_name = "ffi.C.user32.SendInput"
    local ok_probe = pcall(function()
        return user32.SendInput ~= nil
    end)
    if not ok_probe then
        local ok_load, loaded = pcall(ffi.load, "user32")
        if not ok_load or loaded == nil then
            backend_probe.windowsLoadError = ok_load and "ffi.load(user32) returned nil" or tostring(loaded)
            set_backend_init_error(ok_load and "ffi.load(user32) returned nil" or loaded)
            return nil
        end
        user32 = loaded
        backend_name = "ffi.load(user32).SendInput"
        backend_probe.windowsLoadMode = "ffi.load(user32)"
    else
        backend_probe.windowsLoadMode = "ffi.C.user32"
    end

    local INPUT_MOUSE = 0
    local INPUT_KEYBOARD = 1
    local KEYEVENTF_EXTENDEDKEY = 0x0001
    local KEYEVENTF_KEYUP = 0x0002
    local KEYEVENTF_SCANCODE = 0x0008
    local WHEEL_DELTA = 120
    local XBUTTON1 = 0x0001
    local XBUTTON2 = 0x0002
    local input_size = ffi.sizeof("INPUT")

    local function send_input(input_data)
        local sent = user32.SendInput(1, input_data, input_size)
        return tonumber(sent or 0) == 1
    end

    local function split_scan_code(scan_code)
        local resolved_scan_code = tonumber(scan_code) or 0
        if resolved_scan_code >= 0xE000 then
            local prefix = math.floor(resolved_scan_code / 0x100)
            if prefix == 0xE0 or prefix == 0xE1 then
                return resolved_scan_code % 0x100, true
            end
        end

        return resolved_scan_code % 0x100, false
    end

    local function send_keyboard(scan_code, is_down)
        local resolved_scan_code = resolve_key ~= nil and resolve_key(scan_code) or scan_code
        if resolved_scan_code == nil then
            return false
        end

        local final_scan_code, is_extended = split_scan_code(resolved_scan_code)
        local input_data = ffi.new("INPUT[1]")
        input_data[0].type = INPUT_KEYBOARD
        input_data[0].u.ki.wVk = 0
        input_data[0].u.ki.wScan = final_scan_code
        input_data[0].u.ki.dwFlags = KEYEVENTF_SCANCODE
            + (is_extended and KEYEVENTF_EXTENDEDKEY or 0)
            + (is_down and 0 or KEYEVENTF_KEYUP)
        input_data[0].u.ki.time = 0
        input_data[0].u.ki.dwExtraInfo = 0
        return send_input(input_data)
    end

    local function send_mouse(flags, x, y, mouse_data)
        local input_data = ffi.new("INPUT[1]")
        input_data[0].type = INPUT_MOUSE
        input_data[0].u.mi.dx = round_to_int(x or 0)
        input_data[0].u.mi.dy = round_to_int(y or 0)
        input_data[0].u.mi.mouseData = to_dword(mouse_data or 0)
        input_data[0].u.mi.dwFlags = flags or 0
        input_data[0].u.mi.time = 0
        input_data[0].u.mi.dwExtraInfo = 0
        return send_input(input_data)
    end

    local function send_mouse_button(button, is_down)
        if button == MouseButton.Left then
            return send_mouse(is_down and MouseFlags.LEFTDOWN or MouseFlags.LEFTUP, 0, 0, 0)
        end
        if button == MouseButton.Right then
            return send_mouse(is_down and MouseFlags.RIGHTDOWN or MouseFlags.RIGHTUP, 0, 0, 0)
        end
        if button == MouseButton.Middle then
            return send_mouse(is_down and MouseFlags.MIDDLEDOWN or MouseFlags.MIDDLEUP, 0, 0, 0)
        end
        if button == MouseButton.X1 then
            return send_mouse(is_down and MouseFlags.XDOWN or MouseFlags.XUP, 0, 0, XBUTTON1)
        end
        if button == MouseButton.X2 then
            return send_mouse(is_down and MouseFlags.XDOWN or MouseFlags.XUP, 0, 0, XBUTTON2)
        end
        return false
    end

    return {
        name = backend_name,
        keyDown = function(_, scan_code)
            return send_keyboard(scan_code, true)
        end,
        keyUp = function(_, scan_code)
            return send_keyboard(scan_code, false)
        end,
        tapKey = function(self, scan_code)
            local down_ok = self:keyDown(scan_code)
            local up_ok = self:keyUp(scan_code)
            return down_ok and up_ok
        end,
        mouseMove = function(_, x, y)
            return send_mouse(MouseFlags.MOVE, x, y, 0)
        end,
        mouseButton = function(_, button, is_down)
            return send_mouse_button(button, is_down)
        end,
        mouseWheel = function(_, amount)
            local wheel_amount = round_to_int((amount or 0.0) * WHEEL_DELTA)
            return send_mouse(MouseFlags.WHEEL, 0, 0, wheel_amount)
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
}

local backend = create_noop_backend()
local lua_bridge_backend = nil
local queue_bridge_backend = nil
local siminput_backend = nil
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
    input.secondaryBackendName = "simInputLib"
    input.secondaryBackendAvailable = siminput_backend ~= nil
    input.secondaryBackendError = siminput_backend ~= nil and nil or backend_init_error
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
    state.pressed_keys[resolved] = nil
    return state.keyboard:setKeyUp(resolved) or true
end

function input.tapKey(vk_code)
    refresh_preferred_backend()
    local resolved = normalize_key(vk_code)
    if resolved == nil then
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
    state.pressed_mouse_buttons[resolved] = nil
    return backend:mouseButton(resolved, false) or true
end

function input.clickMouseButton(button)
    refresh_preferred_backend()
    local resolved = normalize_mouse_button(button)
    if resolved == nil then
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

    for button in pairs(state.pressed_mouse_buttons) do
        backend:mouseButton(button, false)
    end
    state.pressed_mouse_buttons = {}
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
    return setmetatable(KeyAction.new(keys), KeyPress)
end

function KeyPress:enter(current_time, from_voice_recognition)
    self:setKeyDown()
    self._time = current_time or 0.0
    self._need_update = from_voice_recognition and true or false
end

function KeyPress:update(current_time)
    if self._need_update and ((current_time or 0.0) - self._time) >= self._duration then
        self:leave()
    end
end

function KeyPress:leave()
    self:setKeyUp()
    self._need_update = false
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

local MouseAction = {}
MouseAction.__index = MouseAction
setmetatable(MouseAction, InputActionBase)

function MouseAction.new(buttons)
    return new_input_action(MouseAction, normalize_values(buttons, normalize_mouse_button))
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
            input.releaseMouseButton(button)
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
    return setmetatable(MouseAction.new(buttons), MousePress)
end

function MousePress:enter(current_time, from_voice_recognition)
    self:setKeyDown()
    self._time = current_time or 0.0
    self._need_update = from_voice_recognition and true or false
end

function MousePress:update(current_time)
    if self._need_update and ((current_time or 0.0) - self._time) >= self._duration then
        self:leave()
    end
end

function MousePress:leave()
    self:setKeyUp()
    self._need_update = false
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
siminput_backend = create_siminput_backend()
preferred_backend = lua_bridge_backend or queue_bridge_backend
active_backend = preferred_backend or siminput_backend
if active_backend == nil then
    active_backend = create_windows_backend()
end

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

_G.RE9Input = input

package.loaded[module_name] = input

return input