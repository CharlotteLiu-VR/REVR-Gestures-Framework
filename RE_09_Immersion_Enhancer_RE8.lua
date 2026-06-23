-- 专用配置：把通用 VR 手势系统接到本作的键鼠动作上。
-- 文件按三大类整理：
-- 第一类：底层依赖与运行骨架
-- 第二类：微调设置与模块开关
-- 第三类：RE8 个性化映射

-- 第一类运行骨架已下沉到 RE_08_environment：这里只保留业务热重载入口。
-- VR 运行时状态经 RE_00_vr_globals 读取；publisher 见 RE_00 头注释。
-- =============================================================================
local environment = require("RE_08_environment")
local vr_globals = require("RE_00_vr_globals")

local existing_enhancer = environment:getEnhancer()
local skip_full_init = type(existing_enhancer) == "table"

-- =============================================================================
-- 第二类：微调设置与模块开关
-- 配置文件、默认开关和面板状态归在这一类；保持原位，方便以后迁移时单独替换。
--
-- 【作用】持久化并驱动「武器槽位手势」总开关，不负责具体手势映射（那是第三类）。
--   1. 从 JSON 读出 ImmersionEnhancerHolster（默认 true）
--   2. 得到运行时变量 ImmersionEnhancerHolster_enabled
--   3. apply_holster_toggle() 据此启停 holsterWeaponRight / shoulderWeaponRight /
--      chestRight / shoulderWeaponLeft 四个槽位手势
--   4. Scripts 面板勾选变化 → save_holster_config() 写回 JSON，下次启动仍生效
--
-- 【数据流】磁盘 JSON ↔ holster_config ↔ ImmersionEnhancerHolster_enabled ↔ UI 勾选
-- =============================================================================

-- 配置文件路径。
-- 新文件：本脚本专用，存 ImmersionEnhancerHolster 开关。

local holster_config_relative_path = "re8_vr/re8_immersion_enhancer_holster.json"
local legacy_holster_config_relative_path = "re8_vr/re8_vr_holster.json"
-- io.open 兜底读写用同一条相对路径（不要加 reframework/data/ 前缀，会套娃）。
local holster_config_path = holster_config_relative_path
local legacy_holster_config_path = legacy_holster_config_relative_path
local holster_config = nil      -- 从磁盘读出的配置表
local holster_json = nil        -- json 模块缓存，只 require 一次

-- 安全读文件：仅 json.load_file 不可用时的兜底路径会用到。
local function is_blocked_binary_path(path)
    -- 禁止对 .dll / .exe 做 io.open，防止误操作二进制。
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

-- 获取 json 模块；成功则缓存，后续 load/save 共用。
local function get_holster_json()
    if holster_json ~= nil then
        return holster_json
    end

    local ok, json = pcall(require, "json")
    if ok and json then
        holster_json = json
    end

    return holster_json
end

-- 从单个路径读配置。优先 json.load_file，失败再 io.open + json.decode。
local function load_holster_config_from_path(relative_path, absolute_path)
    local json = get_holster_json()
    if not json then return nil end

    if type(json.load_file) == "function" then
        local ok, data = pcall(json.load_file, relative_path)
        if ok and type(data) == "table" then
            return data
        end
    end

    local file = safe_io_open(absolute_path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok2, data = pcall(json.decode, content)
    if ok2 and type(data) == "table" then return data end
    return nil
end

-- 加载总入口：先新文件，再旧文件；旧文件只迁移 ImmersionEnhancerHolster 字段。
local function load_holster_config()
    local dedicated_config = load_holster_config_from_path(holster_config_relative_path, holster_config_path)
    if type(dedicated_config) == "table" then
        return dedicated_config
    end

    local legacy_config = load_holster_config_from_path(legacy_holster_config_relative_path, legacy_holster_config_path)
    if type(legacy_config) == "table" and legacy_config.ImmersionEnhancerHolster ~= nil then
        return {
            ImmersionEnhancerHolster = legacy_config.ImmersionEnhancerHolster ~= false,
        }
    end

    return nil
end

-- 保存配置：优先 json.dump_file，失败再 encode + safe_io_open 写盘。
local function save_holster_config()
    local json = get_holster_json()
    if not json then return false end

    if type(json.dump_file) == "function" then
        local ok = pcall(json.dump_file, holster_config_relative_path, holster_config)
        if ok then
            return true
        end
    end

    if type(json.encode) ~= "function" then
        return false
    end

    local ok, encoded = pcall(json.encode, holster_config)
    if not ok or type(encoded) ~= "string" then
        return false
    end

    local file = safe_io_open(holster_config_path, "w")
    if not file then
        return false
    end

    file:write(encoded)
    file:close()
    return true
end

-- 冷启动：读盘 → 补默认 → 得到运行时开关 ImmersionEnhancerHolster_enabled。
-- 该开关控制腰/肩/胸/左肩武器槽位手势整组启停（apply_holster_toggle）。
holster_config = load_holster_config()
local holster_config_needs_save = false
local function ensure_panel_toggle(field_name, default_value)
    -- 配置缺字段时写入默认值，并标记稍后 save_holster_config。
    if holster_config[field_name] == nil then
        holster_config[field_name] = default_value
        holster_config_needs_save = true
    end
end

if type(holster_config) ~= "table" then
    holster_config = {}
    holster_config_needs_save = true
end
ensure_panel_toggle("ImmersionEnhancerHolster", true)
-- ~= false：只有明确 false 才关；nil/缺字段/true 都算开。
local ImmersionEnhancerHolster_enabled = holster_config.ImmersionEnhancerHolster ~= false

-- ImGui 每帧绘制前调用：重读配置并同步运行时开关（含热重载后）。
local function refresh_panel_toggles_from_config()
    if type(holster_config) ~= "table" then
        holster_config = load_holster_config() or {}
    end
    ensure_panel_toggle("ImmersionEnhancerHolster", true)
    ImmersionEnhancerHolster_enabled = holster_config.ImmersionEnhancerHolster ~= false
end

-- =============================================================================
-- 第一类：底层依赖与运行骨架（初始化入口）
-- 脚本热重载后兼容旧代码：有些 enhancer:tick 调体仍通过全局名访问，这里提供兼容路径。
-- =============================================================================
if not skip_full_init then
environment:initialize({})

local input = environment.input
local actions = environment.actions
local defaultHaptics = environment.defaultHaptics
local gestures = environment.gestures

local Key = input.Key
local MouseButton = input.MouseButton
local GestureValidation_Delay = gestures.GestureValidation_Delay

local gestureSets = environment:createGestureSets(nil)
local gestureTracker = gestureSets.defaultGestureSet
local vrToMouse = environment.vrToMouse

-- =============================================================================
-- 这一段虽然写在配置后面，但本质仍是动作别名和公共辅助；不前移，避免影响上面的配置装载。
-- =============================================================================

local MultiAction = actions.MultiAction
local Mode = actions.Mode
local ModeBasedAction = actions.ModeBasedAction
local ModeSwitch = actions.ModeSwitch
local ModeCopy = actions.ModeCopy
local ModeSwitchWithReset = actions.ModeSwitchWithReset
local CombinedAction = actions.CombinedAction
local Counter = actions.Counter
local ActionSplit = actions.ActionSplit
local Action = actions.Action
local CallbackAction = actions.CallbackAction
local Chain = actions.Chain
local ChainStart = actions.ChainStart
local ChainEnd = actions.ChainEnd
local PersistentAction = actions.PersistentAction
local ActionSequence = actions.ActionSequence
local ResetAction = actions.ResetAction
local TimedAction = actions.TimedAction
local GuardedAction = actions.GuardedAction
local RefcountAction = actions.RefcountAction

local function noop_action()
    return Action.new()
end

local HapticsGroup = environment.haptics.HapticsGroup

-- 交互 grip：背心 pattern 挂在 gripAction.haptics 上，RE_10/RE_07 的 grip 路径才会播背心震动。
local function create_interact_grip_action(vest_pattern, touch_enter, key_action)
    local wrapped = MultiAction.new({ key_action })
    wrapped.haptics = HapticsGroup.new(vest_pattern, nil, nil, touch_enter)
    return wrapped
end

-- =============================================================================
-- 第二类：由本文将发布的G.在此管理
-- =============================================================================
--[[ pullpin 暂时禁用
local pullpin_state = { active = false }
local function set_pullpin_active(active)
    pullpin_state.active = active and true or false
    _G.pullpin_active = pullpin_state.active
end

set_pullpin_active(false)
]]
_G.pullpin_active = false

--第一类
environment.haptics.applyCompanionGestureDefaults(gestureTracker, defaultHaptics)

-- =============================================================================
-- 这个辅助函数直接服务模块启停，所以归第二类；代码留在这里是为了不改已有执行顺序。
-- =============================================================================

-- 第二类 批量启停一组手势；关闭时顺手 reset，避免模式状态残留。
local function set_gesture_group_enabled(gesture_list, enabled)
    for _, gesture in ipairs(gesture_list) do
        if gesture ~= nil then
            if not enabled then
                gesture:reset()
            end
            gesture.enabled = enabled
        end
    end
end

-- =============================================================================
-- 第三类：定义一些限定条件
-- =============================================================================

-- 副手被占用（双手持枪）时，不要触发左手侧功能键。
local function is_support_hand_free()
    if vr_globals.isTwoHandingWeapon() then
        return false
    end
    return true
end

-- =============================================================================
-- 第三类：RE8 个性化映射
-- 下面开始进入具体的手势到键鼠映射：战斗、交互、槽位、近战都在这一类。
-- =============================================================================

local aimMode

-- 诊断面板里直接显示当前 aimMode 实际对应的命令，便于排查映射是否跑偏。
local function get_current_aim_command()
    if type(aimMode) ~= "table" then
        return "none"
    end
    if aimMode.current == 1 then
        return "mouse left"
    end
    if aimMode.current == 2 then
        return "Escape"
    end
    return "none"
end

-- 基础手势集：
-- 菜单与地图。
aimMode = Mode.new()
gestureTracker.triggerLeft.enabled = true
gestureTracker.triggerLeft.action = ModeSwitchWithReset.new(aimMode, 2, 0)

-- 瞄准、开火、换弹。
local aim_pistol_like_action = MultiAction.new({
    input.MousePress.new(MouseButton.Right),
    ModeSwitchWithReset.new(aimMode, 1, 0),
})

local function is_aim_pistol_action_allowed()
    local aim_gesture = gestureTracker.aimPistol
    if aim_gesture.inGripGesture then
        return false
    end

    local vr_state = environment:getVRState()
    if vr_state ~= nil and (vr_state.leftGrip or 0.0) > aim_gesture.gripUpperThreshold then
        return false
    end

    return true
end

local function cancel_aim_pistol_gesture()
    local aim_gesture = gestureTracker.aimPistol
    if not aim_gesture.inGesture then
        return
    end

    if type(aim_gesture.action) == "table" and type(aim_gesture.action.leave) == "function" then
        aim_gesture.action:leave()
    end
    aim_gesture.inGesture = false
end

local aim_pistol_reload_action = GuardedAction.new(input.KeyPress.new(Key.R), is_support_hand_free)

gestureTracker.aimPistol.enabled = true
gestureTracker.aimPistol.action = GuardedAction.new(aim_pistol_like_action, is_aim_pistol_action_allowed)

-- 左手 grip：换弹；生效时取消瞄准，避免与 aim pistol 冲突。
gestureTracker.aimPistol.gripAction = MultiAction.new({
    CallbackAction.new({
        enter = function()
            cancel_aim_pistol_gesture()
        end,
    }),
    aim_pistol_reload_action,
})
--切换弹药
gestureTracker.aimPistol.triggerAction = input.KeyPress.new(Key.F)

-- 治疗
gestureTracker.injectSyringe.enabled = true
gestureTracker.injectSyringe.triggerAction = GuardedAction.new(noop_action(), is_support_hand_free)


-- 右手扳机：开火；RE_10 通过 triggerRightFireAction 绑定开火震动。
gestureTracker.triggerRight.enabled = true
local trigger_right_fire_action = input.MousePress.new(MouseButton.Left)
local trigger_right_menu_action = input.KeyPress.new(Key.P)
--local trigger_right_knife_action = input.KeyPress.new(Key.Space)

gestureTracker.triggerRight.action = trigger_right_fire_action

--体术
gestureTracker.meleeRight.enabled = true
gestureTracker.meleeRight.gripAction = input.MousePress.new(MouseButton.Left)

gestureTracker.thrustLeft.enabled = true
gestureTracker.thrustLeft.gripAction = input.MousePress.new(MouseButton.Left)
gestureTracker.thrustRight.enabled = true
gestureTracker.thrustRight.gripAction = input.MousePress.new(MouseButton.Left)

-- 扔鱼叉
gestureTracker.upperAreaRight.enabled = true
gestureTracker.upperAreaRight.action = input.MousePress.new(MouseButton.Right)

--[[ pullpin 暂时禁用
-- 拉雷手势。
gestureTracker.pullPin.enabled = true
gestureTracker.pullPin.triggerAction = PersistentAction.new(MultiAction.new({
    CallbackAction.new({
        enter = function()
            set_pullpin_active(true)
        end,
        leave = function()
            set_pullpin_active(false)
        end,
        reset = function()
            set_pullpin_active(false)
        end,
    }),
    input.MousePress.new(MouseButton.Right),
}), 2.0, 1)
]]
gestureTracker.pullPin.enabled = false

-- 蹲伏、重置、侧移。
gestureTracker.duck.enabled = true
gestureTracker.duck.action = input.KeyToggle.new(Key.C, {
    tapOnLeave = true,
    pulseDuration = 0.08,
})

gestureTracker.lightLeft.enabled = true
gestureTracker.lightLeft.action = MultiAction.new({
    CallbackAction.new(function()
        input.resetKB(environment)
    end),
    CallbackAction.new(function()
        pcall(function() environment:reset() end)
    end),
})
gestureTracker.lightLeft.validationMode = GestureValidation_Delay

--[[gestureTracker.leanLeft.enabled = false
gestureTracker.leanLeft.action = input.KeyPress.new(Key.A)

gestureTracker.leanRight.enabled = false
gestureTracker.leanRight.action = input.KeyPress.new(Key.D)
]]

-- 交互。
gestureTracker.useRightDown.enabled = true
gestureTracker.useRightDown.gripAction = input.KeyPress.new(Key.F)

gestureTracker.useLeftDown.enabled = true
gestureTracker.useLeftDown.gripAction = input.KeyPress.new(Key.F)

-- 切换楼层
gestureTracker.swipeLeftHandUp.enabled = true
gestureTracker.swipeLeftHandUp.gripAction = input.KeyPress.new(Key.T)
gestureTracker.swipeLeftHandDown.enabled = true
gestureTracker.swipeLeftHandDown.gripAction = input.KeyPress.new(Key.G)

--菜单
gestureTracker.swipeLeftHandLeft.enabled = true
gestureTracker.swipeLeftHandLeft.gripAction = input.KeyPress.new(Key.Z)
gestureTracker.swipeLeftHandRight.enabled = true
gestureTracker.swipeLeftHandRight.gripAction = input.KeyPress.new(Key.C)

--手电筒槽位
--gestureTracker.chestLeft.enabled = true
--gestureTracker.chestLeft.gripAction = input.KeyPress.new(Key.F)

-- 武器槽位模块。
-- 右腰、右肩、右胸、左肩的数字键绑定都集中在这里；诊断面板读取的最近一次槽位事件也在这里维护。
local last_weapon_slot_event = {
    region = "none",
    binding = "none",
    key = "none",
    source = "none",
    at = 0.0,
}

local function record_weapon_slot_event(region_name, binding_name, digit_name, current_time, from_voice_recognition)
    local region = region_name or "unknown"
    local binding = binding_name or "unknown"
    local key = tostring(digit_name or "?")
    local source = from_voice_recognition and "voice" or "gesture"
    local at = current_time or os.clock()

    _G[vr_globals.KEYS.weapon_slot_region] = region
    _G[vr_globals.KEYS.weapon_slot_binding] = binding
    _G[vr_globals.KEYS.weapon_slot_key] = key
    _G[vr_globals.KEYS.weapon_slot_source] = source
    _G[vr_globals.KEYS.weapon_slot_at] = at

    last_weapon_slot_event.region = region
    last_weapon_slot_event.binding = binding
    last_weapon_slot_event.key = key
    last_weapon_slot_event.source = source
    last_weapon_slot_event.at = at
end

local function get_last_weapon_slot_event()
    return {
        region = last_weapon_slot_event.region,
        binding = last_weapon_slot_event.binding,
        key = last_weapon_slot_event.key,
        source = last_weapon_slot_event.source,
        at = last_weapon_slot_event.at,
    }
end

local SLOT_HAPTIC_CLASS_BY_REGION_BINDING = {
    holsterWeaponRight = { grip = "Pistol", trigger = "AutoPistol" },
    shoulderWeaponRight = { grip = "Shotgun", trigger = "AutoShotgun" },
    shoulderWeaponLeft = { grip = "AutoRifle", trigger = "AutoRifle" },
}

local function set_slot_haptic_class(region_name, binding_name)
    local region_map = SLOT_HAPTIC_CLASS_BY_REGION_BINDING[region_name]
    if region_map == nil then
        return
    end

    local haptic_class = region_map[binding_name]
    if haptic_class ~= nil then
        _G[vr_globals.KEYS.last_slot_haptic_class] = haptic_class
    end
end

local function create_weapon_slot_press(region_name, binding_name, digit_name, key_code)
    return MultiAction.new({
        CallbackAction.new(function(current_time, from_voice_recognition)
            record_weapon_slot_event(region_name, binding_name, digit_name, current_time, from_voice_recognition)
            set_slot_haptic_class(region_name, binding_name)
        end),
        input.KeyPress.new(key_code),
    })
end

local function configure_weapon_slot_bindings()
    gestureTracker.holsterWeaponRight.gripAction = create_weapon_slot_press("holsterWeaponRight", "grip", "1", Key.D1)
    gestureTracker.holsterWeaponRight.triggerAction = create_weapon_slot_press("holsterWeaponRight", "trigger", "5", Key.D5)

    gestureTracker.shoulderWeaponRight.gripAction = create_weapon_slot_press("shoulderWeaponRight", "grip", "2", Key.D2)
    gestureTracker.shoulderWeaponRight.triggerAction = create_weapon_slot_press("shoulderWeaponRight", "trigger", "2", Key.D2)

    gestureTracker.chestRight.gripAction = create_weapon_slot_press("chestRight", "grip", "3", Key.D3)
    gestureTracker.chestRight.triggerAction = create_weapon_slot_press("chestRight", "trigger", "7", Key.D7)

    gestureTracker.shoulderWeaponLeft.gripAction = create_weapon_slot_press("shoulderWeaponLeft", "grip", "4", Key.D4)
    gestureTracker.shoulderWeaponLeft.triggerAction = create_weapon_slot_press("shoulderWeaponLeft", "trigger", "8", Key.D8)
end

configure_weapon_slot_bindings()

local holster_toggle_gestures = {
    gestureTracker.holsterWeaponRight,
    gestureTracker.shoulderWeaponRight,
    gestureTracker.chestRight,
    gestureTracker.shoulderWeaponLeft,
}

local function apply_holster_toggle()
    set_gesture_group_enabled(holster_toggle_gestures, ImmersionEnhancerHolster_enabled ~= false)
end

-- =============================================================================
-- 第二类：微调设置与模块开关（收口）
-- =============================================================================

apply_holster_toggle()
if holster_config_needs_save then
    save_holster_config()
end

-- 暴露给其他脚本，尤其是 RE_12_diagnose.lua。
enhancer = {
    environment = environment,
    gestureSets = gestureSets,
    gestureTracker = gestureTracker,
    triggerRightFireAction = trigger_right_fire_action,
    aimMode = aimMode,
    -- pullpinState = pullpin_state,
    pullpinState = { active = false },
    getCurrentAimCommand = get_current_aim_command,
    getLastWeaponSlotEvent = get_last_weapon_slot_event,
    getLastWeaponSlotAction = get_last_weapon_slot_event,
    vrToMouse = vrToMouse,
    holsterConfig = holster_config,
    applyHolsterToggle = apply_holster_toggle,
    _last_tick_at = 0.0,
    _last_tick_source = "uninitialized",
    _fallback_active = false,
    _twoHandAimHold = false,
    _aimPistolLikeAction = aim_pistol_like_action,
}

-- [第三类/运行时] 双手持枪：由 tick 持续驱动 aim_pistol_like_action。
function enhancer:syncTwoHandAim(current_time)
    local action = self._aimPistolLikeAction
    if action == nil then
        return
    end

    local want_two_hand = vr_globals.isTwoHandingWeapon()
    if want_two_hand and not self._twoHandAimHold then
        action:enter(current_time, false)
        self._twoHandAimHold = true
    elseif not want_two_hand and self._twoHandAimHold then
        action:leave()
        self._twoHandAimHold = false
    elseif want_two_hand and self._twoHandAimHold then
        action:update(current_time)
    end
end

-- =============================================================================
-- 【第二类 · 运行骨架】enhancer 每帧入口（由 RE_08 attachEnhancerRuntime 挂到 UpdateBehavior / on_frame）
-- =============================================================================
-- 顺序固定，勿随意调换：
--   1. RE_10 同步武器震动路由并绑扳机震动组
--   2. RE_08 environment:tick → 手势识别 → 键鼠/动作
--   3. syncTwoHandAim → motion _G 驱动双手瞄准 hold（须在 gesture tick 之后）
-- =============================================================================
function enhancer:tick(source)
    self._last_tick_at = os.clock()
    self._last_tick_source = source or "unknown"

    -- ① 武器震动（RE_10）：槽位路由或武器ID路由 → 当前 Haptics_* 组
    if self.hapticFeedbackManager ~= nil and type(self.hapticFeedbackManager.syncCurrentWeapon) == "function" then
        self.hapticFeedbackManager:syncCurrentWeapon()
        if self.hapticFeedbackEnabled ~= false and type(self.hapticFeedbackManager.applyHapticFeedbackGroup) == "function" then
            self.hapticFeedbackManager:applyHapticFeedbackGroup()
        elseif type(self.hapticFeedbackManager.applyTouchOnlyGroup) == "function" then
            -- 震动总关时仍保留控制器触觉反馈（touch-only）
            self.hapticFeedbackManager:applyTouchOnlyGroup()
        end
    end

    -- ② 手势与输入主循环（RE_08）
    self.environment:tick(self._last_tick_at)

    -- ③ 双手瞄准补同步（须在 ② 之后）
    if type(self.syncTwoHandAim) == "function" then
        self:syncTwoHandAim(self._last_tick_at)
    end

    -- ④ 发布瞄准状态到 _G，供 re8_vr 消费驱动 LT
    --    aimPistol 手势和 twoHandAim 都会触发 aim_pistol_like_action，取并集
    local aim_pistol_gesture = self.gestureTracker and self.gestureTracker.aimPistol
    local is_aiming = (aim_pistol_gesture and aim_pistol_gesture.inGesture) or (self._twoHandAimHold == true)
    _G[vr_globals.KEYS.aim_pistol_active] = is_aiming
end

end -- not skip_full_init

local enhancer = existing_enhancer or enhancer

-- =============================================================================
-- UI 在冷启动与脚本热重载时都会注册，避免 Scripts 面板菜单消失。
-- =============================================================================

local function register_immersion_enhancer_ui()
    if not (re and re.on_draw_ui and imgui) then
        return
    end

    if rawget(_G, "__RE09_immersion_ui_registered") == true then
        return
    end
    _G.__RE09_immersion_ui_registered = true

    re.on_draw_ui(function()
        refresh_panel_toggles_from_config()
        local active_enhancer = environment:getEnhancer() or enhancer

        imgui.separator()
        imgui.text_colored("Immersion Enhancer", 0xFF00FFFF)
        local holster_changed, holster_enabled = imgui.checkbox("Enable holster weapon slots", ImmersionEnhancerHolster_enabled ~= false)
        if holster_changed then
            ImmersionEnhancerHolster_enabled = holster_enabled and true or false
            holster_config.ImmersionEnhancerHolster = ImmersionEnhancerHolster_enabled
            if type(active_enhancer) == "table" and type(active_enhancer.applyHolsterToggle) == "function" then
                active_enhancer.applyHolsterToggle()
            elseif type(apply_holster_toggle) == "function" then
                apply_holster_toggle()
            end
            save_holster_config()
        end

    end)
end

if not skip_full_init then
    environment:attachEnhancerRuntime(enhancer)
end

register_immersion_enhancer_ui()

-- =============================================================================
-- 【第二类 · 热重载迁移】skip_full_init 分支（Scripts 重载 RE_09 时进入，非冷启动）
-- =============================================================================
-- 保留内存里已有的 enhancer，只 patch 缺字段/旧 closure，再 attachEnhancerRuntime。
-- 移植其它作品时这里最常改：要同步哪些 _G、补哪些 enhancer 字段、重绑哪些手势。
--
-- 当前维护项：
--   pullpinState        → _G.pullpin_active
--   _aimPistolLikeAction（syncTwoHandAim 依赖）
--   triggerLeft.action  → 菜单 ModeSwitchWithReset 重绑
--   syncTwoHandAim      + _twoHandAimHold（缺则补定义）
--
-- 注意：syncTwoHandAim 与冷启动处逻辑需保持一致；改第三类业务时两处都要看。
-- =============================================================================
if skip_full_init then
    -- 重载前松开模拟输入，避免键鼠卡住
    local old_env = rawget(_G, "VREnvironment")
    if old_env ~= nil then
        if type(old_env.input) == "table" and type(old_env.input.releaseAll) == "function" then
            old_env.input.releaseAll()
        end
    end

    --[[ pullpin 暂时禁用
    -- 拉雷运行时标志：旧 enhancer → _G
    local existing_pullpin_state = existing_enhancer.pullpinState
    if type(existing_pullpin_state) == "table" then
        _G.pullpin_active = existing_pullpin_state.active == true
    elseif rawget(_G, "pullpin_active") == nil then
        _G.pullpin_active = false
    end
    ]]
    _G.pullpin_active = false

    -- 瞄准运行时标志：旧 enhancer → _G（aimPistol 手势 + twoHandAim 并集）
    local existing_aim_pistol = existing_enhancer.gestureTracker and existing_enhancer.gestureTracker.aimPistol
    local is_aiming = (existing_aim_pistol and existing_aim_pistol.inGesture) or (existing_enhancer._twoHandAimHold == true)
    _G[vr_globals.KEYS.aim_pistol_active] = is_aiming

    -- 双手瞄准 sync 依赖的 action 引用
    if existing_enhancer._aimPistolLikeAction == nil and type(existing_enhancer.gestureTracker) == "table" then
        local aim_pistol_gesture = existing_enhancer.gestureTracker.aimPistol
        if type(aim_pistol_gesture) == "table" and aim_pistol_gesture.action ~= nil then
            existing_enhancer._aimPistolLikeAction = aim_pistol_gesture.action
        end
    end

    -- 热重载后 triggerLeft 菜单切换 action 可能指向旧 closure，需重建
    if type(existing_enhancer.gestureTracker) == "table"
        and type(existing_enhancer.aimMode) == "table"
        and type(existing_enhancer.gestureTracker.triggerLeft) == "table" then
        local runtime_env = existing_enhancer.environment or rawget(_G, "VREnvironment")
        if type(runtime_env) == "table" and type(runtime_env.actions) == "table" then
            existing_enhancer.gestureTracker.triggerLeft.action =
                runtime_env.actions.ModeSwitchWithReset.new(existing_enhancer.aimMode, 2, 0)
        end
    end

    -- 旧 enhancer 无 syncTwoHandAim 时补定义（逻辑须与冷启动版一致）
    if type(existing_enhancer.syncTwoHandAim) ~= "function" then
        function existing_enhancer:syncTwoHandAim(current_time)
            local action = self._aimPistolLikeAction
            if action == nil then
                return
            end

            local want_two_hand = vr_globals.isTwoHandingWeapon()
            if want_two_hand and not self._twoHandAimHold then
                action:enter(current_time, false)
                self._twoHandAimHold = true
            elseif not want_two_hand and self._twoHandAimHold then
                action:leave()
                self._twoHandAimHold = false
            elseif want_two_hand and self._twoHandAimHold then
                action:update(current_time)
            end
        end
        if existing_enhancer._twoHandAimHold == nil then
            existing_enhancer._twoHandAimHold = false
        end
    end

    -- 重新挂 UpdateBehavior / on_frame；跳过后面的冷启动 init
    local existing_environment = existing_enhancer.environment or rawget(_G, "VREnvironment")
    if type(existing_environment) == "table" then
        environment:attachEnhancerRuntime(existing_enhancer)
    end
    return existing_enhancer
end

-- =============================================================================
-- 【第一类 · 模块收口】冷启动路径：全局导出与 require 返回值
-- =============================================================================
-- 全局导出统一由 RE_08_environment.publishEnhancer 完成，这里仅确保兼容路径可用。
environment:publishEnhancer(enhancer)

-- require 本文件时返回同一份 enhancer 实例，属于模块对外接口收口。
return enhancer
