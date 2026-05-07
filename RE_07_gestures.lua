local module_name = "RE_07_gestures"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_07_gestures.lua
-- Core gesture primitives, predefined gesture tracker, and gesture-set switching.
local numerics = require("RE_01_numerics")
local haptics_module = require("RE_05_haptics")
local actions = require("RE_06_actions")

local gestures = {}

local runtime_context = {
    haptic_player = nil,
    touch_haptics_player = nil,
    getVRState = function()
        return nil
    end,
}

local INJECT_SYRINGE_DISTANCE = 0.30
local INJECT_SYRINGE_YAW_OFFSET_DEGREES = 45.0
local inject_syringe_up = numerics.new_vector(0.0, 0.0, 0.0)
local inject_syringe_direction = numerics.new_vector(0.0, 0.0, 0.0)

local function inject_syringe_distance_squared(source_pose, target_pose)
    local angle = math.rad(INJECT_SYRINGE_YAW_OFFSET_DEGREES)
    local cos_angle = math.cos(angle)
    local sin_angle = math.sin(angle)

    numerics.set_vector(
        inject_syringe_up,
        source_pose.up.x or 0.0,
        source_pose.up.y or 0.0,
        source_pose.up.z or 0.0
    )

    numerics.set_vector(
        inject_syringe_direction,
        ((source_pose.forward.x or 0.0) * cos_angle) + (inject_syringe_up.x * sin_angle),
        ((source_pose.forward.y or 0.0) * cos_angle) + (inject_syringe_up.y * sin_angle),
        ((source_pose.forward.z or 0.0) * cos_angle) + (inject_syringe_up.z * sin_angle)
    )

    local direction_length = numerics.length(inject_syringe_direction)
    if direction_length > 1e-6 then
        numerics.scale(inject_syringe_direction, inject_syringe_direction, 1.0 / direction_length)
    end

    local target_point = numerics.set_vector(
        numerics.shared.temp.vector_b,
        (source_pose.position.x or 0.0) + (inject_syringe_direction.x * INJECT_SYRINGE_DISTANCE),
        (source_pose.position.y or 0.0) + (inject_syringe_direction.y * INJECT_SYRINGE_DISTANCE),
        (source_pose.position.z or 0.0) + (inject_syringe_direction.z * INJECT_SYRINGE_DISTANCE)
    )
    return numerics.distance_squared(target_pose.position, target_point)
end

local function derive(base)
    local derived = {}
    derived.__index = derived
    setmetatable(derived, { __index = base })
    return derived
end

local function safe_call(target, method_name, ...)
    if target ~= nil and type(target[method_name]) == "function" then
        return target[method_name](target, ...)
    end
    return nil
end

local function get_current_haptics(action)
    if action ~= nil and type(action.getCurrentHaptics) == "function" then
        return action:getCurrentHaptics()
    end
    return nil
end

local function entered_action(result)
    return result ~= false
end

local function get_context(instance)
    return instance._context or runtime_context
end

local function set_validation(target, trigger, grip)
    target.trigger = trigger or 0.0
    target.grip = grip or 0.0
    target.triggerUsed = false
    target.gripUsed = false
    return target
end

local GestureValidation = {}
GestureValidation.__index = GestureValidation

function GestureValidation.new(trigger, grip)
    return setmetatable({
        trigger = trigger or 0.0,
        grip = grip or 0.0,
        triggerUsed = false,
        gripUsed = false,
    }, GestureValidation)
end

local Gesture = {}
Gesture.__index = Gesture

function Gesture.new(lower_threshold, upper_threshold)
    return setmetatable({
        name = "unnamedGesture",
        lowerThreshold = lower_threshold,
        upperThreshold = upper_threshold,
        coolDown = 0.0,
        _lastActionTime = 0.0,
        _lastTriggerTime = 0.0,
        _lastGripTime = 0.0,
        validationMode = 0,
        validationThreshold = 0.6,
        validationTime = 0.5,
        _validationStartTime = 0.0,
        haptics = haptics_module.HapticsGroup.new(),
        validating = nil,
        touchValidating = nil,
        action = nil,
        triggerAction = nil,
        gripAction = nil,
        triggerLowerThreshold = 0.5,
        triggerUpperThreshold = 0.6,
        gripLowerThreshold = 0.5,
        gripUpperThreshold = 0.6,
        enabled = false,
        _inValidation = false,
        inGesture = false,
        inTriggerGesture = false,
        inGripGesture = false,
        _context = nil,
    }, Gesture)
end

function Gesture:setContext(context)
    self._context = context
    return self
end

function Gesture:reset()
    safe_call(self.action, "reset")
    safe_call(self.triggerAction, "reset")
    safe_call(self.gripAction, "reset")
    self._inValidation = false
    self.inGesture = false
    self.inTriggerGesture = false
    self.inGripGesture = false
end

function Gesture:playHaptics(current_time, haptic_pattern, touch_haptics, phase_name)
    local context = get_context(self)
    local gesture_name = self.name or "unnamedGesture"
    if context.haptic_player ~= nil and haptic_pattern ~= nil then
        context.haptic_player:play_registered(gesture_name, haptic_pattern, phase_name)
    end
    if context.touch_haptics_player ~= nil and touch_haptics ~= nil then
        context.touch_haptics_player:play(touch_haptics, gesture_name, phase_name)
    end
end

function Gesture:_updateBaseGesture(current_time, value, validation, current_haptics)
    local action_haptics = get_current_haptics(self.action)
    if action_haptics ~= nil then
        current_haptics = action_haptics
    end

    if self.inGesture then
        if value > self.upperThreshold then
            self:playHaptics(current_time, current_haptics.leave, current_haptics.touchLeave, "leave")
            safe_call(self.action, "leave")
            self.inGesture = false
            self._lastActionTime = current_time
        else
            self:playHaptics(current_time, current_haptics.hold, current_haptics.touchHold, "hold")
            safe_call(self.action, "update", current_time)
        end
    elseif (current_time - self._lastActionTime) > self.coolDown and value < self.lowerThreshold then
        local valid = false
        if self.validationMode == 0 then
            valid = true
        elseif self.validationMode == 1 then
            if self._inValidation then
                valid = (current_time - self._validationStartTime) > self.validationTime
            end
        elseif self.validationMode == 2 then
            valid = (not validation.triggerUsed) and validation.trigger > self.validationThreshold
        elseif self.validationMode == 3 then
            valid = (not validation.gripUsed) and validation.grip > self.validationThreshold
        end

        if valid then
            local enter_result = safe_call(self.action, "enter", current_time, false)
            if entered_action(enter_result) then
                self:playHaptics(current_time, current_haptics.enter, current_haptics.touchEnter, "enter")
                self.inGesture = true
            end
        end
    end

    if self.inGesture then
        if self.validationMode == 2 then
            validation.triggerUsed = true
        elseif self.validationMode == 3 then
            validation.gripUsed = true
        end
    end
end

function Gesture:_updateTriggerGesture(current_time, value, validation, current_haptics)
    local action_haptics = get_current_haptics(self.triggerAction)
    if action_haptics ~= nil then
        current_haptics = action_haptics
    end

    if self.inTriggerGesture then
        if validation.triggerUsed or value > self.upperThreshold or validation.trigger < self.triggerLowerThreshold then
            self:playHaptics(current_time, current_haptics.leave, current_haptics.touchLeave, "leave")
            safe_call(self.triggerAction, "leave")
            self.inTriggerGesture = false
            self._lastTriggerTime = current_time
        else
            self:playHaptics(current_time, current_haptics.hold, current_haptics.touchHold, "hold")
            safe_call(self.triggerAction, "update", current_time)
        end
    elseif (current_time - self._lastTriggerTime) > self.coolDown
        and (not validation.triggerUsed)
        and value < self.lowerThreshold
        and validation.trigger > self.triggerUpperThreshold then
        local enter_result = safe_call(self.triggerAction, "enter", current_time, false)
        if entered_action(enter_result) then
            self:playHaptics(current_time, current_haptics.enter, current_haptics.touchEnter, "enter")
            self.inTriggerGesture = true
        end
    end

    if self.inTriggerGesture then
        validation.triggerUsed = true
    end
end

function Gesture:_updateGripGesture(current_time, value, validation, current_haptics)
    local action_haptics = get_current_haptics(self.gripAction)
    if action_haptics ~= nil then
        current_haptics = action_haptics
    end

    if self.inGripGesture then
        if validation.gripUsed or value > self.upperThreshold or validation.grip < self.gripLowerThreshold then
            self:playHaptics(current_time, current_haptics.leave, current_haptics.touchLeave, "leave")
            safe_call(self.gripAction, "leave")
            self.inGripGesture = false
            self._lastGripTime = current_time
        else
            self:playHaptics(current_time, current_haptics.hold, current_haptics.touchHold, "hold")
            safe_call(self.gripAction, "update", current_time)
        end
    elseif (current_time - self._lastGripTime) > self.coolDown
        and (not validation.gripUsed)
        and value < self.lowerThreshold
        and validation.grip > self.gripUpperThreshold then
        local enter_result = safe_call(self.gripAction, "enter", current_time, false)
        if entered_action(enter_result) then
            self:playHaptics(current_time, current_haptics.enter, current_haptics.touchEnter, "enter")
            self.inGripGesture = true
        end
    end

    if self.inGripGesture then
        validation.gripUsed = true
    end
end

function Gesture:_updateCore(current_time, value, validation, current_haptics)
    if self.action ~= nil then
        self:_updateBaseGesture(current_time, value, validation, current_haptics)
    end
    if self.triggerAction ~= nil then
        self:_updateTriggerGesture(current_time, value, validation, current_haptics)
    end
    if self.gripAction ~= nil then
        self:_updateGripGesture(current_time, value, validation, current_haptics)
    end

    if self.inGesture or self.inTriggerGesture or self.inGripGesture then
        self._inValidation = false
    elseif value < self.lowerThreshold then
        if not self._inValidation then
            self:playHaptics(current_time, self.validating, self.touchValidating, "validating")
            self._inValidation = true
            self._validationStartTime = current_time
        end
    else
        self._inValidation = false
    end
end

function Gesture:update(current_time, value, validation)
    self:_updateCore(current_time, value, validation, self.haptics)
end

local LocationBasedGesture = derive(Gesture)

local function compute_location_center(head_pose, offset, out)
    out = out or numerics.new_vector(0.0, 0.0, 0.0)
    if head_pose == nil then
        return numerics.set_vector(out, 0.0, 0.0, 0.0)
    end

    return numerics.set_vector(
        out,
        (head_pose.position.x or 0.0)
            - ((head_pose.left.x or 0.0) * (offset.x or 0.0))
            + ((head_pose.forward.x or 0.0) * (offset.z or 0.0)),
        (head_pose.position.y or 0.0) + (offset.y or 0.0),
        (head_pose.position.z or 0.0)
            - ((head_pose.left.z or 0.0) * (offset.x or 0.0))
            + ((head_pose.forward.z or 0.0) * (offset.z or 0.0))
    )
end

function LocationBasedGesture.new(lower_threshold, upper_threshold, offset)
    local instance = Gesture.new(lower_threshold, upper_threshold)
    instance.offset = offset
    return setmetatable(instance, LocationBasedGesture)
end

function LocationBasedGesture:getWorldCenter(head_pose, out)
    return compute_location_center(head_pose, self.offset, out)
end

local GestureTracker = {}
GestureTracker.__index = GestureTracker

local function register_gesture(tracker, name, gesture)
    gesture:setContext(tracker._context)
    gesture.name = name
    tracker[name] = gesture
    return gesture
end

local function add_all(target, source)
    for _, value in ipairs(source) do
        target[#target + 1] = value
    end
end

local function update_if_enabled(gesture, current_time, value, validation)
    if gesture.enabled then
        gesture:update(current_time, value, validation)
    end
end

function GestureTracker.new(inventory, context)
    local tracker = setmetatable({
        enter = nil,
        leave = nil,
        _context = context or runtime_context,
        _cache = {
            headBasis = {},
            leftValidation = GestureValidation.new(0.0, 0.0),
            rightValidation = GestureValidation.new(0.0, 0.0),
            noneValidation = GestureValidation.new(1.0, 1.0),
            leftMetrics = {},
            rightMetrics = {},
            relativeMetrics = {},
        },
        _previousLeftPosition = numerics.new_vector(0.0, 0.0, 0.0),
        _previousRightPosition = numerics.new_vector(0.0, 0.0, 0.0),
        _motionInitialized = false,
    }, GestureTracker)

    register_gesture(tracker, "aimPistol", Gesture.new(0.02, 0.03))
    register_gesture(tracker, "aimRifleLeft", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "aimRifleRight", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "buttonA", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "buttonB", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "buttonX", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "buttonY", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "buttonLeftStick", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "buttonLeftStickUp", Gesture.new(-0.2, -0.05))
    register_gesture(tracker, "buttonLeftStickDown", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "buttonLeftStickLeft", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "buttonLeftStickRight", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "buttonLeftStickInnerRing", Gesture.new(0.5, 0.5))
    register_gesture(tracker, "buttonLeftStickOuterRing", Gesture.new(-0.9, -0.9))
    register_gesture(tracker, "buttonRightStick", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "buttonRightStickUp", Gesture.new(-0.2, -0.05))
    register_gesture(tracker, "buttonRightStickDown", Gesture.new(-0.9, -0.85))
    register_gesture(tracker, "buttonRightStickLeft", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "buttonRightStickRight", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "buttonRightStickInnerRing", Gesture.new(0.5, 0.5))
    register_gesture(tracker, "buttonRightStickOuterRing", Gesture.new(-0.9, -0.9))
    register_gesture(tracker, "duck", Gesture.new(-0.2, -0.1))
    register_gesture(tracker, "gripLeft", Gesture.new(-0.95, -0.9))
    register_gesture(tracker, "gripRight", Gesture.new(-0.6, -0.4))
    register_gesture(tracker, "holsterInventoryLeft", LocationBasedGesture.new(0.05, 0.1, numerics.new_vector(-0.3, -0.75, 0.1)))
    register_gesture(tracker, "holsterInventoryRight", LocationBasedGesture.new(0.05, 0.1, numerics.new_vector(0.3, -0.75, 0.1)))
    register_gesture(tracker, "holsterWeaponLeft", LocationBasedGesture.new(0.05, 0.1, numerics.new_vector(-0.3, -0.75, 0.1)))
    register_gesture(tracker, "holsterWeaponRight", LocationBasedGesture.new(0.02, 0.05, numerics.new_vector(0.3, -0.75, 0.1)))
    register_gesture(tracker, "leanLeft", Gesture.new(-0.55, -0.45))
    register_gesture(tracker, "leanRight", Gesture.new(-0.55, -0.45))
    register_gesture(tracker, "lightLeft", LocationBasedGesture.new(0.04, 0.05, numerics.new_vector(0.0, 0.0, 0.0)))
    register_gesture(tracker, "lightRight", LocationBasedGesture.new(0.04, 0.05, numerics.new_vector(0.0, 0.0, 0.0)))
    register_gesture(tracker, "chestLeft", LocationBasedGesture.new(0.02, 0.02, numerics.new_vector(-0.1, -0.4, 0.0)))
    register_gesture(tracker, "chestRight", LocationBasedGesture.new(0.02, 0.02, numerics.new_vector(-0.1, -0.4, 0.0)))
    register_gesture(tracker, "lowerAreaLeft", Gesture.new(-0.7, -0.6))
    register_gesture(tracker, "lowerAreaRight", Gesture.new(-0.7, -0.6))
    register_gesture(tracker, "meleeLeft", Gesture.new(-18.0, -16.0))
    register_gesture(tracker, "meleeLeftAlt", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "meleeLeftAltPull", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "meleeLeftAltPush", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "meleeRight", Gesture.new(-8.0, -6.0))
    register_gesture(tracker, "meleeRightAlt", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "meleeRightAltPull", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "meleeRightAltPush", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "shoulderInventoryLeft", LocationBasedGesture.new(0.01, 0.02, numerics.new_vector(-0.25, 0.0, 0.1)))
    register_gesture(tracker, "shoulderInventoryRight", LocationBasedGesture.new(0.05, 0.1, numerics.new_vector(0.3, 0.0, 0.0)))
    register_gesture(tracker, "shoulderWeaponLeft", LocationBasedGesture.new(0.05, 0.05, numerics.new_vector(-0.3, 0.0, 0.0)))
    register_gesture(tracker, "shoulderWeaponRight", LocationBasedGesture.new(0.01, 0.02, numerics.new_vector(0.2, -0.1, 0.15)))
    register_gesture(tracker, "triggerLeft", Gesture.new(-0.6, -0.4))
    register_gesture(tracker, "triggerRight", Gesture.new(-0.6, -0.4))
    register_gesture(tracker, "upperAreaLeft", Gesture.new(0.2, 0.3))
    register_gesture(tracker, "upperAreaRight", Gesture.new(0.2, 0.3))
    register_gesture(tracker, "useLeftUp", Gesture.new(-0.9, -0.8))
    register_gesture(tracker, "useRightUp", Gesture.new(-0.9, -0.8))
    register_gesture(tracker, "useLeftDown", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "useRightDown", Gesture.new(-0.8, -0.7))
    register_gesture(tracker, "foreheadLeft", LocationBasedGesture.new(0.02, 0.04, numerics.new_vector(0.0, 0.05, -0.15)))
    register_gesture(tracker, "foreheadRight", LocationBasedGesture.new(0.02, 0.04, numerics.new_vector(0.0, 0.05, -0.15)))
    register_gesture(tracker, "holsterBackLeft", LocationBasedGesture.new(0.03, 0.04, numerics.new_vector(0.0, -0.63, 0.15)))
    register_gesture(tracker, "holsterBackRight", LocationBasedGesture.new(0.03, 0.04, numerics.new_vector(0.0, -0.63, 0.15)))
    register_gesture(tracker, "swipeLeftHandLeft", Gesture.new(-4.0, -2.0))
    register_gesture(tracker, "swipeLeftHandRight", Gesture.new(-0.8, -0.6))
    register_gesture(tracker, "swipeLeftHandUp", Gesture.new(-0.5, -0.4))
    register_gesture(tracker, "swipeLeftHandDown", Gesture.new(-5.0, -4.0))
    register_gesture(tracker, "swipeRightHandLeft", Gesture.new(-4.0, -2.0))
    register_gesture(tracker, "swipeRightHandRight", Gesture.new(-2.0, -1.0))
    register_gesture(tracker, "swipeRightHandUp", Gesture.new(-0.8, -0.6))
    register_gesture(tracker, "swipeRightHandDown", Gesture.new(-5.0, -4.0))
    register_gesture(tracker, "circleSkyLeft", Gesture.new(-0.7, -0.5))
    register_gesture(tracker, "circleSkyRight", Gesture.new(-0.7, -0.5))
    register_gesture(tracker, "circleFloorLeft", Gesture.new(-0.7, -0.5))
    register_gesture(tracker, "circleFloorRight", Gesture.new(-0.7, -0.5))
    register_gesture(tracker, "shakeLeft", Gesture.new(-0.8, -0.6))
    register_gesture(tracker, "shakeRight", Gesture.new(-0.8, -0.6))
    register_gesture(tracker, "thrustLeft", Gesture.new(-8.0, -6.0))
    register_gesture(tracker, "retractLeft", Gesture.new(-12.0, -8.0))
    register_gesture(tracker, "thrustRight", Gesture.new(-8.0, -6.0))
    register_gesture(tracker, "retractRight", Gesture.new(-12.0, -8.0))
    register_gesture(tracker, "pullPin", Gesture.new(-3.0, -2.0))
    register_gesture(tracker, "axeSharpen", Gesture.new(0.03, 0.04))
    register_gesture(tracker, "injectSyringe", Gesture.new(0.03, 0.04))

    tracker.leftMeleeAltThreshold = -0.5
    tracker.rightMeleeAltThreshold = -0.5

    tracker.meleeLeft.coolDown = 0.2
    tracker.meleeLeftAlt.coolDown = 0.2
    tracker.meleeLeftAltPull.coolDown = 0.2
    tracker.meleeLeftAltPush.coolDown = 0.2
    tracker.meleeRight.coolDown = 0.2
    tracker.meleeRightAlt.coolDown = 0.2
    tracker.meleeRightAltPull.coolDown = 0.2
    tracker.meleeRightAltPush.coolDown = 0.2
    tracker.swipeLeftHandLeft.coolDown = 0.5
    tracker.swipeLeftHandRight.coolDown = 0.5
    tracker.swipeLeftHandUp.coolDown = 0.5
    tracker.swipeLeftHandDown.coolDown = 0.5
    tracker.swipeRightHandLeft.coolDown = 0.5
    tracker.swipeRightHandRight.coolDown = 0.5
    tracker.swipeRightHandUp.coolDown = 0.5
    tracker.swipeRightHandDown.coolDown = 0.5
    tracker.circleSkyLeft.coolDown = 1.0
    tracker.circleSkyRight.coolDown = 1.0
    tracker.circleFloorLeft.coolDown = 1.0
    tracker.circleFloorRight.coolDown = 1.0
    tracker.shakeLeft.coolDown = 0.01
    tracker.shakeRight.coolDown = 0.01
    tracker.thrustLeft.coolDown = 0.1
    tracker.retractLeft.coolDown = 0.5
    tracker.thrustRight.coolDown = 0.1
    tracker.retractRight.coolDown = 0.5
    tracker.pullPin.coolDown = 0.5
    tracker.axeSharpen.coolDown = 0.5
    tracker.injectSyringe.coolDown = 0.5

    tracker.triggerLeft.validationMode = 2
    tracker.triggerRight.validationMode = 2
    tracker.gripLeft.validationMode = 3
    tracker.gripRight.validationMode = 3

    tracker.fireWeaponLeft = tracker.triggerLeft
    tracker.fireWeaponRight = tracker.triggerRight
    tracker.grabLeft = tracker.gripLeft
    tracker.grabRight = tracker.gripRight

    tracker._locationBasedGesturesLeft = {
        tracker.holsterInventoryLeft,
        tracker.holsterInventoryRight,
        tracker.lightLeft,
        tracker.chestLeft,
        tracker.shoulderInventoryLeft,
        tracker.shoulderInventoryRight,
        tracker.foreheadLeft,
        tracker.holsterBackLeft,
    }

    tracker._locationBasedGesturesRight = {
        tracker.holsterWeaponLeft,
        tracker.holsterWeaponRight,
        tracker.lightRight,
        tracker.chestRight,
        tracker.shoulderWeaponLeft,
        tracker.shoulderWeaponRight,
        tracker.foreheadRight,
        tracker.holsterBackRight,
    }

    tracker._allGestures = {}
    add_all(tracker._allGestures, {
        tracker.aimPistol,
        tracker.aimRifleLeft,
        tracker.aimRifleRight,
        tracker.buttonA,
        tracker.buttonB,
        tracker.buttonX,
        tracker.buttonY,
        tracker.buttonLeftStick,
        tracker.buttonLeftStickUp,
        tracker.buttonLeftStickDown,
        tracker.buttonLeftStickLeft,
        tracker.buttonLeftStickRight,
        tracker.buttonLeftStickInnerRing,
        tracker.buttonLeftStickOuterRing,
        tracker.buttonRightStick,
        tracker.buttonRightStickUp,
        tracker.buttonRightStickDown,
        tracker.buttonRightStickLeft,
        tracker.buttonRightStickRight,
        tracker.buttonRightStickInnerRing,
        tracker.buttonRightStickOuterRing,
        tracker.duck,
        tracker.gripLeft,
        tracker.gripRight,
        tracker.holsterInventoryLeft,
        tracker.holsterInventoryRight,
        tracker.holsterWeaponLeft,
        tracker.holsterWeaponRight,
        tracker.leanLeft,
        tracker.leanRight,
        tracker.lightLeft,
        tracker.lightRight,
        tracker.chestLeft,
        tracker.chestRight,
        tracker.lowerAreaLeft,
        tracker.lowerAreaRight,
        tracker.meleeLeft,
        tracker.meleeLeftAlt,
        tracker.meleeLeftAltPull,
        tracker.meleeLeftAltPush,
        tracker.meleeRight,
        tracker.meleeRightAlt,
        tracker.meleeRightAltPull,
        tracker.meleeRightAltPush,
        tracker.shoulderInventoryLeft,
        tracker.shoulderInventoryRight,
        tracker.shoulderWeaponLeft,
        tracker.shoulderWeaponRight,
        tracker.triggerLeft,
        tracker.triggerRight,
        tracker.upperAreaLeft,
        tracker.upperAreaRight,
        tracker.useLeftUp,
        tracker.useRightUp,
        tracker.useLeftDown,
        tracker.useRightDown,
        tracker.swipeLeftHandLeft,
        tracker.swipeLeftHandRight,
        tracker.swipeLeftHandUp,
        tracker.swipeLeftHandDown,
        tracker.swipeRightHandLeft,
        tracker.swipeRightHandRight,
        tracker.swipeRightHandUp,
        tracker.swipeRightHandDown,
        tracker.foreheadLeft,
        tracker.foreheadRight,
        tracker.holsterBackLeft,
        tracker.holsterBackRight,
        tracker.circleSkyLeft,
        tracker.circleSkyRight,
        tracker.circleFloorLeft,
        tracker.circleFloorRight,
        tracker.shakeLeft,
        tracker.shakeRight,
        tracker.thrustLeft,
        tracker.retractLeft,
        tracker.thrustRight,
        tracker.retractRight,
        tracker.pullPin,
        tracker.axeSharpen,
        tracker.injectSyringe,
    })

    return tracker
end

function GestureTracker:addLocationBasedGesture(left_hand, lower_threshold, upper_threshold, offset)
    local gesture = LocationBasedGesture.new(lower_threshold, upper_threshold, offset)
    gesture:setContext(self._context)
    if left_hand then
        self._locationBasedGesturesLeft[#self._locationBasedGesturesLeft + 1] = gesture
    else
        self._locationBasedGesturesRight[#self._locationBasedGesturesRight + 1] = gesture
    end
    self._allGestures[#self._allGestures + 1] = gesture
    return gesture
end

function GestureTracker:reset()
    for _, gesture in ipairs(self._allGestures) do
        gesture:reset()
    end
    self._motionInitialized = false
end

function GestureTracker:update(current_time, delta_time, vr_state)
    local context = self._context or runtime_context
    if vr_state == nil and context.getVRState ~= nil then
        vr_state = context.getVRState()
    end
    if vr_state == nil or not vr_state.isMounted then
        return
    end

    local left_validation = set_validation(self._cache.leftValidation, vr_state.leftTrigger, vr_state.leftGrip)
    local right_validation = set_validation(self._cache.rightValidation, vr_state.rightTrigger, vr_state.rightGrip)
    local none_validation = set_validation(self._cache.noneValidation, 1.0, 1.0)
    local left_previous = vr_state.leftController or self._previousLeftPosition
    local right_previous = vr_state.rightController or self._previousRightPosition

    if not self._motionInitialized then
        numerics.copy_vector(left_previous, vr_state.leftTouchPose.position)
        numerics.copy_vector(right_previous, vr_state.rightTouchPose.position)
        numerics.copy_vector(self._previousLeftPosition, vr_state.leftTouchPose.position)
        numerics.copy_vector(self._previousRightPosition, vr_state.rightTouchPose.position)
        self._motionInitialized = true
    end

    local basis = numerics.compute_head_basis(vr_state.headPose, self._cache.headBasis)
    local swipe_speed_threshold = 1.0
    local swipe_purity = 1.5
    local shake_min = 0.8
    local shake_max = 5.0
    local shake_maintain = 0.8
    local thrust_retract_min = 8.0
    local thrust_retract_purity = 1.5

    update_if_enabled(self.lowerAreaLeft, current_time, (vr_state.leftTouchPose.position.y or 0.0) - (vr_state.headPose.position.y or 0.0), left_validation)
    update_if_enabled(self.lowerAreaRight, current_time, (vr_state.rightTouchPose.position.y or 0.0) - (vr_state.headPose.position.y or 0.0), right_validation)
    update_if_enabled(self.upperAreaLeft, current_time, (vr_state.headPose.position.y or 0.0) - (vr_state.leftTouchPose.position.y or 0.0), left_validation)
    update_if_enabled(self.upperAreaRight, current_time, (vr_state.headPose.position.y or 0.0) - (vr_state.rightTouchPose.position.y or 0.0), right_validation)

    if self.aimPistol.enabled then
        self.aimPistol:update(current_time, numerics.distance_squared(vr_state.leftTouchPose.position, vr_state.rightTouchPose.position), left_validation)
    end

    if self.aimRifleRight.enabled then
        if self.aimPistol.inGesture or numerics.dot_product(vr_state.leftTouchPose.forward, vr_state.headPose.forward) < 0.5 then
            self.aimRifleRight:update(current_time, 0.0, right_validation)
        else
            local dx = (vr_state.rightTouchPose.position.x or 0.0) - (vr_state.headPose.position.x or 0.0)
            local dz = (vr_state.rightTouchPose.position.z or 0.0) - (vr_state.headPose.position.z or 0.0)
            self.aimRifleRight:update(current_time, -((dx * dx) + (dz * dz)), right_validation)
        end
    end

    if self.aimRifleLeft.enabled then
        if self.aimPistol.inGesture or self.aimRifleRight.inGesture or numerics.dot_product(vr_state.leftTouchPose.forward, vr_state.headPose.forward) < 0.5 then
            self.aimRifleLeft:update(current_time, 0.0, left_validation)
        else
            local dx = (vr_state.leftTouchPose.position.x or 0.0) - (vr_state.headPose.position.x or 0.0)
            local dz = (vr_state.leftTouchPose.position.z or 0.0) - (vr_state.headPose.position.z or 0.0)
            self.aimRifleLeft:update(current_time, -((dx * dx) + (dz * dz)), left_validation)
        end
    end

    update_if_enabled(self.buttonA, current_time, -(vr_state.a or 0.0), right_validation)
    update_if_enabled(self.buttonB, current_time, -(vr_state.b or 0.0), right_validation)
    update_if_enabled(self.buttonRightStick, current_time, -(vr_state.rightStick or 0.0), right_validation)
    update_if_enabled(self.buttonX, current_time, -(vr_state.x or 0.0), left_validation)
    update_if_enabled(self.buttonY, current_time, -(vr_state.y or 0.0), left_validation)
    update_if_enabled(self.buttonLeftStick, current_time, -(vr_state.leftStick or 0.0), left_validation)
    update_if_enabled(self.buttonLeftStickUp, current_time, -(vr_state.leftStickAxes.y or 0.0), left_validation)
    update_if_enabled(self.buttonLeftStickDown, current_time, vr_state.leftStickAxes.y or 0.0, left_validation)
    update_if_enabled(self.buttonLeftStickLeft, current_time, vr_state.leftStickAxes.x or 0.0, left_validation)
    update_if_enabled(self.buttonLeftStickRight, current_time, -(vr_state.leftStickAxes.x or 0.0), left_validation)

    local left_stick = math.sqrt(((vr_state.leftStickAxes.x or 0.0) ^ 2) + ((vr_state.leftStickAxes.y or 0.0) ^ 2))
    update_if_enabled(self.buttonLeftStickInnerRing, current_time, left_stick, left_validation)
    update_if_enabled(self.buttonLeftStickOuterRing, current_time, -left_stick, left_validation)

    update_if_enabled(self.buttonRightStickUp, current_time, -(vr_state.rightStickAxes.y or 0.0), right_validation)
    update_if_enabled(self.buttonRightStickDown, current_time, vr_state.rightStickAxes.y or 0.0, right_validation)
    update_if_enabled(self.buttonRightStickLeft, current_time, vr_state.rightStickAxes.x or 0.0, right_validation)
    update_if_enabled(self.buttonRightStickRight, current_time, -(vr_state.rightStickAxes.x or 0.0), right_validation)

    local right_stick = math.sqrt(((vr_state.rightStickAxes.x or 0.0) ^ 2) + ((vr_state.rightStickAxes.y or 0.0) ^ 2))
    update_if_enabled(self.buttonRightStickInnerRing, current_time, right_stick, right_validation)
    update_if_enabled(self.buttonRightStickOuterRing, current_time, -right_stick, right_validation)

    update_if_enabled(self.duck, current_time, (vr_state.headPose.position.y or 0.0) - (vr_state.standingHeight or 0.0), none_validation)

    local roll = numerics.get_roll(vr_state.headPose)
    update_if_enabled(self.leanLeft, current_time, roll - (vr_state.rollCenter or 0.0), none_validation)
    update_if_enabled(self.leanRight, current_time, (vr_state.rollCenter or 0.0) - roll, none_validation)

    actions.updateActiveActions(current_time)

    local left_metrics = numerics.compute_motion_metrics(vr_state.leftTouchPose, left_previous, delta_time, basis, self._cache.leftMetrics, 0.9)
    local right_metrics = numerics.compute_motion_metrics(vr_state.rightTouchPose, right_previous, delta_time, basis, self._cache.rightMetrics, 0.7)
    local left_melee_action = -1
    local right_melee_action = -1

    update_if_enabled(self.useLeftUp, current_time, vr_state.leftTouchPose.left.y or 0.0, left_validation)
    update_if_enabled(self.useLeftDown, current_time, -(vr_state.leftTouchPose.left.y or 0.0), left_validation)

    if self.circleSkyLeft.enabled then
        if left_metrics.distance2 > 2.0 then
            self.circleSkyLeft:update(current_time, 0.0, left_validation)
        elseif not self.circleSkyLeft.inGesture then
            if (vr_state.leftTouchPose.forward.y or 0.0) < -0.9 and left_metrics.speed_xz > 1.0 and left_metrics.speed_xz > (math.abs(left_metrics.dy) * 1.5) then
                self.circleSkyLeft:update(current_time, -1.0, left_validation)
            else
                self.circleSkyLeft:update(current_time, 0.0, left_validation)
            end
        else
            self.circleSkyLeft:update(current_time, left_metrics.speed > 0.1 and -1.0 or 0.0, left_validation)
        end
    end

    if self.circleFloorLeft.enabled then
        if left_metrics.distance2 > 2.0 then
            self.circleFloorLeft:update(current_time, 0.0, left_validation)
        elseif not self.circleFloorLeft.inGesture then
            if (vr_state.leftTouchPose.forward.y or 0.0) > 0.9 and left_metrics.speed_xz > 1.0 and left_metrics.speed_xz > (math.abs(left_metrics.dy) * 1.5) then
                self.circleFloorLeft:update(current_time, -1.0, left_validation)
            else
                self.circleFloorLeft:update(current_time, 0.0, left_validation)
            end
        else
            self.circleFloorLeft:update(current_time, left_metrics.speed > 0.1 and -1.0 or 0.0, left_validation)
        end
    end

    if left_melee_action == -1 then
        local swipe_up = 0.0
        local swipe_down = 0.0
        local swipe_left = 0.0
        local swipe_right = 0.0
        if left_metrics.speed > swipe_speed_threshold and left_metrics.is_horizontal then
            if numerics.is_pure_axis(left_metrics.dy, left_metrics.dx, left_metrics.dz, swipe_purity) then
                if left_metrics.dy > 0.0 then
                    swipe_up = -left_metrics.speed
                else
                    swipe_down = -left_metrics.speed
                end
            elseif numerics.is_pure_axis(left_metrics.dx, left_metrics.dy, left_metrics.dz, swipe_purity) then
                if left_metrics.dx > 0.0 then
                    swipe_left = -left_metrics.speed
                else
                    swipe_right = -left_metrics.speed
                end
            end
        end
        self.swipeLeftHandUp:update(current_time, swipe_up, left_validation)
        self.swipeLeftHandDown:update(current_time, swipe_down, left_validation)
        self.swipeLeftHandLeft:update(current_time, swipe_left, left_validation)
        self.swipeLeftHandRight:update(current_time, swipe_right, left_validation)
        if self.swipeLeftHandUp.inGesture or self.swipeLeftHandDown.inGesture or self.swipeLeftHandLeft.inGesture or self.swipeLeftHandRight.inGesture then
            left_melee_action = 5
        end
    end

    local left_pure_z = numerics.is_pure_axis(left_metrics.dz, left_metrics.dx, left_metrics.dy, thrust_retract_purity)
    if left_melee_action == -1 then
        local thrust_input = 0.0
        if left_metrics.distance2 > thrust_retract_min and left_metrics.dz < 0.0 and left_pure_z then
            thrust_input = -left_metrics.distance2
        end
        self.thrustLeft:update(current_time, thrust_input, left_validation)
        if self.thrustLeft.inGesture then
            left_melee_action = 6
        end
    end

    if left_melee_action == -1 then
        local retract_input = 0.0
        if left_metrics.distance2 > thrust_retract_min and left_metrics.dz > 0.0 and left_pure_z then
            retract_input = -left_metrics.distance2
        end
        self.retractLeft:update(current_time, retract_input, left_validation)
        if self.retractLeft.inGesture then
            left_melee_action = 7
        end
    end

    if left_melee_action == -1 then
        local shake_input = 0.0
        if math.abs(left_metrics.dz) < 0.5 then
            if not self.shakeLeft.inGesture then
                if left_metrics.speed > shake_min and left_metrics.speed < shake_max then
                    shake_input = -1.0
                end
            elseif left_metrics.speed > shake_maintain then
                shake_input = -1.0
            end
        end
        self.shakeLeft:update(current_time, shake_input, left_validation)
        if self.shakeLeft.inGesture then
            left_melee_action = 4
        end
    end

    if left_melee_action == -1 then
        local push_input = 0.0
        if (vr_state.leftTouchPose.forward.y or 0.0) < self.leftMeleeAltThreshold then
            local dot = numerics.dot_product(vr_state.leftTouchPose.left, vr_state.headPose.forward)
            if self.meleeLeftAltPush.enabled and dot < -0.5 then
                push_input = -left_metrics.distance2
            end
        end
        self.meleeLeftAltPush:update(current_time, push_input, left_validation)
        if self.meleeLeftAltPush.inGesture then
            left_melee_action = 2
        end
    end

    if left_melee_action == -1 then
        local pull_input = 0.0
        if (vr_state.leftTouchPose.forward.y or 0.0) < self.leftMeleeAltThreshold then
            local dot = numerics.dot_product(vr_state.leftTouchPose.left, vr_state.headPose.forward)
            if self.meleeLeftAltPull.enabled and dot > 0.5 then
                pull_input = -left_metrics.distance2
            end
        end
        self.meleeLeftAltPull:update(current_time, pull_input, left_validation)
        if self.meleeLeftAltPull.inGesture then
            left_melee_action = 3
        end
    end

    if left_melee_action == -1 then
        local alt_input = 0.0
        if (vr_state.leftTouchPose.forward.y or 0.0) < self.leftMeleeAltThreshold and self.meleeLeftAlt.enabled then
            alt_input = -left_metrics.distance2
        end
        self.meleeLeftAlt:update(current_time, alt_input, left_validation)
        if self.meleeLeftAlt.inGesture then
            left_melee_action = 1
        end
    end

    if left_melee_action == -1 and self.meleeLeft.enabled then
        local melee_input = 0.0
        if not (left_pure_z or (left_metrics.is_vertical and math.abs(left_metrics.dy) <= 1.5)) then
            melee_input = -left_metrics.distance2
        end
        self.meleeLeft:update(current_time, melee_input, left_validation)
        if self.meleeLeft.inGesture then
            left_melee_action = 0
        end
    end

    update_if_enabled(self.useRightUp, current_time, -(vr_state.rightTouchPose.left.y or 0.0), right_validation)
    update_if_enabled(self.useRightDown, current_time, vr_state.rightTouchPose.left.y or 0.0, right_validation)

    if self.circleSkyRight.enabled then
        if right_metrics.distance2 > 2.0 then
            self.circleSkyRight:update(current_time, 0.0, right_validation)
        elseif not self.circleSkyRight.inGesture then
            if (vr_state.rightTouchPose.forward.y or 0.0) < -0.9 and right_metrics.speed_xz > 1.0 and right_metrics.speed_xz > (math.abs(right_metrics.dy) * 1.5) then
                self.circleSkyRight:update(current_time, -1.0, right_validation)
            else
                self.circleSkyRight:update(current_time, 0.0, right_validation)
            end
        else
            self.circleSkyRight:update(current_time, right_metrics.speed > 0.1 and -1.0 or 0.0, right_validation)
        end
    end

    if self.circleFloorRight.enabled then
        if right_metrics.distance2 > 2.0 then
            self.circleFloorRight:update(current_time, 0.0, right_validation)
        elseif not self.circleFloorRight.inGesture then
            if (vr_state.rightTouchPose.forward.y or 0.0) > 0.9 and right_metrics.speed_xz > 1.0 and right_metrics.speed_xz > (math.abs(right_metrics.dy) * 1.5) then
                self.circleFloorRight:update(current_time, -1.0, right_validation)
            else
                self.circleFloorRight:update(current_time, 0.0, right_validation)
            end
        else
            self.circleFloorRight:update(current_time, right_metrics.speed > 0.1 and -1.0 or 0.0, right_validation)
        end
    end

    if right_melee_action == -1 then
        local swipe_up = 0.0
        local swipe_down = 0.0
        local swipe_left = 0.0
        local swipe_right = 0.0
        if right_metrics.speed > swipe_speed_threshold and right_metrics.is_horizontal then
            if numerics.is_pure_axis(right_metrics.dy, right_metrics.dx, right_metrics.dz, swipe_purity) then
                if right_metrics.dy > 0.0 then
                    swipe_up = -right_metrics.speed
                else
                    swipe_down = -right_metrics.speed
                end
            elseif numerics.is_pure_axis(right_metrics.dx, right_metrics.dy, right_metrics.dz, swipe_purity) then
                if right_metrics.dx > 0.0 then
                    swipe_left = -right_metrics.speed
                else
                    swipe_right = -right_metrics.speed
                end
            end
        end
        self.swipeRightHandUp:update(current_time, swipe_up, right_validation)
        self.swipeRightHandDown:update(current_time, swipe_down, right_validation)
        self.swipeRightHandLeft:update(current_time, swipe_left, right_validation)
        self.swipeRightHandRight:update(current_time, swipe_right, right_validation)
        if self.swipeRightHandUp.inGesture or self.swipeRightHandDown.inGesture or self.swipeRightHandLeft.inGesture or self.swipeRightHandRight.inGesture then
            right_melee_action = 5
        end
    end

    local right_pure_z = numerics.is_pure_axis(right_metrics.dz, right_metrics.dx, right_metrics.dy, thrust_retract_purity)
    if right_melee_action == -1 then
        local thrust_input = 0.0
        if right_metrics.distance2 > thrust_retract_min and right_metrics.dz < 0.0 and right_pure_z then
            thrust_input = -right_metrics.distance2
        end
        self.thrustRight:update(current_time, thrust_input, right_validation)
        if self.thrustRight.inGesture then
            right_melee_action = 6
        end
    end

    if right_melee_action == -1 then
        local retract_input = 0.0
        if right_metrics.distance2 > thrust_retract_min and right_metrics.dz > 0.0 and right_pure_z then
            retract_input = -right_metrics.distance2
        end
        self.retractRight:update(current_time, retract_input, right_validation)
        if self.retractRight.inGesture then
            right_melee_action = 7
        end
    end

    if right_melee_action == -1 then
        local shake_input = 0.0
        if math.abs(right_metrics.dz) < 0.5 then
            if not self.shakeRight.inGesture then
                if right_metrics.speed > shake_min and right_metrics.speed < shake_max then
                    shake_input = -1.0
                end
            elseif right_metrics.speed > shake_maintain then
                shake_input = -1.0
            end
        end
        self.shakeRight:update(current_time, shake_input, right_validation)
        if self.shakeRight.inGesture then
            right_melee_action = 4
        end
    end

    if right_melee_action == -1 then
        local push_input = 0.0
        if (vr_state.rightTouchPose.forward.y or 0.0) < self.rightMeleeAltThreshold then
            local dot = numerics.dot_product(vr_state.rightTouchPose.left, vr_state.headPose.forward)
            if self.meleeRightAltPush.enabled and dot < -0.5 then
                push_input = -right_metrics.distance2
            end
        end
        self.meleeRightAltPush:update(current_time, push_input, right_validation)
        if self.meleeRightAltPush.inGesture then
            right_melee_action = 2
        end
    end

    if right_melee_action == -1 then
        local pull_input = 0.0
        if (vr_state.rightTouchPose.forward.y or 0.0) < self.rightMeleeAltThreshold then
            local dot = numerics.dot_product(vr_state.rightTouchPose.left, vr_state.headPose.forward)
            if self.meleeRightAltPull.enabled and dot > 0.5 then
                pull_input = -right_metrics.distance2
            end
        end
        self.meleeRightAltPull:update(current_time, pull_input, right_validation)
        if self.meleeRightAltPull.inGesture then
            right_melee_action = 3
        end
    end

    if right_melee_action == -1 then
        local alt_input = 0.0
        if (vr_state.rightTouchPose.forward.y or 0.0) < self.rightMeleeAltThreshold and self.meleeRightAlt.enabled then
            alt_input = -right_metrics.distance2
        end
        self.meleeRightAlt:update(current_time, alt_input, right_validation)
        if self.meleeRightAlt.inGesture then
            right_melee_action = 1
        end
    end

    if right_melee_action == -1 and self.meleeRight.enabled then
        local melee_input = 0.0
        if not (right_pure_z or (right_metrics.is_vertical and math.abs(right_metrics.dy) <= 1.5)) then
            melee_input = -right_metrics.distance2
        end
        self.meleeRight:update(current_time, melee_input, right_validation)
        if self.meleeRight.inGesture then
            right_melee_action = 0
        end
    end

    local relative_metrics = numerics.compute_relative_velocity(vr_state.leftTouchPose, vr_state.rightTouchPose, left_metrics, right_metrics, self._cache.relativeMetrics)
    if relative_metrics.distance > 0.001 then
        self.pullPin:update(current_time, relative_metrics.velocity > 0.0 and -relative_metrics.velocity or 0.0, left_validation)
    end

    if self.axeSharpen.enabled then
        self.axeSharpen:update(current_time, numerics.forward_offset_distance_squared(vr_state.rightTouchPose, vr_state.leftTouchPose, 0.30, false), left_validation)
    end

    if self.injectSyringe.enabled then
        self.injectSyringe:update(current_time, inject_syringe_distance_squared(vr_state.leftTouchPose, vr_state.rightTouchPose), right_validation)
    end

    for _, gesture in ipairs(self._locationBasedGesturesLeft) do
        if gesture.enabled then
            gesture:update(current_time, numerics.location_distance_squared(vr_state.headPose, gesture.offset, vr_state.leftTouchPose), left_validation)
        end
    end

    for _, gesture in ipairs(self._locationBasedGesturesRight) do
        if gesture.enabled then
            gesture:update(current_time, numerics.location_distance_squared(vr_state.headPose, gesture.offset, vr_state.rightTouchPose), right_validation)
        end
    end

    if self.triggerLeft.enabled then
        self.triggerLeft:update(current_time, -(vr_state.leftTrigger or 0.0), left_validation)
    end
    if self.triggerRight.enabled then
        self.triggerRight:update(current_time, -(vr_state.rightTrigger or 0.0), right_validation)
    end
    if self.gripLeft.enabled then
        self.gripLeft:update(current_time, -(vr_state.leftGrip or 0.0), left_validation)
    end
    if self.gripRight.enabled then
        self.gripRight:update(current_time, -(vr_state.rightGrip or 0.0), right_validation)
    end

    numerics.copy_vector(self._previousLeftPosition, vr_state.leftTouchPose.position)
    numerics.copy_vector(self._previousRightPosition, vr_state.rightTouchPose.position)
    if vr_state.leftController ~= nil then
        numerics.copy_vector(vr_state.leftController, vr_state.leftTouchPose.position)
    end
    if vr_state.rightController ~= nil then
        numerics.copy_vector(vr_state.rightController, vr_state.rightTouchPose.position)
    end
end

local GestureSets = {}
GestureSets.__index = GestureSets

function GestureSets.new(weapon_inventory, context)
    return setmetatable({
        defaultGestureSet = GestureTracker.new(weapon_inventory, context),
        gestureSets = {},
        mode = actions.Mode.new(),
        _activeMode = nil,
        _context = context or runtime_context,
    }, GestureSets)
end

function GestureSets:createGestureSet(mode, weapon_inventory)
    local tracker = GestureTracker.new(weapon_inventory, self._context)
    self.gestureSets[mode] = tracker
    return tracker
end

function GestureSets:getCurrentGestureSet()
    return self.gestureSets[self._activeMode] or self.defaultGestureSet
end

function GestureSets:update(current_time, delta_time, vr_state)
    if self.mode.current ~= self._activeMode then
        local current = self:getCurrentGestureSet()
        current:reset()
        if current.leave ~= nil then
            current.leave:enter(current_time, false)
            current.leave:leave()
        end
        self._activeMode = self.mode.current
        current = self:getCurrentGestureSet()
        if current.enter ~= nil then
            current.enter:enter(current_time, false)
            current.enter:leave()
        end
    end
    self:getCurrentGestureSet():update(current_time, delta_time, vr_state)
end

function gestures.setContext(context)
    runtime_context = context or runtime_context
end

gestures.computeLocationCenter = compute_location_center
gestures.GestureValidation = GestureValidation
gestures.Gesture = Gesture
gestures.LocationBasedGesture = LocationBasedGesture
gestures.GestureTracker = GestureTracker
gestures.GestureSets = GestureSets
gestures.GestureValidation_None = 0
gestures.GestureValidation_Delay = 1
gestures.GestureValidation_Trigger = 2
gestures.GestureValidation_Grip = 3

package.loaded[module_name] = gestures

return gestures