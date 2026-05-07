local module_name = "RE_06_actions"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_06_actions.lua
-- Higher-level action composition: chains, timers, mode switches, and reset callbacks.
local input = require("RE_04_input")

local actions = {}

local active_actions = {}

local function derive(base)
    local derived = {}
    derived.__index = derived
    setmetatable(derived, { __index = base })
    return derived
end

local function remove_active_action(target)
    for index = #active_actions, 1, -1 do
        if active_actions[index] == target then
            table.remove(active_actions, index)
            return true
        end
    end
    return false
end

local Action = {}
Action.__index = Action

function Action.new()
    return setmetatable({ haptics = nil }, Action)
end

function Action:getCurrentHaptics()
    return self.haptics
end

function Action:enter(_, _)
end

function Action:update(_)
end

function Action:leave()
end

function Action:reset()
end

local CallbackAction = derive(Action)

function CallbackAction.new(callbacks)
    local instance = Action.new()
    if type(callbacks) == "function" then
        callbacks = { enter = callbacks }
    end
    instance._callbacks = callbacks or {}
    return setmetatable(instance, CallbackAction)
end

function CallbackAction:enter(current_time, from_voice_recognition)
    local callback = self._callbacks.enter
    if callback ~= nil then
        callback(current_time, from_voice_recognition, self)
    end
end

function CallbackAction:update(current_time)
    local callback = self._callbacks.update
    if callback ~= nil then
        callback(current_time, self)
    end
end

function CallbackAction:leave()
    local callback = self._callbacks.leave
    if callback ~= nil then
        callback(self)
    end
end

function CallbackAction:reset()
    local callback = self._callbacks.reset
    if callback ~= nil then
        callback(self)
    end
end

local GuardedAction = derive(Action)

function GuardedAction.new(action, predicate)
    local instance = Action.new()
    instance._action = action
    instance._predicate = predicate
    instance._active = false
    return setmetatable(instance, GuardedAction)
end

function GuardedAction:getCurrentHaptics()
    if self.haptics ~= nil then
        return self.haptics
    end
    if self._action ~= nil and type(self._action.getCurrentHaptics) == "function" then
        return self._action:getCurrentHaptics()
    end
    return nil
end

function GuardedAction:enter(current_time, from_voice_recognition)
    if self._predicate ~= nil and self._predicate(current_time, from_voice_recognition, self) == false then
        self._active = false
        return false
    end

    self._active = true
    if self._action ~= nil and type(self._action.enter) == "function" then
        return self._action:enter(current_time, from_voice_recognition)
    end
    return true
end

function GuardedAction:update(current_time)
    if self._active and self._action ~= nil and type(self._action.update) == "function" then
        return self._action:update(current_time)
    end
    return nil
end

function GuardedAction:leave()
    if self._active and self._action ~= nil and type(self._action.leave) == "function" then
        self._action:leave()
    end
    self._active = false
end

function GuardedAction:reset()
    if self._action ~= nil and type(self._action.reset) == "function" then
        self._action:reset()
    elseif self._active and self._action ~= nil and type(self._action.leave) == "function" then
        self._action:leave()
    end
    self._active = false
end

local ResetAction = derive(CallbackAction)

function ResetAction.new(reset_callback)
    local instance = CallbackAction.new(function(current_time, from_voice_recognition)
        if reset_callback ~= nil then
            reset_callback(current_time, from_voice_recognition)
        end
    end)
    return setmetatable(instance, ResetAction)
end

local MultiAction = derive(Action)

function MultiAction.new(action_list)
    local instance = Action.new()
    instance._actions = action_list or {}
    return setmetatable(instance, MultiAction)
end

function MultiAction:getCurrentHaptics()
    for _, action in ipairs(self._actions) do
        if action.getCurrentHaptics then
            local current = action:getCurrentHaptics()
            if current ~= nil then
                return current
            end
        end
    end
    return self.haptics
end

function MultiAction:enter(current_time, from_voice_recognition)
    for _, action in ipairs(self._actions) do
        if action.enter then
            action:enter(current_time, from_voice_recognition)
        end
    end
end

function MultiAction:update(current_time)
    for _, action in ipairs(self._actions) do
        if action.update then
            action:update(current_time)
        end
    end
end

function MultiAction:leave()
    for _, action in ipairs(self._actions) do
        if action.leave then
            action:leave()
        end
    end
end

function MultiAction:reset()
    for _, action in ipairs(self._actions) do
        if action.reset then
            action:reset()
        end
    end
end

local ActionSplit = derive(Action)

function ActionSplit.new(action_pair)
    local instance = Action.new()
    instance._actions = action_pair or {}
    instance._inAction = false
    instance._lastTime = 0.0
    return setmetatable(instance, ActionSplit)
end

function ActionSplit:getCurrentHaptics()
    local target = self._inAction and self._actions[2] or self._actions[1]
    if target and target.getCurrentHaptics then
        local current = target:getCurrentHaptics()
        if current ~= nil then
            return current
        end
    end
    return self.haptics
end

function ActionSplit:enter(current_time, from_voice_recognition)
    local enter_action = self._actions[1]
    if enter_action then
        enter_action:enter(current_time, from_voice_recognition)
        enter_action:leave()
    end
    self._inAction = true
    self._lastTime = current_time or 0.0
end

function ActionSplit:update(current_time)
    self._lastTime = current_time or self._lastTime
end

function ActionSplit:leave()
    local leave_action = self._actions[2]
    if leave_action then
        leave_action:enter(self._lastTime, false)
        leave_action:leave()
    end
    self._inAction = false
end

function ActionSplit:reset()
    for _, action in ipairs(self._actions) do
        if action.reset then
            action:reset()
        end
    end
    self._inAction = false
end

local Counter = {}
Counter.__index = Counter

function Counter.new(count)
    return setmetatable({ _target = count or 0, _current = 0 }, Counter)
end

function Counter:increase()
    self._current = self._current + 1
    if self._current > self._target then
        error("Too many activations of counter.")
    end
end

function Counter:decrease()
    self._current = self._current - 1
    if self._current < 0 then
        error("Too many deactivations of counter.")
    end
end

function Counter:active()
    return self._current == self._target
end

local CombinedAction = derive(Action)

function CombinedAction.new(counter, action)
    local instance = Action.new()
    instance._counter = counter
    instance._action = action
    instance._entered = false
    instance._counterActive = false
    return setmetatable(instance, CombinedAction)
end

function CombinedAction:enter(current_time, from_voice_recognition)
    if from_voice_recognition then
        error("CombinedAction does not support voice commands.")
    end

    self._entered = true
    self._counter:increase()
    self._counterActive = self._counter:active()
    if self._action ~= nil and self._counterActive then
        self._action:enter(current_time, false)
    end
end

function CombinedAction:update(current_time)
    if self._action == nil then
        return
    end

    local active = self._counter:active()
    if self._counterActive ~= active then
        if self._counterActive then
            self._action:leave()
        else
            self._action:enter(current_time, false)
        end
        self._counterActive = active
    elseif self._counterActive then
        self._action:update(current_time)
    end
end

function CombinedAction:leave()
    if self._action ~= nil and self._counterActive then
        self._action:leave()
    end
    self._counter:decrease()
    self._entered = false
    self._counterActive = false
end

function CombinedAction:reset()
    if self._entered then
        self:leave()
    end
    if self._action ~= nil then
        self._action:reset()
    end
end

local Chain = {}
Chain.__index = Chain

function Chain.new(window)
    return setmetatable({ _window = window or 0.0, _startTime = -1.0, _waiting = false }, Chain)
end

function Chain:start(current_time)
    self._startTime = current_time or 0.0
    self._waiting = true
end

function Chain:check(current_time)
    if self._waiting and ((current_time or 0.0) - self._startTime) <= self._window then
        self._waiting = false
        return true
    end
    return false
end

function Chain:isExpired(current_time)
    return self._waiting and ((current_time or 0.0) - self._startTime) > self._window
end

function Chain:isWaiting()
    return self._waiting
end

function Chain:reset()
    self._waiting = false
    self._startTime = -1.0
end

local ChainStart = derive(Action)

function ChainStart.new(chain)
    local instance = Action.new()
    instance._chain = chain
    instance._active = false
    return setmetatable(instance, ChainStart)
end

function ChainStart:enter(current_time, _)
    self._chain:start(current_time)
    self._active = true
    active_actions[#active_actions + 1] = self
end

function ChainStart:update(current_time)
    if self._chain:isExpired(current_time) or (not self._chain:isWaiting()) then
        self._chain:reset()
        self._active = false
        remove_active_action(self)
    end
end

function ChainStart:reset()
    self._chain:reset()
    self._active = false
    remove_active_action(self)
end

local ChainEnd = derive(Action)

function ChainEnd.new(chain, action)
    local instance = Action.new()
    instance._chain = chain
    instance._action = action
    instance._entered = false
    return setmetatable(instance, ChainEnd)
end

function ChainEnd:enter(current_time, from_voice_recognition)
    if self._chain:check(current_time) then
        self._entered = true
        if self._action ~= nil then
            self._action:enter(current_time, from_voice_recognition)
        end
    end
end

function ChainEnd:update(current_time)
    if self._entered and self._action ~= nil then
        self._action:update(current_time)
    end
end

function ChainEnd:leave()
    if self._entered then
        if self._action ~= nil then
            self._action:leave()
        end
        self._entered = false
    end
end

function ChainEnd:reset()
    if self._entered then
        self:leave()
    end
    if self._action ~= nil then
        self._action:reset()
    end
end

local PersistentAction = derive(Action)

function PersistentAction.new(action, duration)
    local instance = Action.new()
    instance._action = action
    instance._duration = duration or 0.0
    instance._startTime = 0.0
    instance._isRunning = false
    return setmetatable(instance, PersistentAction)
end

function PersistentAction:enter(current_time, _)
    if not self._isRunning then
        self._startTime = current_time or 0.0
        self._isRunning = true
        if self._action ~= nil then
            self._action:enter(current_time, false)
        end
        active_actions[#active_actions + 1] = self
    end
end

function PersistentAction:update(current_time)
    if self._isRunning then
        if ((current_time or 0.0) - self._startTime) < self._duration then
            if self._action ~= nil then
                self._action:update(current_time)
            end
        else
            self:stop()
        end
    end
end

function PersistentAction:stop()
    if self._isRunning then
        if self._action ~= nil then
            self._action:leave()
        end
        self._isRunning = false
        remove_active_action(self)
    end
end

function PersistentAction:leave()
end

function PersistentAction:reset()
    self:stop()
end

local TimedAction = {}
TimedAction.__index = TimedAction

function TimedAction.new(action, duration)
    return setmetatable({ action = action, duration = duration or 0.0 }, TimedAction)
end

local ActionSequence = derive(Action)

function ActionSequence.new(action_list)
    local instance = Action.new()
    instance._actions = action_list or {}
    instance._index = 1
    instance._time = 0.0
    return setmetatable(instance, ActionSequence)
end

function ActionSequence:getCurrentHaptics()
    local entry = self._actions[self._index]
    if entry ~= nil and entry.action and entry.action.getCurrentHaptics then
        local current = entry.action:getCurrentHaptics()
        if current ~= nil then
            return current
        end
    end
    return self.haptics
end

function ActionSequence:enter(current_time, _)
    self._index = 1
    self._time = current_time or 0.0
    local entry = self._actions[self._index]
    if entry ~= nil and entry.action ~= nil then
        entry.action:enter(current_time, false)
    end
end

function ActionSequence:update(current_time)
    local entry = self._actions[self._index]
    if entry == nil then
        return
    end

    if entry.duration > ((current_time or 0.0) - self._time) then
        entry.action:update(current_time)
    else
        entry.action:leave()
        self._index = self._index + 1
        self._time = current_time or 0.0
        local next_entry = self._actions[self._index]
        if next_entry ~= nil then
            next_entry.action:enter(current_time, false)
        end
    end
end

function ActionSequence:leave()
    local entry = self._actions[self._index]
    if entry ~= nil and entry.action ~= nil then
        entry.action:leave()
    end
    self._index = 1
    self._time = 0.0
end

function ActionSequence:reset()
    for _, entry in ipairs(self._actions) do
        if entry.action and entry.action.reset then
            entry.action:reset()
        end
    end
    self._index = 1
    self._time = 0.0
end

local ActionRepeat = derive(Action)

function ActionRepeat.new(action, times, action_duration, time_interval)
    local instance = Action.new()
    instance._action = action
    instance._times = (times or 1) - 1
    instance._actionDuration = action_duration or 0.05
    instance._timeInterval = time_interval or 0.2
    instance._timesLeft = 0
    instance._active = false
    instance._needUpdate = false
    instance._time = 0.0
    return setmetatable(instance, ActionRepeat)
end

function ActionRepeat:getCurrentHaptics()
    if self._action and self._action.getCurrentHaptics then
        local current = self._action:getCurrentHaptics()
        if current ~= nil then
            return current
        end
    end
    return self.haptics
end

function ActionRepeat:enter(current_time, from_voice_recognition)
    self._action:enter(current_time, false)
    self._active = true
    self._time = current_time or 0.0
    self._needUpdate = true
    if from_voice_recognition and self._times == -1 then
        self._timesLeft = 0
    else
        self._timesLeft = self._times
    end
end

function ActionRepeat:update(current_time)
    if not self._needUpdate then
        return
    end
    local elapsed = (current_time or 0.0) - self._time
    if elapsed < self._actionDuration then
        self._action:update(current_time)
    else
        self._action:leave()
        self._active = false
        if self._timesLeft == 0 then
            self._needUpdate = false
        end
        if elapsed >= self._timeInterval then
            self._action:enter(current_time, false)
            self._active = true
            self._time = current_time or 0.0
            if self._timesLeft > 0 then
                self._timesLeft = self._timesLeft - 1
            end
        end
    end
end

function ActionRepeat:leave()
    if self._active then
        self._action:leave()
        self._active = false
    end
    self._needUpdate = false
end

function ActionRepeat:reset()
    self:leave()
end

local TimeBased = derive(Action)

function TimeBased.new(action_pair, duration)
    local instance = Action.new()
    instance._actions = action_pair or {}
    instance._duration = duration or 0.25
    instance._inLongAction = false
    instance._time = 0.0
    return setmetatable(instance, TimeBased)
end

function TimeBased:getCurrentHaptics()
    local target = self._inLongAction and self._actions[2] or self._actions[1]
    if target and target.getCurrentHaptics then
        local current = target:getCurrentHaptics()
        if current ~= nil then
            return current
        end
    end
    return self.haptics
end

function TimeBased:enter(current_time, from_voice_recognition)
    if from_voice_recognition then
        error("TimeBased does not support voice commands.")
    end
    self._time = current_time or 0.0
    self._inLongAction = false
end

function TimeBased:update(current_time)
    if self._inLongAction then
        self._actions[2]:update(current_time)
    elseif ((current_time or 0.0) - self._time) > self._duration then
        self._inLongAction = true
        self._actions[2]:enter(current_time, false)
    end
end

function TimeBased:leave()
    if self._inLongAction then
        self._actions[2]:leave()
    elseif self._actions[1] ~= nil then
        self._actions[1]:enter(self._time, false)
        self._actions[1]:leave()
    end
    self._inLongAction = false
end

function TimeBased:reset()
    for _, action in ipairs(self._actions) do
        if action.reset then
            action:reset()
        end
    end
    self._inLongAction = false
end

local Mode = {}
Mode.__index = Mode

function Mode.new(initial_value)
    return setmetatable({ current = initial_value or 0 }, Mode)
end

local ModeBasedAction = derive(Action)

local function build_mode_action_map(action_source)
    if type(action_source) ~= "table" then
        return {}
    end

    local mapped = {}
    for key, action in pairs(action_source) do
        mapped[key] = action
    end
    return mapped
end

function ModeBasedAction.new(mode, action_source, default_action)
    local instance = Action.new()
    instance._mode = mode
    instance._actions = build_mode_action_map(action_source)
    instance._defaultAction = default_action
    instance._activeMode = mode and mode.current or 0
    return setmetatable(instance, ModeBasedAction)
end

function ModeBasedAction:getCurrentAction()
    local mode_key = self._activeMode
    local action = self._actions[mode_key]
    if action == nil then
        action = self._actions[self._mode.current]
    end
    return action or self._defaultAction
end

function ModeBasedAction:getCurrentHaptics()
    local action = self:getCurrentAction()
    if action and action.getCurrentHaptics then
        local current = action:getCurrentHaptics()
        if current ~= nil then
            return current
        end
    end
    return self.haptics
end

function ModeBasedAction:enter(current_time, from_voice_recognition)
    self._activeMode = self._mode.current
    local action = self:getCurrentAction()
    if action then
        action:enter(current_time, from_voice_recognition)
    end
end

function ModeBasedAction:update(current_time)
    if self._mode.current == self._activeMode then
        local action = self:getCurrentAction()
        if action then
            action:update(current_time)
        end
    else
        local previous = self._actions[self._activeMode] or self._defaultAction
        if previous then
            previous:leave()
        end
        self._activeMode = self._mode.current
        local next_action = self:getCurrentAction()
        if next_action then
            next_action:enter(current_time, false)
        end
    end
end

function ModeBasedAction:leave()
    local action = self:getCurrentAction()
    if action then
        action:leave()
    end
end

function ModeBasedAction:reset()
    for _, action in pairs(self._actions) do
        if action.reset then
            action:reset()
        end
    end
    if self._defaultAction and self._defaultAction.reset then
        self._defaultAction:reset()
    end
end

local ModeSwitch = derive(Action)

function ModeSwitch.new(modes, selected_mode)
    local instance = Action.new()
    instance._modes = {}
    if modes ~= nil then
        if modes.current ~= nil then
            instance._modes[1] = modes
        else
            for _, mode in ipairs(modes) do
                instance._modes[#instance._modes + 1] = mode
            end
        end
    end
    instance._selectedMode = selected_mode
    return setmetatable(instance, ModeSwitch)
end

function ModeSwitch:enter(_, from_voice_recognition)
    if from_voice_recognition then
        self:leave()
    end
end

function ModeSwitch:leave()
    for _, mode in ipairs(self._modes) do
        mode.current = self._selectedMode
    end
end

local ModeCopy = derive(Action)

function ModeCopy.new(mode, target_mode)
    local instance = Action.new()
    instance._mode = mode
    instance._targetMode = target_mode
    return setmetatable(instance, ModeCopy)
end

function ModeCopy:leave()
    self._mode.current = self._targetMode.current
end

local ModeSwitchWithReset = derive(Action)

function ModeSwitchWithReset.new(mode, selected_mode, reset_mode)
    local instance = Action.new()
    instance._mode = mode
    instance._selectedMode = selected_mode
    instance._resetMode = reset_mode
    instance._lastMode = mode.current
    return setmetatable(instance, ModeSwitchWithReset)
end

function ModeSwitchWithReset:enter(_, _)
    self._lastMode = self._mode.current
    self._mode.current = self._selectedMode
end

function ModeSwitchWithReset:leave()
    if self._resetMode == nil then
        self._mode.current = self._lastMode
    else
        self._mode.current = self._resetMode
    end
end

function actions.updateActiveActions(current_time)
    for index = #active_actions, 1, -1 do
        local action = active_actions[index]
        if action and action.update then
            action:update(current_time)
        end
    end
end

function actions.resetActiveActions()
    for index = #active_actions, 1, -1 do
        local action = active_actions[index]
        if action and action.reset then
            action:reset()
        end
        active_actions[index] = nil
    end
end

actions.activeActions = active_actions
actions.Action = Action
actions.CallbackAction = CallbackAction
actions.GuardedAction = GuardedAction
actions.MultiAction = MultiAction
actions.ActionSplit = ActionSplit
actions.Counter = Counter
actions.CombinedAction = CombinedAction
actions.Chain = Chain
actions.ChainStart = ChainStart
actions.ChainEnd = ChainEnd
actions.PersistentAction = PersistentAction
actions.TimedAction = TimedAction
actions.ActionSequence = ActionSequence
actions.ActionRepeat = ActionRepeat
actions.TimeBased = TimeBased
actions.Mode = Mode
actions.ModeBasedAction = ModeBasedAction
actions.ModeSwitch = ModeSwitch
actions.ModeCopy = ModeCopy
actions.ModeSwitchWithReset = ModeSwitchWithReset
actions.ResetAction = ResetAction
actions.input = input

package.loaded[module_name] = actions

return actions