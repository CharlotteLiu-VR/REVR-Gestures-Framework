local module_name = "RE_05_haptics"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_05_haptics.lua
-- Controller touch-haptics runtime. Vest/bHaptics placeholders stay optional here.
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
    local left_hand = source.leftHand and true or false

    _G.lastGestureHaptic = gesture_name
    _G.lastHapticPatternName = pattern_name
    _G.lastHapticPhase = phase_name
    _G.lastHapticLeftHand = left_hand
    _G.lastHapticSource = {
        gestureName = gesture_name,
        patternName = pattern_name,
        phase = phase_name,
        leftHand = left_hand,
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
    if pattern == nil or pattern.samples == nil then
        return false
    end

    local queue = pattern.left and self._left or self._right
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

local HapticPlayer = {}
HapticPlayer.__index = HapticPlayer

function HapticPlayer.new(touch_player)
    return setmetatable({
        touch_player = touch_player,
        registry = {},
    }, HapticPlayer)
end

function HapticPlayer:register(name, pattern)
    if name == nil then
        return false
    end
    if type(pattern) == "table" and pattern.name == nil then
        pattern.name = name
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

    if resolved == nil or self.touch_player == nil then
        return false
    end

    if resolved.samples ~= nil then
        return self.touch_player:play(resolved, gesture_name, phase_name)
    end

    return false
end

function HapticPlayer:update(delta_time)
    if self.touch_player ~= nil then
        self.touch_player:update(delta_time)
    end
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

    defaults.Haptics_Melee = HapticsGroup.new(nil, nil, nil, defaults.Touch_Melee_Right)
    defaults.Haptics_Pistol = HapticsGroup.new(nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 0.5), "Haptics_Pistol.touchEnter"))
    defaults.Haptics_AutoPistol = HapticsGroup.new(nil, nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 0.5), "Haptics_AutoPistol.touchHold"))
    defaults.Haptics_Rifle = HapticsGroup.new(nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 1.0), "Haptics_Rifle.touchEnter"))
    defaults.Haptics_AutoRifle = HapticsGroup.new(nil, nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(0.2, 1.0), "Haptics_AutoRifle.touchHold"))
    defaults.Haptics_Shotgun = HapticsGroup.new(nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulseWithPause(0.4, 1.0, 0.7), "Haptics_Shotgun.touchEnter"))
    defaults.Haptics_AutoShotgun = HapticsGroup.new(nil, nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulseWithPause(0.4, 1.0, 0.7), "Haptics_AutoShotgun.touchHold"))
    defaults.Haptics_Laser = HapticsGroup.new(nil, nil, nil, nil, TouchHaptics.new(defaults.Touch_Right, touch_haptics_player:pulse(1.2, 0.5), "Haptics_Laser.touchHold"))

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
    set_touch_feedback(gesture_tracker.swipeLeftHandLeft, nil, defaults.Touch_Ancient_Impact_L)
    set_touch_feedback(gesture_tracker.swipeRightHandLeft, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.swipeRightHandRight, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.swipeLeftHandDown, nil, defaults.Touch_Ancient_Impact_L)
    set_touch_feedback(gesture_tracker.swipeRightHandDown, nil, defaults.Touch_Ancient_Impact_R)
    set_touch_feedback(gesture_tracker.pullPin, nil, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.holsterBackLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.holsterBackRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.chestLeft, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)
    set_touch_feedback(gesture_tracker.chestRight, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.injectSyringe, defaults.Touch_Validating_Right, defaults.Touch_Enter_Right)
    set_touch_feedback(gesture_tracker.axeSharpen, defaults.Touch_Validating_Left, defaults.Touch_Enter_Left)

    return true
end

haptics.HapticsGroup = HapticsGroup
haptics.TouchHapticsSample = TouchHapticsSample
haptics.TouchHaptics = TouchHaptics
haptics.TouchHapticsPlayer = TouchHapticsPlayer
-- Exporting the player class is just module wiring, not vest playback by itself.
haptics.HapticPlayer = HapticPlayer

package.loaded[module_name] = haptics

return haptics