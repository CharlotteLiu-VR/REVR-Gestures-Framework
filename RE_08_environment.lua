local module_name = "RE_08_environment"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_08_environment.lua
-- Runtime bridge that samples vrmod, manages timing, applies haptics, and owns reset/calibration.
local numerics = require("RE_01_numerics")
local keyboard_input = require("RE_02_Keyboard_input")
local keyboard_wrapper = require("RE_03_keyboard_wrapper")
local input = require("RE_04_input")
local haptics = require("RE_05_haptics")
local actions = require("RE_06_actions")
local gestures = require("RE_07_gestures")

local function safe_require(module_name)
    local ok, value = pcall(require, module_name)
    if ok then
        return value
    end
    return nil
end

local function new_pose()
    return {
        position = numerics.new_vector(0.0, 0.0, 0.0),
        forward = numerics.new_vector(0.0, 0.0, 1.0),
        left = numerics.new_vector(-1.0, 0.0, 0.0),
        up = numerics.new_vector(0.0, 1.0, 0.0),
        rotation = nil,
    }
end

local environment = {
    updateFrequency = 1.0 / 60.0,
    numerics = numerics,
    keyboardInput = keyboard_input,
    keyboardWrapper = keyboard_wrapper,
    input = input,
    haptics = haptics,
    actions = actions,
    gestures = gestures,
    modules = {
        numerics = numerics,
        keyboard_input = keyboard_input,
        keyboard_wrapper = keyboard_wrapper,
        input = input,
        haptics = haptics,
        actions = actions,
        gestures = gestures,
    },
    re9 = safe_require("utility/RE9"),
    vr_controller_manager = safe_require("vr/VRControllerManager"),
    vrmod = rawget(_G, "vrmod"),
    time = {
        current = 0.0,
        delta = 0.0,
        _last_clock = nil,
        accumulator = 0.0,
    },
    state = {
        hasVrmod = false,
        isMounted = false,
        usingControllers = false,
        isOpenXR = false,
        runtimeName = "unavailable",
        handleStatus = {
            leftJoystick = false,
            rightJoystick = false,
            trigger = false,
            grip = false,
            aButton = false,
            bButton = false,
            joystickClick = false,
        },
        lastHaptic = {
            success = false,
            leftHand = false,
            duration = 0.0,
            frequency = 0.0,
            amplitude = 0.0,
            api = "not_called",
            reason = "not_called",
        },
        calibrated = false,
        standingHeight = 0.0,
        rollCenter = 0.0,
        headPose = new_pose(),
        leftTouchPose = new_pose(),
        rightTouchPose = new_pose(),
        headController = {
            standingHeight = 0.0,
        },
        leftController = numerics.new_vector(0.0, 0.0, 0.0),
        rightController = numerics.new_vector(0.0, 0.0, 0.0),
        leftTrigger = 0.0,
        rightTrigger = 0.0,
        leftGrip = 0.0,
        rightGrip = 0.0,
        a = 0.0,
        b = 0.0,
        x = 0.0,
        y = 0.0,
        leftStick = 0.0,
        rightStick = 0.0,
        leftStickAxes = { x = 0.0, y = 0.0 },
        rightStickAxes = { x = 0.0, y = 0.0 },
        controllerIndices = { 0, 0 },
    },
    handles = {
        left = nil,
        right = nil,
        left_index = nil,
        right_index = nil,
        trigger = nil,
        grip = nil,
        a_button = nil,
        b_button = nil,
        joystick_click = nil,
    },
    _initialized = false,
}

local function safe_call(target, method_name, ...)
    if target ~= nil and type(target[method_name]) == "function" then
        local ok, result = pcall(target[method_name], target, ...)
        if ok then
            return result
        end
    end
    return nil
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

local function resolve_quaternion(rotation_value)
    if rotation_value == nil then
        return nil
    end
    if type(rotation_value.to_quat) == "function" then
        local ok, quaternion = pcall(rotation_value.to_quat, rotation_value)
        if ok then
            return quaternion
        end
    end
    return rotation_value
end

local function update_pose(vrmod, index, pose)
    local position = safe_call(vrmod, "get_position", index)
    if position ~= nil then
        numerics.copy_vector(pose.position, position)
    end

    local rotation_value = safe_call(vrmod, "get_rotation", index)
    if rotation_value == nil then
        local transform = safe_call(vrmod, "get_transform", index)
        if transform ~= nil and type(transform.to_quat) == "function" then
            local ok, quaternion = pcall(transform.to_quat, transform)
            if ok then
                rotation_value = quaternion
            end
        end
    end
    local quaternion = resolve_quaternion(rotation_value)
    if quaternion ~= nil then
        pose.rotation = quaternion
        numerics.quaternion_to_axes(quaternion, pose)
    end
    return pose
end

local function safe_digital(vrmod, action_handle, hand_handle)
    if vrmod == nil or action_handle == nil then
        return 0.0
    end

    local function try_source(source_handle)
        if source_handle == nil then
            return false
        end

        local ok, value = pcall(vrmod.is_action_active, vrmod, action_handle, source_handle)
        return ok and value and true or false
    end

    if try_source(hand_handle) then
        return 1.0
    end

    return 0.0
end

local function safe_digital_for_hand(vrmod, action_handle, hand_handle, controller_index)
    if hand_handle ~= nil then
        return safe_digital(vrmod, action_handle, hand_handle)
    end

    return safe_digital(vrmod, action_handle, controller_index)
end

local function update_axis(out_axis, source)
    out_axis.x = (source and source.x) or 0.0
    out_axis.y = (source and source.y) or 0.0
    return out_axis
end

local function copy_controller_position(target, pose)
    if target ~= nil and pose ~= nil and pose.position ~= nil then
        numerics.copy_vector(target, pose.position)
    end
end

function environment:refreshHandles()
    self.vrmod = rawget(_G, "vrmod") or self.vrmod
    self.state.hasVrmod = self.vrmod ~= nil
    if self.vrmod == nil then
        self.state.runtimeName = "unavailable"
        self.state.isOpenXR = false
        self.state.handleStatus.leftJoystick = false
        self.state.handleStatus.rightJoystick = false
        self.state.handleStatus.trigger = false
        self.state.handleStatus.grip = false
        self.state.handleStatus.aButton = false
        self.state.handleStatus.bButton = false
        self.state.handleStatus.joystickClick = false
        return false
    end

    local is_openxr = safe_call(self.vrmod, "is_openxr_loaded")
    self.state.isOpenXR = is_openxr and true or false
    self.state.runtimeName = self.state.isOpenXR and "openxr" or "openvr"

    local controller_indices = safe_call(self.vrmod, "get_controllers")
    local left_index, right_index = normalize_controller_indices(controller_indices)
    self.handles.left_index = left_index
    self.handles.right_index = right_index
    self.state.controllerIndices[1] = self.handles.left_index or 0
    self.state.controllerIndices[2] = self.handles.right_index or 0

    self.handles.left = safe_call(self.vrmod, "get_left_joystick")
    self.handles.right = safe_call(self.vrmod, "get_right_joystick")
    self.handles.trigger = safe_call(self.vrmod, "get_action_trigger")
    self.handles.grip = safe_call(self.vrmod, "get_action_grip")
    self.handles.a_button = safe_call(self.vrmod, "get_action_a_button")
    self.handles.b_button = safe_call(self.vrmod, "get_action_b_button")
    self.handles.joystick_click = safe_call(self.vrmod, "get_action_joystick_click")

    self.state.handleStatus.leftJoystick = self.handles.left ~= nil
    self.state.handleStatus.rightJoystick = self.handles.right ~= nil
    self.state.handleStatus.trigger = self.handles.trigger ~= nil
    self.state.handleStatus.grip = self.handles.grip ~= nil
    self.state.handleStatus.aButton = self.handles.a_button ~= nil
    self.state.handleStatus.bButton = self.handles.b_button ~= nil
    self.state.handleStatus.joystickClick = self.handles.joystick_click ~= nil
    return true
end

function environment:applyTouchHaptics(left_hand, duration, frequency, amplitude)
    if not self:refreshHandles() then
        self.state.lastHaptic.success = false
        self.state.lastHaptic.api = "none"
        self.state.lastHaptic.reason = "refresh_handles_failed"
        return false
    end

    local hand = left_hand and self.handles.left or self.handles.right
    local haptic_api = nil
    local haptic_method = nil

    if type(self.vrmod.apply_haptic_vibration) == "function" then
        haptic_api = "apply_haptic_vibration"
        haptic_method = self.vrmod.apply_haptic_vibration
    elseif type(self.vrmod.trigger_haptic_vibration) == "function" then
        haptic_api = "trigger_haptic_vibration"
        haptic_method = self.vrmod.trigger_haptic_vibration
    end

    if hand == nil or haptic_method == nil then
        local resolved_duration = math.max(0.0, tonumber(duration) or 0.0)
        local resolved_frequency = math.max(0.0, tonumber(frequency) or 0.0)
        local resolved_amplitude = math.min(1.0, math.max(0.0, tonumber(amplitude) or 0.0))
        self.state.lastHaptic.success = false
        self.state.lastHaptic.leftHand = left_hand and true or false
        self.state.lastHaptic.duration = resolved_duration
        self.state.lastHaptic.frequency = resolved_frequency
        self.state.lastHaptic.amplitude = resolved_amplitude
        self.state.lastHaptic.api = haptic_api or "none"
        self.state.lastHaptic.reason = hand == nil and "joystick_handle_missing" or "haptic_api_missing"
        return false
    end

    local resolved_duration = math.max(0.0, tonumber(duration) or 0.0)
    local resolved_frequency = math.max(0.0, tonumber(frequency) or 0.0)
    local resolved_amplitude = math.min(1.0, math.max(0.0, tonumber(amplitude) or 0.0))
    local ok = pcall(haptic_method, self.vrmod, 0.0, resolved_duration, resolved_frequency, resolved_amplitude, hand)
    self.state.lastHaptic.success = ok and true or false
    self.state.lastHaptic.leftHand = left_hand and true or false
    self.state.lastHaptic.duration = resolved_duration
    self.state.lastHaptic.frequency = resolved_frequency
    self.state.lastHaptic.amplitude = resolved_amplitude
    self.state.lastHaptic.api = haptic_api
    self.state.lastHaptic.reason = ok and "ok" or (haptic_api .. "_failed")
    return ok
end

function environment:setInputBackend(backend)
    return self.input.setBackend(backend)
end

function environment:syncControllerState()
    local state = self.state
    copy_controller_position(state.leftController, state.leftTouchPose)
    copy_controller_position(state.rightController, state.rightTouchPose)
    state.headController.standingHeight = state.standingHeight
    return true
end

function environment:calibrateState()
    local state = self.state
    if not state.isMounted then
        return false
    end

    state.standingHeight = state.headPose.position.y or state.standingHeight
    state.rollCenter = numerics.get_roll(state.headPose)
    self:syncControllerState()
    state.calibrated = true
    return true
end

function environment:recenterVRSpace()
    if not self:refreshHandles() or self.vrmod == nil or not self.state.isMounted then
        return false
    end

    if type(self.vrmod.center) == "function" then
        local ok = pcall(self.vrmod.center, self.vrmod)
        if ok then
            return true
        end
    end

    local standing_origin = safe_call(self.vrmod, "get_standing_origin")
    local hmd_pos = safe_call(self.vrmod, "get_position", 0)
    local vector4f = rawget(_G, "Vector4f")
    if standing_origin == nil or hmd_pos == nil or vector4f == nil or type(vector4f.new) ~= "function" or type(self.vrmod.set_standing_origin) ~= "function" then
        return false
    end

    local ok_vector, new_origin = pcall(vector4f.new, hmd_pos.x, standing_origin.y, hmd_pos.z, standing_origin.w or 1.0)
    if not ok_vector or new_origin == nil then
        return false
    end

    local ok = pcall(self.vrmod.set_standing_origin, self.vrmod, new_origin)
    return ok
end

function environment:reset()
    -- reset() in VRCompanion.py recenters VR space, stores standing height,
    -- refreshes controller baselines, clears roll calibration, and resets runtime helpers.
    self:sampleVRState()
    self:recenterVRSpace()
    self:sampleVRState()
    self:calibrateState()

    if self.gestureSets ~= nil then
        local current = self.gestureSets:getCurrentGestureSet()
        if current ~= nil then
            current:reset()
        end
    end

    self.actions.resetActiveActions()
    self.input.releaseAll()
    if self.vrToMouse ~= nil and self.vrToMouse.reset ~= nil then
        self.vrToMouse:reset()
    end
    if self.hapticPlayer ~= nil and self.hapticPlayer.clear ~= nil then
        self.hapticPlayer:clear()
    end

    self.time.accumulator = 0.0
    return self.state.calibrated
end

function environment:updateTime(current_time, delta_time)
    local now = current_time or os.clock()
    local delta = delta_time
    if delta == nil then
        if self.re9 and type(self.re9.delta_time) == "number" and self.re9.delta_time > 0.0 then
            delta = self.re9.delta_time
        elseif self.time._last_clock ~= nil then
            delta = now - self.time._last_clock
        else
            delta = self.updateFrequency
        end
    end
    if delta < 0.0 then
        delta = self.updateFrequency
    end
    self.time.current = now
    self.time.delta = delta
    self.time._last_clock = now
    return now, delta
end

function environment:sampleVRState()
    local state = self.state
    if not self:refreshHandles() then
        state.isMounted = false
        state.usingControllers = false
        state.calibrated = false
        return state
    end

    state.isMounted = self.vrmod.is_hmd_active and self.vrmod:is_hmd_active() or false
    state.usingControllers = self.vrmod.is_using_controllers and self.vrmod:is_using_controllers() or false
    if not state.isMounted then
        state.calibrated = false
        return state
    end

    update_pose(self.vrmod, 0, state.headPose)
    update_pose(self.vrmod, self.handles.left_index or 1, state.leftTouchPose)
    update_pose(self.vrmod, self.handles.right_index or 2, state.rightTouchPose)

    if not state.calibrated then
        state.standingHeight = state.headPose.position.y or 0.0
        state.rollCenter = numerics.get_roll(state.headPose)
        state.headController.standingHeight = state.standingHeight
    end

    local left_axis = safe_call(self.vrmod, "get_left_stick_axis")
    local right_axis = safe_call(self.vrmod, "get_right_stick_axis")
    update_axis(state.leftStickAxes, left_axis)
    update_axis(state.rightStickAxes, right_axis)
    state.leftStick = safe_digital_for_hand(self.vrmod, self.handles.joystick_click, self.handles.left, self.handles.left_index)
    state.rightStick = safe_digital_for_hand(self.vrmod, self.handles.joystick_click, self.handles.right, self.handles.right_index)
    state.leftTrigger = safe_digital_for_hand(self.vrmod, self.handles.trigger, self.handles.left, self.handles.left_index)
    state.rightTrigger = safe_digital_for_hand(self.vrmod, self.handles.trigger, self.handles.right, self.handles.right_index)
    state.leftGrip = safe_digital_for_hand(self.vrmod, self.handles.grip, self.handles.left, self.handles.left_index)
    state.rightGrip = safe_digital_for_hand(self.vrmod, self.handles.grip, self.handles.right, self.handles.right_index)
    state.x = safe_digital_for_hand(self.vrmod, self.handles.a_button, self.handles.left, self.handles.left_index)
    state.y = safe_digital_for_hand(self.vrmod, self.handles.b_button, self.handles.left, self.handles.left_index)
    state.a = safe_digital_for_hand(self.vrmod, self.handles.a_button, self.handles.right, self.handles.right_index)
    state.b = safe_digital_for_hand(self.vrmod, self.handles.b_button, self.handles.right, self.handles.right_index)

    return state
end

function environment:getVRState()
    return self.state
end

function environment:createGestureSets(inventory)
    self.gestureSets = self.gestures.GestureSets.new(inventory, {
        haptic_player = self.hapticPlayer,
        touch_haptics_player = self.touchHapticsPlayer,
        getVRState = function()
            return environment.state
        end,
    })
    self.gestureTracker = self.gestureSets.defaultGestureSet
    if self.defaultHaptics ~= nil then
        self.haptics.applyCompanionGestureDefaults(self.gestureTracker, self.defaultHaptics)
    end
    return self.gestureSets
end

function environment:initialize(options)
    if self._initialized then
        return self
    end

    self.input.setTimeProvider(function()
        return environment.time.current
    end)

    if options and options.inputBackend then
        self:setInputBackend(options.inputBackend)
    elseif _G.RE9InputBackend ~= nil then
        self:setInputBackend(_G.RE9InputBackend)
    end

    self.touchHapticsPlayer = self.haptics.TouchHapticsPlayer.new(self)
    self.hapticPlayer = self.haptics.HapticPlayer.new(self.touchHapticsPlayer)
    self.defaultHaptics = self.haptics.createCompanionDefaults(self.touchHapticsPlayer)
    self.vrToMouse = self.input.VRToMouse.new(self)
    self:createGestureSets(nil)
    self._initialized = true
    _G.RE9Environment = self
    return self
end

function environment:tick(current_time, delta_time)
    if not self._initialized then
        self:initialize()
    end
    self:updateTime(current_time, delta_time)
    if self.input ~= nil and type(self.input.updatePending) == "function" then
        self.input.updatePending(self.time.current)
    end
    self:sampleVRState()
    if not self.state.isMounted then
        return
    end
    if not self.state.calibrated then
        self:calibrateState()
    end

    local logical_delta = self.time.delta
    if self.updateFrequency > 0.0 then
        self.time.accumulator = self.time.accumulator + self.time.delta
        if self.time.accumulator < self.updateFrequency then
            return
        end
        logical_delta = self.time.accumulator
        self.time.accumulator = 0.0
    end

    if self.gestureSets ~= nil then
        self.gestureSets:update(self.time.current, logical_delta, self.state)
    end
    if self.vrToMouse ~= nil then
        self.vrToMouse:update(self.time.current, logical_delta)
    end
    if self.hapticPlayer ~= nil then
        self.hapticPlayer:update(logical_delta)
    end
    self:syncControllerState()
end

package.loaded[module_name] = environment

return environment