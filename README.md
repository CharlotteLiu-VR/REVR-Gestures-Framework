RE_09 is a saved spot for specific game lua script.
##################################
# How to draft Immersion Enhancer #
##################################

This note explains how to write a game-specific Immersion Enhancer script for the current REFramework Lua port.
It is based on these runtime files:
 - RE_04_input.lua
 - RE_05_haptics.lua
 - RE_06_actions.lua
 - RE_07_gestures.lua
 - RE_08_environment.lua

This document is intentionally written as a drafting guide, not as engine internals documentation.
Copy the parts you need and keep your own profile organized into reusable layers.


########################
# Current feature scope #
########################

Supported in the current Lua port:
 - Keyboard output
 - Mouse output
 - Gesture sets
 - Mode-based action routing
 - Touch controller haptics
 - VR to Mouse mapping

Currently not supported in this Lua profile layer:
 - Voice commands
 - bHaptics / vest playback
 - Built-in VR to Gamepad helper layer
 - Built-in Roomscale helper layer

Notes:
 - Voice command placeholders can still exist in your own draft, but there is no active voice runtime in the current RE_04 to RE_08 stack.
 - HapticsGroup fields for vest playback are still present, but the current runtime only plays controller touch haptics.


###############################
# Recommended file structure   #
###############################

For new game-specific drafts, keep the file in three major layers:

1. Bottom-layer dependencies and runtime skeleton
   - require RE_08_environment
   - initialize environment
   - pull input/actions/gestures aliases
   - create gesture sets
   - create enhancer export and runtime tick hooks

2. Tweakable settings and module toggles
   - config file paths
   - panel toggles
   - gesture-group enable and disable helpers
   - UI switches

3. Game-specific mapping
   - game state readers
   - shared modes and helper objects
   - gesture to keyboard or mouse bindings
   - special trackers such as climbing

Practical rule:
 - Declare shared Mode, Chain, Counter and helper state once near the top of the game-specific section.
 - Do not scatter mode declarations across many small mapping blocks unless the runtime order forces it.


#############
# Bootstrap #
#############

Start every profile with the same bootstrap shape:

    if _G.MY_GAME_ENHANCER ~= nil then
        return _G.MY_GAME_ENHANCER
    end

    local environment = require("RE_08_environment")
    environment:initialize()

    local input = environment.input
    local actions = environment.actions
    local gestures = environment.gestures
    local defaultHaptics = environment.defaultHaptics

    local Key = input.Key
    local MouseButton = input.MouseButton
    local GestureValidation_Delay = gestures.GestureValidation_Delay
    local GestureValidation_Trigger = gestures.GestureValidation_Trigger
    local GestureValidation_Grip = gestures.GestureValidation_Grip

    local gestureSets = environment:createGestureSets(nil)
    local gestureTracker = gestureSets.defaultGestureSet
    local vrToMouse = environment.vrToMouse


################################
# Constructor alias shortcuts   #
################################

The current codebase uses constructor tables with .new().
If you want shorter draft code, alias the constructor functions instead of removing .new() everywhere.

Example:

    local KeyPress = input.KeyPress.new
    local MousePress = input.MousePress.new
    local Mode = actions.Mode.new
    local ModeSwitch = actions.ModeSwitch.new
    local ModeBasedAction = actions.ModeBasedAction.new

    local aimMode = Mode()
    gestureTracker.triggerRight.action = ModeBasedAction(aimMode, {
        [1] = MousePress(MouseButton.Left),
    })

This is only a writing shortcut.
The runtime still depends on the real .new constructor functions exported by the modules.


##################
# Gesture basics #
##################

Each gesture object can be configured with:
 - enabled
 - action
 - triggerAction
 - gripAction
 - coolDown
 - lowerThreshold
 - upperThreshold
 - validationMode
 - validationThreshold
 - validationTime
 - triggerLowerThreshold
 - triggerUpperThreshold
 - gripLowerThreshold
 - gripUpperThreshold
 - validating
 - touchValidating
 - haptics.enter
 - haptics.hold
 - haptics.leave
 - haptics.touchEnter
 - haptics.touchHold
 - haptics.touchLeave

Typical setup pattern:

    gestureTracker.triggerRight.enabled = true
    gestureTracker.triggerRight.action = input.MousePress.new(MouseButton.Left)

Validation modes available from RE_07_gestures.lua:
 - gestures.GestureValidation_None
 - gestures.GestureValidation_Delay
 - gestures.GestureValidation_Trigger
 - gestures.GestureValidation_Grip

Example:

    gestureTracker.lightLeft.enabled = true
    gestureTracker.lightLeft.validationMode = GestureValidation_Delay
    gestureTracker.lightLeft.action = actions.ResetAction.new(function()
        environment:reset()
    end)


########################
# List of all gestures #
########################

The default GestureTracker currently exposes these built-in gestures.

Distance, button, stick and posture gestures:
 - gestureTracker.aimPistol                 : squared distance between both controllers
 - gestureTracker.aimRifleLeft             : negative squared xz distance between left controller and head, disabled while aimPistol or aimRifleRight is active
 - gestureTracker.aimRifleRight            : negative squared xz distance between right controller and head, disabled while aimPistol is active
 - gestureTracker.buttonA                  : negative press value of A on the right controller
 - gestureTracker.buttonB                  : negative press value of B on the right controller
 - gestureTracker.buttonX                  : negative press value of X on the left controller
 - gestureTracker.buttonY                  : negative press value of Y on the left controller
 - gestureTracker.buttonLeftStick          : negative press value of the left stick click
 - gestureTracker.buttonLeftStickUp        : negative left stick Y
 - gestureTracker.buttonLeftStickDown      : positive left stick Y
 - gestureTracker.buttonLeftStickLeft      : positive left stick X
 - gestureTracker.buttonLeftStickRight     : negative left stick X
 - gestureTracker.buttonLeftStickInnerRing : left stick magnitude in the inner ring
 - gestureTracker.buttonLeftStickOuterRing : negative left stick magnitude in the outer ring
 - gestureTracker.buttonRightStick         : negative press value of the right stick click
 - gestureTracker.buttonRightStickUp       : negative right stick Y
 - gestureTracker.buttonRightStickDown     : positive right stick Y
 - gestureTracker.buttonRightStickLeft     : positive right stick X
 - gestureTracker.buttonRightStickRight    : negative right stick X
 - gestureTracker.buttonRightStickInnerRing: right stick magnitude in the inner ring
 - gestureTracker.buttonRightStickOuterRing: negative right stick magnitude in the outer ring
 - gestureTracker.duck                     : head height delta from standingHeight
 - gestureTracker.gripLeft                 : negative left grip press
 - gestureTracker.gripRight                : negative right grip press
 - gestureTracker.leanLeft                 : current head roll minus rollCenter
 - gestureTracker.leanRight                : rollCenter minus current head roll
 - gestureTracker.lowerAreaLeft            : left controller Y minus head Y
 - gestureTracker.lowerAreaRight           : right controller Y minus head Y
 - gestureTracker.upperAreaLeft            : head Y minus left controller Y
 - gestureTracker.upperAreaRight           : head Y minus right controller Y
 - gestureTracker.triggerLeft              : negative left trigger press
 - gestureTracker.triggerRight             : negative right trigger press
 - gestureTracker.useLeftUp                : leftTouchPose.left.y
 - gestureTracker.useRightUp               : negative rightTouchPose.left.y
 - gestureTracker.useLeftDown              : negative leftTouchPose.left.y
 - gestureTracker.useRightDown             : rightTouchPose.left.y

Location-based gestures built into the default tracker:
 - gestureTracker.holsterInventoryLeft     : left hand to left hip inventory slot
 - gestureTracker.holsterInventoryRight    : left hand to right hip inventory slot
 - gestureTracker.holsterWeaponLeft        : right hand to left hip weapon slot
 - gestureTracker.holsterWeaponRight       : right hand to right hip weapon slot
 - gestureTracker.lightLeft                : left hand near the head
 - gestureTracker.lightRight               : right hand near the head
 - gestureTracker.chestLeft                : left hand near chest offset
 - gestureTracker.chestRight               : right hand near chest offset
 - gestureTracker.shoulderInventoryLeft    : left hand to left shoulder inventory slot
 - gestureTracker.shoulderInventoryRight   : left hand to right shoulder inventory slot
 - gestureTracker.shoulderWeaponLeft       : right hand to left shoulder weapon slot
 - gestureTracker.shoulderWeaponRight      : right hand to right shoulder weapon slot
 - gestureTracker.foreheadLeft             : left hand near forehead offset
 - gestureTracker.foreheadRight            : right hand near forehead offset
 - gestureTracker.holsterBackLeft          : left hand near back holster offset
 - gestureTracker.holsterBackRight         : right hand near back holster offset

Motion and combat gestures:
 - gestureTracker.meleeLeft                : left hand general melee motion
 - gestureTracker.meleeLeftAlt             : left hand upward-facing alt melee motion
 - gestureTracker.meleeLeftAltPull         : left hand upward-facing pull motion
 - gestureTracker.meleeLeftAltPush         : left hand upward-facing push motion
 - gestureTracker.meleeRight               : right hand general melee motion
 - gestureTracker.meleeRightAlt            : right hand upward-facing alt melee motion
 - gestureTracker.meleeRightAltPull        : right hand upward-facing pull motion
 - gestureTracker.meleeRightAltPush        : right hand upward-facing push motion
 - gestureTracker.swipeLeftHandLeft        : left-hand horizontal swipe to the left
 - gestureTracker.swipeLeftHandRight       : left-hand horizontal swipe to the right
 - gestureTracker.swipeLeftHandUp          : left-hand horizontal swipe upward
 - gestureTracker.swipeLeftHandDown        : left-hand horizontal swipe downward
 - gestureTracker.swipeRightHandLeft       : right-hand horizontal swipe to the left
 - gestureTracker.swipeRightHandRight      : right-hand horizontal swipe to the right
 - gestureTracker.swipeRightHandUp         : right-hand horizontal swipe upward
 - gestureTracker.swipeRightHandDown       : right-hand horizontal swipe downward
 - gestureTracker.circleSkyLeft            : left-hand circular motion while pointing downward
 - gestureTracker.circleSkyRight           : right-hand circular motion while pointing downward
 - gestureTracker.circleFloorLeft          : left-hand circular motion while pointing upward
 - gestureTracker.circleFloorRight         : right-hand circular motion while pointing upward
 - gestureTracker.shakeLeft                : short repeated left-hand shake
 - gestureTracker.shakeRight               : short repeated right-hand shake
 - gestureTracker.thrustLeft               : left-hand forward thrust on the Z axis
 - gestureTracker.retractLeft              : left-hand backward retract on the Z axis
 - gestureTracker.thrustRight              : right-hand forward thrust on the Z axis
 - gestureTracker.retractRight             : right-hand backward retract on the Z axis
 - gestureTracker.pullPin                  : relative pull velocity between both controllers
 - gestureTracker.axeSharpen               : forward-offset distance between right and left hand
 - gestureTracker.injectSyringe            : custom left-to-right injection distance test

Convenience aliases also set by the default tracker:
 - gestureTracker.fireWeaponLeft   points to gestureTracker.triggerLeft
 - gestureTracker.fireWeaponRight  points to gestureTracker.triggerRight
 - gestureTracker.grabLeft         points to gestureTracker.gripLeft
 - gestureTracker.grabRight        points to gestureTracker.gripRight


###########################
# Location-based gestures #
###########################

You can add more location-based gestures on top of the built-in ones.

Example:

    local numerics = environment.numerics
    local breast = gestureTracker:addLocationBasedGesture(
        true,
        0.05,
        0.10,
        numerics.new_vector(0.0, -0.4, -0.2)
    )
    breast.enabled = true
    breast.touchValidating = defaultHaptics.Touch_Validating_Left
    breast.haptics.touchEnter = defaultHaptics.Touch_Enter_Left
    breast.gripAction = input.KeyPress.new(Key.B)

Parameters:
 - first parameter  : true for left hand, false for right hand
 - second parameter : lower threshold
 - third parameter  : upper threshold
 - fourth parameter : offset from the head pose

Offset coordinate rule:
 - X negative = left, X positive = right
 - Y positive = up, Y negative = down
 - Z negative = forward, Z positive = backward

Examples:
 - numerics.new_vector(0.0, 0.0, -0.2)   : in front of the face
 - numerics.new_vector(0.0, 0.2, 0.0)    : above the head
 - numerics.new_vector(-0.2, 0.0, 0.0)   : left side of the head


###############
# Gesture sets #
###############

Use separate gesture sets when a gameplay mode needs a different input profile.
RE9 climbing is the best template for this pattern.

Create a new set:

    local climbingTracker = gestureSets:createGestureSet("climbing", nil)
    environment.haptics.applyCompanionGestureDefaults(climbingTracker, defaultHaptics)

Switch into it:

    gestureTracker.upperAreaLeft.gripAction = actions.ModeSwitch.new(gestureSets.mode, "climbing")

Switch back out:

    climbingTracker.gripLeft.action = actions.ActionSplit.new({
        actions.Action.new(),
        actions.ModeSwitch.new(gestureSets.mode, 0),
    })

Gesture-set lifecycle hooks:

    climbingTracker.enter = actions.MultiAction.new({
        actions.ModeSwitch.new(vrToMouse.mode, 0),
    })

    climbingTracker.leave = actions.ModeSwitch.new(vrToMouse.mode, 0)

Important:
 - Each gesture set is a separate tracker.
 - Custom location-based gestures must be added to each set where you want to use them.
 - Voice state does not matter here because the current Lua profile layer does not support voice commands.


##################
# Input actions  #
##################

Keyboard actions from RE_04_input.lua:

1. KeyQuickPress

    gestureTracker.buttonA.action = input.KeyQuickPress.new(Key.F)
    gestureTracker.buttonB.action = input.KeyQuickPress.new({ Key.LeftShift, Key.R })

Presses once when the gesture enters.

2. KeyPress

    gestureTracker.triggerRight.action = input.KeyPress.new(Key.F)

Holds the key while the gesture stays active.

3. KeyToggle

    gestureTracker.duck.action = input.KeyToggle.new(Key.LeftControl, {
        tapOnLeave = true,
        pulseDuration = 0.08,
    })

Pulses once on enter. If tapOnLeave is true, pulses again on leave.

4. KeySwitchState

    gestureTracker.buttonX.action = input.KeySwitchState.new(Key.R)

Turns the key state on, then off, on repeated entries.

5. KeySetState

    gestureTracker.buttonY.action = input.KeySetState.new(Key.LeftShift, true)
    gestureTracker.buttonB.action = input.KeySetState.new(Key.LeftShift, false)

Forces the target keys into a specific pressed or released state.

Mouse actions from RE_04_input.lua:

6. MouseQuickPress

    gestureTracker.buttonRightStick.action = input.MouseQuickPress.new(MouseButton.Left)

7. MousePress

    gestureTracker.aimPistol.action = input.MousePress.new(MouseButton.Right)

8. MouseToggle

    gestureTracker.lightRight.action = input.MouseToggle.new(MouseButton.Middle)

9. MouseSwitchState

    gestureTracker.buttonLeftStick.action = input.MouseSwitchState.new(MouseButton.Right)

10. MouseSetState

    gestureTracker.buttonLeftStickUp.action = input.MouseSetState.new(MouseButton.Left, true)
    gestureTracker.buttonLeftStickDown.action = input.MouseSetState.new(MouseButton.Left, false)

Mouse buttons available through input.MouseButton include at least:
 - MouseButton.Left
 - MouseButton.Right
 - MouseButton.Middle
 - MouseButton.X1
 - MouseButton.X2
 - MouseButton.WheelUp
 - MouseButton.WheelDown


###########################
# Composed action helpers #
###########################

The following helpers come from RE_06_actions.lua.

1. Empty action

    gestureTracker.foreheadLeft.action = actions.Action.new()

Useful when you only want haptics or state tracking.

2. CallbackAction

    gestureTracker.foreheadRight.action = actions.CallbackAction.new(function(current_time, from_voice_recognition)
        _G.last_forehead_event = current_time
    end)

Or with explicit hooks:

    gestureTracker.foreheadRight.action = actions.CallbackAction.new({
        enter = function(current_time)
            _G.last_forehead_event = current_time
        end,
        leave = function()
            _G.last_forehead_leave = os.clock()
        end,
    })

3. ResetAction

    gestureTracker.lightLeft.action = actions.ResetAction.new(function()
        environment:reset()
    end)

4. GuardedAction

    local function support_hand_free()
        return rawget(_G, "__vr_two_hand_aiming_active") ~= true
    end

    gestureTracker.aimPistol.gripAction = actions.GuardedAction.new(
        input.KeyPress.new(Key.R),
        support_hand_free
    )

Use this when an action must only fire under a condition.

5. MultiAction

    gestureTracker.aimPistol.action = actions.MultiAction.new({
        input.MousePress.new(MouseButton.Right),
        actions.ModeSwitchWithReset.new(aimMode, 1, 0),
    })

Runs multiple actions in parallel.

6. ActionSplit

    gestureTracker.upperAreaRight.gripAction = actions.ActionSplit.new({
        actions.ModeSwitch.new(rightHandRaised, 1),
        actions.ModeSwitch.new(rightHandRaised, 0),
    })

Runs one action on enter and another on leave.

7. Counter and CombinedAction

    local climbCounter = actions.Counter.new(2)

    gestureTracker.upperAreaLeft.gripAction = actions.CombinedAction.new(climbCounter)
    gestureTracker.upperAreaRight.gripAction = actions.CombinedAction.new(
        climbCounter,
        input.KeyPress.new(Key.F)
    )

Only when the counter reaches the target count does the optional action fire.

8. Chain, ChainStart and ChainEnd

    local throwChain = actions.Chain.new(1.0)
    gestureTracker.meleeLeftAltPull.gripAction = actions.ChainStart.new(throwChain)
    gestureTracker.meleeLeftAltPush.gripAction = actions.ChainEnd.new(
        throwChain,
        input.KeyPress.new(Key.F)
    )

Use this for two-step gesture sequences inside a time window.

9. PersistentAction

    gestureTracker.pullPin.triggerAction = actions.PersistentAction.new(
        input.KeyPress.new(Key.U),
        2.0
    )

Starts once and keeps updating the wrapped action until the duration expires.

10. TimedAction and ActionSequence

    gestureTracker.meleeRight.gripAction = actions.ActionSequence.new({
        actions.TimedAction.new(input.MousePress.new(MouseButton.Left), 0.10),
        actions.TimedAction.new(actions.Action.new(), 0.05),
        actions.TimedAction.new(input.KeyPress.new(Key.F), 0.10),
    })

Use TimedAction as one step entry inside ActionSequence.

11. ActionRepeat

    gestureTracker.buttonLeftStick.action = actions.ActionRepeat.new(
        input.KeyQuickPress.new(Key.F),
        3,
        0.05,
        0.20
    )

Repeats the wrapped action while the gesture remains active.

12. TimeBased

    gestureTracker.triggerLeft.action = actions.TimeBased.new({
        input.KeyQuickPress.new(Key.F),
        input.KeyPress.new(Key.R),
    }, 0.25)

Short hold fires the first action. Long hold activates the second action.


#########
# Modes #
#########

Modes are the main way to route one gesture into different actions.

1. Create a mode

    local aimMode = actions.Mode.new()
    local climbMode = actions.Mode.new("free")

2. Switch a mode on enter and reset it on leave

    gestureTracker.triggerLeft.action = actions.ModeSwitchWithReset.new(aimMode, 2, 0)

3. Switch one or more modes on leave

    gestureTracker.buttonA.action = actions.ModeSwitch.new(aimMode, 1)
    gestureTracker.buttonB.action = actions.ModeSwitch.new({ aimMode, climbMode }, 0)

4. Copy one mode into another

    climbingTracker.enter = actions.ModeCopy.new(lastMouseMode, vrToMouse.mode)

5. Select actions from the current mode

    gestureTracker.triggerRight.action = actions.ModeBasedAction.new(aimMode, {
        [1] = input.MousePress.new(MouseButton.Left),
        [2] = input.KeyPress.new(Key.Escape),
        free = input.KeyPress.new(Key.F),
    }, actions.Action.new())

Notes:
 - Mode keys can be numbers or strings.
 - ModeBasedAction reads the current mode key and selects the matching action.
 - ModeSwitch changes the target mode on leave.
 - ModeSwitchWithReset changes the mode on enter and restores on leave.


#################
# Touch haptics #
#################

The current Lua runtime supports controller touch haptics.
Use the default patterns created by RE_05_haptics.lua, or create your own.

Default touch patterns:
 - defaultHaptics.Touch_Validating_Left
 - defaultHaptics.Touch_Validating_Right
 - defaultHaptics.Touch_Enter_Left
 - defaultHaptics.Touch_Enter_Right
 - defaultHaptics.Touch_Melee_Left
 - defaultHaptics.Touch_Melee_Right
 - defaultHaptics.Touch_DoublePulse_Left
 - defaultHaptics.Touch_DoublePulse_Right
 - defaultHaptics.Touch_Ancient_Cast_L
 - defaultHaptics.Touch_Ancient_Cast_R
 - defaultHaptics.Touch_Ancient_Impact_L
 - defaultHaptics.Touch_Ancient_Impact_R

Default haptics groups:
 - defaultHaptics.Haptics_Melee
 - defaultHaptics.Haptics_Pistol
 - defaultHaptics.Haptics_AutoPistol
 - defaultHaptics.Haptics_Rifle
 - defaultHaptics.Haptics_AutoRifle
 - defaultHaptics.Haptics_Shotgun
 - defaultHaptics.Haptics_AutoShotgun
 - defaultHaptics.Haptics_Laser

Examples:

    gestureTracker.holsterWeaponRight.touchValidating = defaultHaptics.Touch_Validating_Right
    gestureTracker.holsterWeaponRight.haptics.touchEnter = defaultHaptics.Touch_Enter_Right

    gestureTracker.meleeRight.haptics = defaultHaptics.Haptics_Melee
    gestureTracker.triggerRight.haptics = defaultHaptics.Haptics_Pistol

Custom touch haptics:

    local pulse = environment.touchHapticsPlayer:pulse(0.12, 0.80)
    local customTouch = environment.haptics.TouchHaptics.new(true, pulse, "CustomTouch")
    gestureTracker.chestLeft.haptics.touchEnter = customTouch


############
# bHaptics #
############

bHaptics / vest playback is not active in the current Lua profile runtime.
Keep all bHaptics notes in your draft as documentation only for now.


################
# VR to Mouse  #
################

The Lua port exports vrToMouse through environment.vrToMouse.
Current mode values are:
 - 0 : disabled
 - 1 : headset drives mouse
 - 2 : left controller drives mouse
 - 3 : right controller drives mouse

Key fields:
 - vrToMouse.mode.current
 - vrToMouse.stickMode.current
 - vrToMouse.mouseSensitivityX
 - vrToMouse.mouseSensitivityY
 - vrToMouse.stickMultiplierX
 - vrToMouse.stickMultiplierY
 - vrToMouse.enableYawPitch.current
 - vrToMouse.enableRoll.current
 - vrToMouse.useControllerOrientation
 - vrToMouse.useRightController

Examples:

    vrToMouse.mode.current = 1
    vrToMouse.stickMode.current = 1
    vrToMouse.mouseSensitivityX = 800.0
    vrToMouse.mouseSensitivityY = 800.0
    vrToMouse.stickMultiplierX = 1.0
    vrToMouse.stickMultiplierY = 1.0
    vrToMouse.enableYawPitch.current = true
    vrToMouse.enableRoll.current = false
    vrToMouse.useRightController = true

Gesture-driven switching example:

    gestureTracker.buttonRightStick.action = actions.ModeSwitch.new(vrToMouse.mode, 1)


############################
# Minimal profile example  #
############################

This example shows the usual writing pattern for a new Immersion Enhancer draft.

    local environment = require("RE_08_environment")
    environment:initialize()

    local input = environment.input
    local actions = environment.actions
    local gestures = environment.gestures
    local Key = input.Key
    local MouseButton = input.MouseButton

    local gestureSets = environment:createGestureSets(nil)
    local gestureTracker = gestureSets.defaultGestureSet

    local aimMode = actions.Mode.new()
    local interactMode = actions.Mode.new()

    gestureTracker.aimPistol.enabled = true
    gestureTracker.aimPistol.action = actions.MultiAction.new({
        input.MousePress.new(MouseButton.Right),
        actions.ModeSwitchWithReset.new(aimMode, 1, 0),
    })

    gestureTracker.triggerRight.enabled = true
    gestureTracker.triggerRight.action = actions.ModeBasedAction.new(aimMode, {
        [1] = input.MousePress.new(MouseButton.Left),
        [0] = actions.Action.new(),
    })

    gestureTracker.useRightDown.enabled = true
    gestureTracker.useRightDown.gripAction = input.KeyPress.new(Key.F)

    gestureTracker.lightLeft.enabled = true
    gestureTracker.lightLeft.validationMode = gestures.GestureValidation_Delay
    gestureTracker.lightLeft.action = actions.ResetAction.new(function()
        environment:reset()
    end)


###################
# Drafting advice #
###################

When drafting a game-specific script, work in this order:
 1. Bind the always-safe gestures first: aim, fire, interact, reload, map, menu.
 2. Add shared modes next and keep them in one block.
 3. Add special helpers such as GuardedAction or Chain only after the basic loop works.
 4. Put custom state readers in one helper section instead of duplicating SDK reads in every action.
 5. If a module can be turned on or off, collect those gestures into one table and toggle them together.
 6. If a special movement mode exists, give it its own gesture set.

Good template habit:
 - shared state first
 - mapping second
 - toggles third
 - hooks and export last
