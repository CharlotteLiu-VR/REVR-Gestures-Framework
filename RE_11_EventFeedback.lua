-- =============================================================================
-- RE_11_EventFeedback - 事件反馈模块 (RE7)
-- 功能：将游戏事件（治疗等）转化为触觉背心反馈
-- =============================================================================

local module_name = "RE_11_EventFeedback"
local vr_globals = require("RE_00_vr_globals")
local haptics_driver = require("RE_05_haptics")

local existing_module = package.loaded[module_name]

local function get_enhancer_global()
    local enhancer = rawget(_G, "VR_ENHANCER")
    if type(enhancer) == "table" then
        return enhancer
    end
    return nil
end

-- =============================================================================
-- 热重载处理：防止重复注册回调导致累积
-- =============================================================================
if existing_module ~= nil then
    local needs_full_reload = type(existing_module.init) ~= "function"
        or type(existing_module.ensureInstalled) ~= "function"

    if not needs_full_reload then
        local existing_enhancer = get_enhancer_global()
        if type(existing_enhancer) == "table" then
            existing_module.ensureInstalled(existing_enhancer)
        end
        return existing_module
    end

    log.warn("RE_11: module structure incomplete after hot-reload, skipping full reload")
    return existing_module
end

local eventFeedback = {}

-- =============================================================================
-- 开关状态同步：从 RE_05_haptics 读取配置
-- =============================================================================
local function sync_enabled_from_haptics_driver()
    if type(haptics_driver.get_haptics_config) == "function" then
        local cfg = haptics_driver.get_haptics_config()
        eventFeedback.enabled = type(cfg) == "table" and cfg.enabled == true or false
    else
        eventFeedback.enabled = rawget(_G, "VR_HAPTIC_FEEDBACK_ENABLED") == true
    end
    _G.VR_HAPTIC_FEEDBACK_ENABLED = eventFeedback.enabled
end

sync_enabled_from_haptics_driver()

-- =============================================================================
-- 触觉 Pattern 名称常量（注册在 HapticPlayer 中的震动模式）
-- =============================================================================
local HEAL_VEST_PATTERN = "Healing_1"
local HEAL_SOURCE_NAME = "Heal"

-- =============================================================================
-- 治疗事件状态跟踪
-- =============================================================================
local heal_state = {
    last_active = false,            -- 上一帧 heal 是否激活（上升沿检测用）
    next_trigger_allowed = 0.0,     -- 下次允许触发治疗震动的时间（冷却）
    cooldown = 1.75,                -- 冷却时间（秒）
}

-- =============================================================================
-- 工具函数
-- =============================================================================

local function safe_eval(callback)
    local ok, result = pcall(callback)
    if ok then
        return result
    end
    return nil
end

local function is_event_feedback_enabled()
    sync_enabled_from_haptics_driver()
    return eventFeedback.enabled ~= false
end

-- =============================================================================
-- HapticPlayer 访问函数
-- =============================================================================

local function get_environment_from_enhancer(enhancer)
    if type(enhancer) == "table" and type(enhancer.environment) == "table" then
        return enhancer.environment
    end
    local environment = rawget(_G, "VREnvironment")
    if type(environment) == "table" then
        return environment
    end
    return nil
end

local function get_haptic_player_from_enhancer(enhancer)
    local environment = get_environment_from_enhancer(enhancer)
    if type(environment) ~= "table" then
        return nil
    end
    if environment.hapticFeedbackEnabled == false then
        return nil
    end
    return environment.hapticPlayer
end

-- =============================================================================
-- 播放已注册的震动模式
-- =============================================================================

local function play_event_registered_haptics(enhancer, gesture_name, pattern_name, phase_name)
    local haptic_player = get_haptic_player_from_enhancer(enhancer)
    if haptic_player == nil or type(haptic_player.play_registered) ~= "function" then
        return false
    end

    local ok, played = pcall(function()
        return haptic_player:play_registered(gesture_name, pattern_name, phase_name or "enter") == true
    end)
    if not ok then
        return false
    end
    return played == true
end

-- =============================================================================
-- 治疗震动分发
-- =============================================================================

local function dispatch_heal_haptics(enhancer)
    return play_event_registered_haptics(enhancer, HEAL_SOURCE_NAME, HEAL_VEST_PATTERN, "enter")
end

-- =============================================================================
-- 治疗事件检测：上升沿 + 冷却
-- 从 vr_globals.isHealActive() 读取 g_is_heal_active 布尔值
-- 参考 two hand weapon 的读取方式：rawget(_G, KEYS.xxx)
-- =============================================================================

local function update_heal_event()
    if not is_event_feedback_enabled() then
        heal_state.last_active = false
        return
    end

    -- 参考 two hand weapon 的读取方式，通过 vr_globals 访问器读取全局变量
    local is_heal_active = vr_globals.isHealActive()

    -- 上升沿检测：从 false 变为 true 时触发
    if is_heal_active and not heal_state.last_active then
        local now = os.clock()
        -- 冷却时间检查，防止高频触发
        if now >= heal_state.next_trigger_allowed then
            heal_state.next_trigger_allowed = now + heal_state.cooldown

            local enhancer = get_enhancer_global()
            if type(enhancer) == "table" then
                dispatch_heal_haptics(enhancer)
            end
        end
    end

    heal_state.last_active = is_heal_active
end

-- =============================================================================
-- 每帧更新
-- =============================================================================

re.on_frame(function()
    update_heal_event()
end)

-- =============================================================================
-- 模块接口
-- =============================================================================

function eventFeedback.init()
    sync_enabled_from_haptics_driver()
    heal_state.last_active = false
    heal_state.next_trigger_allowed = 0.0
end

function eventFeedback.ensureInstalled(enhancer)
    -- 预留：未来可在此安装更多事件 hook
end

package.loaded[module_name] = eventFeedback
return eventFeedback
