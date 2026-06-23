local module_name = "RE_10_HapticFeedback"

-- =============================================================================
-- 【震动路由 · 总览】
-- =============================================================================
-- 路由模式由 RE_00 的 __vr_haptic_routing_mode 控制（默认 1 = 槽位路由）：
--
--   mode 0 · 武器ID路由
--     LateUpdate 探针 read_equipped_weapon_id() → armXXXX
--     → WEAPON_ID_TO_CLASS 查表 → Pistol / Rifle / …
--     → WEAPON_CLASS_TO_GROUP_KEY → Haptics_Pistol 等震动组
--
--   mode 1 · 槽位路由（RE4 主路径）
--     RE_09 切枪手势 set_slot_haptic_class() 写入 __vr_last_slot_haptic_class
--     → syncCurrentWeapon 直接读槽位类别，不查 WEAPON_ID_TO_CLASS
--     → 同上映射到 Haptics_* 震动组
--
-- 两种模式最终都在 HapticFeedbackManager:syncCurrentWeapon → _resolve_group 选组；
-- 开火后坐力触发路径按路由分流：
--   mode 0 · 武器ID → execFire hook → triggerFireHaptics（扳机仅 touch）
--   mode 1 · 槽位   → 完整 Haptics_* 绑 triggerRight，右扳机按下即播背心后坐力
-- =============================================================================

-- LateUpdate: weapon probe only (mag holster pulse lives in RE_11_EventFeedback).
if not rawget(_G, "VR_WEAPON_PROBE_LATEUPDATE_REGISTERED") then
    _G.VR_WEAPON_PROBE_LATEUPDATE_REGISTERED = true

    re.on_application_entry("LateUpdateBehavior", function()
        local probe_tick = rawget(_G, "VR_WEAPON_PROBE_TICK")
        if type(probe_tick) == "function" then
            probe_tick()
        end
    end)
end

local existing_module = package.loaded[module_name]

local function get_enhancer_global()
    local enhancer = rawget(_G, "VR_ENHANCER")
    if type(enhancer) == "table" then
        return enhancer
    end

    return nil
end

if existing_module ~= nil then
    local manager_proto = existing_module.HapticFeedbackManager
    local needs_full_reload = type(manager_proto) ~= "table"
        or type(manager_proto.triggerFireHaptics) ~= "function"
        or type(manager_proto.bindEnhancer) ~= "function"
        or type(manager_proto.update) ~= "function"
        or type(existing_module.ensureInstalled) ~= "function"
        or type(existing_module.init) ~= "function"

    if not needs_full_reload then
        local existing_enhancer = get_enhancer_global()
        if type(existing_module.ensureInstalled) == "function" and type(existing_enhancer) == "table" then
            existing_module.ensureInstalled(existing_enhancer)
        end
        return existing_module
    end

    log.warn("RE_10: module structure incomplete after hot-reload, skipping full reload to prevent re.on_* callback accumulation")
    return existing_module
end

local vr_globals = require("RE_00_vr_globals")
local haptics_driver = require("RE_05_haptics")
local hapticFeedback = {}

local LEON_GRENADE_WEAPONS = {
    ["arm0200"] = true,
    ["arm0204"] = true,
}

local WEAPON_DISPLAY_NAMES = {
    arm0000 = "Matilda IMP",
    arm0001 = "S&S M232",
    arm0003 = "Silencer 9",
    arm0004 = "B934",
    arm0005 = "Redemption",
    arm0006 = "Ghost Grudge",
    arm0007 = "Alligator Snapper",
    arm0100 = "MSBG 500",
    arm0103 = "W870 Police",
    arm0104 = "990-TAC",
    arm0200 = "Grenade",
    arm0202 = "Flash Grenade",
    arm0203 = "Grenade",
    arm0204 = "Grenade",
    arm0207 = "Grenade",
    arm0300 = "Axe",
    arm0303 = "Combat Knife",
    arm0319 = "Knife",
    arm0335 = "Knife",
    arm0350 = "Axe",
    arm0351 = "Knife",
    arm0353 = "Knife",
    arm0354 = "Knife",
    arm0400 = "Requiem",
    arm0500 = "Gal",
    arm0501 = "Stiri REVO3 A1",
    arm0503 = "Clatter Carbine",
    arm0505 = "Freya's Needle",
    arm0600 = "Classic 70",
    arm0601 = "Marksman 1A",
    arm0700 = "RPG-7",
}

local weapon_info_cache = {}
local weapon_info_cache_ready = false

-- =============================================================================
-- 【武器ID路由 · 探针与读表基础设施】（mode 0 专用；mode 1 探针仍写 current_weapon_id 供诊断）
-- =============================================================================
-- normalize_weapon_id / read_equipped_weapon_id：从游戏内存解析 armXXXX 武器 ID。
-- publish_current_weapon：写入 __vr_current_weapon_id / display_name。
-- 注：read_equipped_weapon_id 当前走 RE9 SDK 路径（app.CharacterManager），
--     RE4 原生为 chainsaw.*，探针在 RE4 上可能读不到 ID；槽位路由不依赖此路径。
-- =============================================================================

local function normalize_weapon_id(value)
    if value == nil then
        return nil
    end

    local text = tostring(value)
    local weapon_id = text:match("(arm%d+)")
    if weapon_id ~= nil then
        return weapon_id:lower()
    end

    if text ~= "" and text:lower():match("^arm") then
        return text:lower()
    end

    return nil
end

local function safe_call_method(value, method_name)
    if value == nil then
        return nil
    end

    local ok, result = pcall(function()
        return value:call(method_name)
    end)
    if ok and result ~= nil then
        return result
    end

    return nil
end

local function ensure_weapon_info_cache()
    if weapon_info_cache_ready then
        return weapon_info_cache
    end

    weapon_info_cache_ready = true

    for weapon_id, display_name in pairs(WEAPON_DISPLAY_NAMES) do
        local normalized_id = normalize_weapon_id(weapon_id)
        if normalized_id ~= nil then
            weapon_info_cache[normalized_id] = {
                id = normalized_id,
                displayName = display_name,
                instance = weapon_info_cache[normalized_id] and weapon_info_cache[normalized_id].instance or nil,
            }
        end
    end

    if sdk == nil or type(sdk.find_type_definition) ~= "function" then
        return weapon_info_cache
    end

    local weapon_id_type = sdk.find_type_definition("app.WeaponID")
    if weapon_id_type == nil then
        return weapon_info_cache
    end

    local fields = weapon_id_type:get_fields()
    if type(fields) ~= "table" then
        return weapon_info_cache
    end

    for _, field in ipairs(fields) do
        if field ~= nil and field:is_static() then
            local field_name = field:get_name()
            local weapon_id = normalize_weapon_id(field_name)
            if weapon_id ~= nil then
                local instance = field:get_data(nil)
                local entry = weapon_info_cache[weapon_id] or {
                    id = weapon_id,
                    displayName = weapon_id,
                }
                entry.instance = instance
                if WEAPON_DISPLAY_NAMES[weapon_id] ~= nil then
                    entry.displayName = WEAPON_DISPLAY_NAMES[weapon_id]
                elseif entry.displayName == nil or entry.displayName == weapon_id then
                    entry.displayName = weapon_id
                end
                weapon_info_cache[weapon_id] = entry
            end
        end
    end

    return weapon_info_cache
end

local function resolve_weapon_id_from_value(value)
    if value == nil then
        return nil
    end

    local from_call = normalize_weapon_id(safe_call_method(value, "ToString"))
    if from_call ~= nil then
        return from_call
    end

    local ok_direct, direct_text = pcall(function()
        return value:ToString()
    end)
    if ok_direct and direct_text ~= nil then
        local from_direct = normalize_weapon_id(direct_text)
        if from_direct ~= nil then
            return from_direct
        end
    end

    ensure_weapon_info_cache()
    for weapon_id, entry in pairs(weapon_info_cache) do
        if entry.instance ~= nil and entry.instance == value then
            return weapon_id
        end
    end

    return normalize_weapon_id(value)
end

local function safe_eval_field(object, field_name)
    if object == nil then
        return nil
    end

    local ok, value = pcall(function()
        return object:get_field(field_name)
    end)
    if ok then
        return value
    end

    return nil
end

local function read_weapon_id_from_equipment(equipment, updater)
    if updater ~= nil then
        local equip_weapon = safe_call_method(updater, "get_EquipWeapon")
        local weapon_id_obj = equip_weapon and safe_call_method(equip_weapon, "get_WeaponID") or nil
        local equip_weapon_name = resolve_weapon_id_from_value(weapon_id_obj)
        if equip_weapon_name ~= nil then
            return equip_weapon_name, "EquipWeapon"
        end
    end

    if equipment ~= nil then
        local equip_weapon_id = resolve_weapon_id_from_value(safe_eval_field(equipment, "<EquipWeaponID>k__BackingField"))
        if equip_weapon_id ~= nil then
            return equip_weapon_id, "EquipWeaponID"
        end
    end

    return nil, nil
end

local function read_equipped_weapon_id()
    ensure_weapon_info_cache()

    local character_manager = sdk and sdk.get_managed_singleton and sdk.get_managed_singleton("app.CharacterManager") or nil
    if character_manager == nil then
        return nil, nil
    end

    local context = safe_call_method(character_manager, "get_PlayerContextFast")
    if context ~= nil then
        local updater = safe_call_method(context, "get_Updater")
        if updater ~= nil then
            local equipment = safe_call_method(updater, "get_Equipment")
            local weapon_id, source = read_weapon_id_from_equipment(equipment, updater)
            if weapon_id ~= nil then
                return weapon_id, source
            end
        end
    end

    local player = safe_call_method(character_manager, "get_ManualPlayer")
    if player ~= nil then
        local context_holder = safe_call_method(player, "get_CharacterContextHolder")
        local manual_context = context_holder and safe_call_method(context_holder, "get_Current") or nil
        if manual_context ~= nil then
            local weapon_id = resolve_weapon_id_from_value(safe_eval_field(manual_context, "<EquipWeaponID>k__BackingField"))
            if weapon_id ~= nil then
                return weapon_id, "ManualPlayer"
            end
        end
    end

    return nil, nil
end

local function get_weapon_info(weapon_id)
    local normalized_id = normalize_weapon_id(weapon_id)
    if normalized_id == nil then
        return nil
    end

    ensure_weapon_info_cache()
    local entry = weapon_info_cache[normalized_id]
    if entry ~= nil then
        return {
            id = entry.id,
            displayName = entry.displayName,
        }
    end

    return {
        id = normalized_id,
        displayName = WEAPON_DISPLAY_NAMES[normalized_id] or normalized_id,
    }
end

local function get_weapon_display_name(weapon_id)
    local info = get_weapon_info(weapon_id)
    if info == nil then
        return nil
    end
    return info.displayName
end

local function publish_current_weapon(weapon_id)
    local normalized_id = normalize_weapon_id(weapon_id)
    if normalized_id == nil then
        return nil
    end

    local display_name = get_weapon_display_name(normalized_id) or normalized_id
    _G[vr_globals.KEYS.current_weapon_id] = normalized_id
    _G[vr_globals.KEYS.current_weapon_display_name] = display_name
    return normalized_id, display_name
end

local function is_leon_grenade_weapon_name(weapon_name)
    return type(weapon_name) == "string" and LEON_GRENADE_WEAPONS[weapon_name] == true
end

local function sync_leon_grenade()
    local current_weapon_id = rawget(_G, vr_globals.KEYS.current_weapon_id)
    local active = is_leon_grenade_weapon_name(current_weapon_id)
    _G[vr_globals.KEYS.leon_grenade] = active
    return active
end

local function is_leon_grenade_equipped()
    return sync_leon_grenade()
end

local function is_manual_throw_allowed_for_current_weapon()
    if not is_leon_grenade_equipped() then
        return true
    end
    return rawget(_G, vr_globals.KEYS.pullpin_active) == true
end

local DEFAULT_WEAPON_CLASS = "Pistol"

-- 武器类别 → RE_05 震动组键名（两种路由模式共用）
local WEAPON_CLASS_TO_GROUP_KEY = {
    Melee = "Haptics_Melee",
    Pistol = "Haptics_Pistol",
    AutoPistol = "Haptics_AutoPistol",
    Rifle = "Haptics_Rifle",
    AutoRifle = "Haptics_AutoRifle",
    Shotgun = "Haptics_Shotgun",
    AutoShotgun = "Haptics_AutoShotgun",
}

-- =============================================================================
-- 【武器ID路由 · ID → 震动类别查表】（仅 routing_mode == 0 时用于决定 weapon_class）
-- =============================================================================
-- arm0000 → Pistol，arm0600 → Rifle … 未收录 ID 回退 DEFAULT_WEAPON_CLASS。
-- =============================================================================
local WEAPON_ID_TO_CLASS = {
    arm0000 = "Pistol",
    arm0001 = "Pistol",
    arm0003 = "Pistol",
    arm0004 = "Pistol",
    arm0005 = "Pistol",
    arm0006 = "Pistol",
    arm0007 = "Pistol",
    arm0100 = "Shotgun",
    arm0103 = "Shotgun",
    arm0104 = "Shotgun",
    arm0300 = "Melee",
    arm0303 = "Melee",
    arm0335 = "Melee",
    arm0350 = "Melee",
    arm0353 = "Melee",
    arm0354 = "Melee",
    arm0400 = "Shotgun",--Revolver
    arm0005 = "Shotgun",--Revolver
    arm0006 = "Shotgun",--Revolver
    arm0500 = "AutoPistol",
    arm0501 = "AutoPistol",
    arm0503 = "AutoPistol",
    arm0505 = "AutoPistol",
    arm0600 = "Rifle",
    arm0601 = "Rifle",
    arm0700 = "Shotgun",--RocketLauncher
}

-- get_haptic_routing_mode()：0 = 武器ID路由，1 = 槽位路由（默认见 RE_00_vr_globals.lua）

local function sync_enabled_from_haptics_driver()
    if type(haptics_driver.get_haptics_config) == "function" then
        local cfg = haptics_driver.get_haptics_config()
        hapticFeedback.enabled = type(cfg) == "table" and cfg.enabled == true or false
    else
        hapticFeedback.enabled = rawget(_G, "VR_HAPTIC_FEEDBACK_ENABLED") == true
    end
    _G.VR_HAPTIC_FEEDBACK_ENABLED = hapticFeedback.enabled
end

sync_enabled_from_haptics_driver()

local fire_hook_state = {
    installed = false,
    failed = false,
}

local init_in_progress = false
local init_completed = false

-- =============================================================================
-- 【武器ID路由 · 限频探针 tick】
-- =============================================================================
-- weapon_probe_tick：LateUpdate 调用，变更时更新 weapon_probe 并 publish_current_weapon。
-- resolve_weapon_class：武器ID路由的核心查表（WEAPON_ID_TO_CLASS）。
-- =============================================================================
local weapon_probe = {
    id = nil,                -- 当前武器ID（如 "arm0000"）
    display_name = nil,      -- 显示名称
    weapon_class = nil,      -- 武器类别（如 "Pistol"）
    class_source = nil,      -- 类别来源标识
    last_check_t = 0,        -- 上次检测时间（os.clock）
    check_interval = 0.1,    -- 检测间隔（秒），不切换武器时每100ms才走一次慢路径
    dirty = false,           -- 是否有变更
}

local function safe_eval(callback)
    local ok, result = pcall(callback)
    if ok then
        return result
    end
    return nil
end

local function resolve_weapon_id_value(value)
    return resolve_weapon_id_from_value(value)
end

local function get_haptic_routing_mode()
    return vr_globals.getHapticRoutingMode()  -- 配置在 RE_00，默认 1（槽位）
end

local function publish_current_weapon_id(weapon_id)
    if weapon_id == nil then
        return nil
    end
    publish_current_weapon(weapon_id)
    return weapon_id
end

-- 【武器ID路由】armXXXX → 震动类别（Pistol / Rifle …）
local function resolve_weapon_class(weapon_id)
    local normalized = resolve_weapon_id_value(weapon_id)
    if normalized == nil then
        return DEFAULT_WEAPON_CLASS, "default"
    end

    local weapon_class = WEAPON_ID_TO_CLASS[normalized]
    if weapon_class ~= nil then
        return weapon_class, "weapon_id"
    end

    return DEFAULT_WEAPON_CLASS, "default"
end

-- 武器探针 tick：限频从 native 读取武器ID，检测变更后更新缓存和全局变量。
-- 在 LateUpdateBehavior 中每帧调用，不切换武器时几乎零开销。
local function weapon_probe_tick(now)
    now = now or os.clock()

    -- 快速路径：缓存有效且未到检测间隔，直接返回
    if weapon_probe.id ~= nil
        and (now - weapon_probe.last_check_t) < weapon_probe.check_interval then
        return weapon_probe.id
    end

    weapon_probe.last_check_t = now

    local new_id, source = read_equipped_weapon_id()

    if new_id ~= weapon_probe.id then
        weapon_probe.id = new_id
        weapon_probe.dirty = true

        if new_id ~= nil then
            weapon_probe.display_name = get_weapon_display_name(new_id) or new_id
            weapon_probe.weapon_class, weapon_probe.class_source = resolve_weapon_class(new_id)
            publish_current_weapon(new_id)
        else
            weapon_probe.display_name = nil
            weapon_probe.weapon_class = DEFAULT_WEAPON_CLASS
            weapon_probe.class_source = "default"
        end
    end

    return weapon_probe.id
end

-- 注册到全局，供早期注册的 LateUpdateBehavior 回调调用
_G.VR_WEAPON_PROBE_TICK = weapon_probe_tick

local function read_current_weapon_id()
    if get_haptic_routing_mode() == 1 then
        return vr_globals.getWeaponId(), "cached"
    end

    -- 【武器ID路由】优先读探针缓存（零 native 调用）
    if weapon_probe.id ~= nil then
        return weapon_probe.id, "probe_cache"
    end

    -- 缓存为空，强制跑一轮探针
    local id = weapon_probe_tick()
    if id ~= nil then
        return id, "probe_init"
    end

    return nil, nil
end

local function resolve_trigger_fire_action(enhancer)
    if type(enhancer) ~= "table" then
        return nil
    end

    if enhancer.triggerRightFireAction ~= nil then
        return enhancer.triggerRightFireAction
    end

    local gesture_tracker = enhancer.gestureTracker
    local trigger_right = gesture_tracker and gesture_tracker.triggerRight or nil
    local trigger_action = trigger_right and trigger_right.action or nil
    if type(trigger_action) ~= "table" then
        return nil
    end

    local mapped_actions = trigger_action._actions
    if type(mapped_actions) == "table" then
        return mapped_actions[1]
    end

    return trigger_action
end

local function get_haptics_from_action(action)
    if type(action) ~= "table" then
        return nil
    end

    if type(action.getCurrentHaptics) == "function" then
        return action:getCurrentHaptics()
    end

    return action.haptics
end

local HapticFeedbackManager = {}
HapticFeedbackManager.__index = HapticFeedbackManager

local function dispatch_fire_haptics(manager)
    if type(manager) ~= "table" or type(manager.triggerFireHaptics) ~= "function" then
        return false
    end
    return manager:triggerFireHaptics() == true
end

local function on_exec_fire_haptics()
    sync_enabled_from_haptics_driver()
    if hapticFeedback.enabled == false then
        return
    end

    -- 槽位路由：后坐力由右扳机手势 enter 触发，不走 execFire
    if get_haptic_routing_mode() ~= 0 then
        return
    end

    local enhancer = get_enhancer_global()
    if type(enhancer) ~= "table" then
        return
    end

    local manager = enhancer.hapticFeedbackManager
    if dispatch_fire_haptics(manager) then
        return
    end

    if type(hapticFeedback.ensureInstalled) == "function" then
        manager = hapticFeedback.ensureInstalled(enhancer)
        dispatch_fire_haptics(manager)
    end
end

local FIRE_HOOK_TYPE_CANDIDATES = {
    "chainsaw.PlayerEquipment",
    "app.PlayerEquipment",
}

local function install_fire_hook()
    if fire_hook_state.installed or fire_hook_state.failed then
        return
    end

    local method = nil
    for _, typename in ipairs(FIRE_HOOK_TYPE_CANDIDATES) do
        local td = safe_eval(function()
            if sdk == nil or type(sdk.find_type_definition) ~= "function" then
                return nil
            end
            return sdk.find_type_definition(typename)
        end)
        if td ~= nil then
            method = safe_eval(function()
                return td:get_method("execFire")
            end)
            if method ~= nil then
                fire_hook_state.type_name = typename
                break
            end
        end
    end

    if method == nil then
        fire_hook_state.failed = true
        return
    end

    local ok = pcall(function()
        sdk.hook(method, function(_) end, function(retval)
            pcall(on_exec_fire_haptics)
            return retval
        end)
    end)
    if ok then
        fire_hook_state.installed = true
    else
        fire_hook_state.failed = true
    end
end

function hapticFeedback.init(reason)
    if init_in_progress then
        return init_completed
    end

    if hapticFeedback.enabled == false then
        return false
    end

    init_in_progress = true

    install_fire_hook()

    local ok = true
    if type(haptics_driver.init) == "function" then
        ok = haptics_driver.init(reason or "RE_10_HapticFeedback") == true
    end

    init_in_progress = false
    init_completed = ok
    return ok
end

function HapticFeedbackManager.new(enhancer)
    local instance = setmetatable({
        enhancer = nil,
        environment = nil,
        gestureTracker = nil,
        triggerFireAction = nil,
        currentWeaponId = nil,
        currentWeaponClass = nil,
        currentGroupKey = nil,
        currentWeaponSource = nil,
        currentClassSource = nil,
        activeFireGroup = nil,
        touchOnlyGroups = {},
        _boundTriggerGesture = nil,
        _lastRoutingMode = nil,
        _lastHapticRoutingMode = nil,
        _lastSlotHapticClass = nil,
        _routingDirty = true,
    }, HapticFeedbackManager)

    if enhancer ~= nil then
        instance:bindEnhancer(enhancer)
    end

    return instance
end

function HapticFeedbackManager:bindEnhancer(enhancer)
    if type(enhancer) ~= "table" then
        return false
    end

    self.enhancer = enhancer
    self.environment = enhancer.environment
    self.gestureTracker = enhancer.gestureTracker
    self.triggerFireAction = resolve_trigger_fire_action(enhancer)

    local trigger_right = self.gestureTracker and self.gestureTracker.triggerRight or nil
    local haptics_module = self.environment and self.environment.haptics or nil
    if trigger_right ~= nil
        and trigger_right ~= self._boundTriggerGesture
        and type(haptics_module) == "table"
        and type(haptics_module.HapticsGroup) == "table"
        and type(haptics_module.HapticsGroup.new) == "function"
    then
        trigger_right.haptics = haptics_module.HapticsGroup.new()
        self._boundTriggerGesture = trigger_right
        self._routingDirty = true
    end

    return type(self.environment) == "table"
end

function HapticFeedbackManager:_resolve_group(weapon_class)
    local group_key = WEAPON_CLASS_TO_GROUP_KEY[weapon_class] or WEAPON_CLASS_TO_GROUP_KEY[DEFAULT_WEAPON_CLASS]
    local default_haptics = self.environment and self.environment.defaultHaptics or nil
    local group = nil
    if type(default_haptics) == "table" then
        group = default_haptics[group_key]
    end
    return group, group_key
end

function HapticFeedbackManager:_resolve_touch_only_group(group_key, group)
    if group == nil then
        return nil
    end

    local cached = self.touchOnlyGroups[group_key]
    if cached ~= nil then
        return cached
    end

    local haptics_module = self.environment and self.environment.haptics or nil
    if type(haptics_module) == "table"
        and type(haptics_module.HapticsGroup) == "table"
        and type(haptics_module.HapticsGroup.new) == "function"
    then
        cached = haptics_module.HapticsGroup.new(nil, nil, nil, group.touchEnter, group.touchHold, group.touchLeave)
    else
        cached = {
            enter = nil,
            hold = nil,
            leave = nil,
            touchEnter = group.touchEnter,
            touchHold = group.touchHold,
            touchLeave = group.touchLeave,
        }
    end

    self.touchOnlyGroups[group_key] = cached
    return cached
end

function HapticFeedbackManager:_publishState(group_key, routing_mode)
    local snapshot = rawget(_G, "HAPTIC_FEEDBACK_STATE")
    if type(snapshot) ~= "table" then
        snapshot = {}
        _G.HAPTIC_FEEDBACK_STATE = snapshot
    end

    snapshot.weaponId = self.currentWeaponId
    snapshot.weaponDisplayName = get_weapon_display_name(self.currentWeaponId)
        or vr_globals.getCurrentWeaponDisplayName()
    snapshot.weaponClass = self.currentWeaponClass
    snapshot.groupKey = group_key
    snapshot.weaponSource = self.currentWeaponSource
    snapshot.classSource = self.currentClassSource
    snapshot.routing = routing_mode
    snapshot.hapticRoutingMode = get_haptic_routing_mode()
    -- 【槽位路由】诊断快照：RE_09 写入的 last_slot_haptic_class
    snapshot.lastSlotHapticClass = rawget(_G, vr_globals.KEYS.last_slot_haptic_class)
end

function HapticFeedbackManager:syncCurrentWeapon()
    if not self:bindEnhancer(self.enhancer) then
        return false
    end

    local routing_mode = get_haptic_routing_mode()
    if self._lastHapticRoutingMode ~= routing_mode then
        self._lastHapticRoutingMode = routing_mode
        self._routingDirty = true
    end

    local weapon_id
    local weapon_source
    local weapon_class
    local class_source

    -- -------------------------------------------------------------------------
    -- 【槽位路由 · mode == 1】
    -- -------------------------------------------------------------------------
    -- 震动类别来自 RE_09 切枪手势写入的 __vr_last_slot_haptic_class
    -- （holsterWeaponRight.grip → Pistol，shoulderWeaponRight.grip → Shotgun …）
    -- 不经过 WEAPON_ID_TO_CLASS；weapon_id 仅作诊断展示（读全局缓存）。
    -- -------------------------------------------------------------------------
    if routing_mode == 1 then
        local slot_class = rawget(_G, vr_globals.KEYS.last_slot_haptic_class)
        if type(slot_class) == "string" and slot_class ~= "" then
            weapon_class = slot_class
            class_source = "slot"
        else
            weapon_class = DEFAULT_WEAPON_CLASS
            class_source = "slot_default"
        end
        weapon_id = vr_globals.getWeaponId()
        weapon_source = "slot_routing"

        if self._lastSlotHapticClass ~= slot_class then
            self._lastSlotHapticClass = slot_class
            self._routingDirty = true
        end
    else
        -- ---------------------------------------------------------------------
        -- 【武器ID路由 · mode == 0】
        -- ---------------------------------------------------------------------
        -- read_current_weapon_id → weapon_probe → resolve_weapon_class
        -- → WEAPON_ID_TO_CLASS 决定 weapon_class。
        -- ---------------------------------------------------------------------
        weapon_id, weapon_source = read_current_weapon_id()
        weapon_class, class_source = resolve_weapon_class(weapon_id)
    end

    if self.currentWeaponId ~= weapon_id
        or self.currentWeaponClass ~= weapon_class
        or self.currentWeaponSource ~= weapon_source
        or self.currentClassSource ~= class_source
    then
        self._routingDirty = true
    end

    self.currentWeaponId = weapon_id
    self.currentWeaponClass = weapon_class
    self.currentWeaponSource = weapon_source
    self.currentClassSource = class_source
    return true
end

function HapticFeedbackManager:_apply_group(group, group_key, routing_mode, target_action)
    if not self:bindEnhancer(self.enhancer) then
        return false
    end

    target_action = target_action or self.triggerFireAction

    local should_apply = self._routingDirty
        or self.currentGroupKey ~= group_key
        or self._lastRoutingMode ~= routing_mode
        or (target_action ~= nil and target_action.haptics ~= group)

    if target_action ~= nil and should_apply then
        target_action.haptics = group
    end

    self.currentGroupKey = group_key
    self._lastRoutingMode = routing_mode
    self._routingDirty = false

    if should_apply then
        self:_publishState(group_key, routing_mode)
    end

    return true
end

function HapticFeedbackManager:applyTouchOnlyGroup()
    if self.currentWeaponClass == nil and not self:syncCurrentWeapon() then
        return false
    end

    local group, group_key = self:_resolve_group(self.currentWeaponClass)
    local touch_only_group = self:_resolve_touch_only_group(group_key, group)
    return self:_apply_group(touch_only_group, group_key, "touch")
end

function HapticFeedbackManager:applyHapticFeedbackGroup()
    -- syncCurrentWeapon 已按路由模式归一 currentWeaponClass；此处选组并绑到扳机动作。
    if self.currentWeaponClass == nil and not self:syncCurrentWeapon() then
        return false
    end

    local group, group_key = self:_resolve_group(self.currentWeaponClass)
    self.activeFireGroup = group

    local routing_mode = get_haptic_routing_mode()
    if routing_mode == 1 then
        -- 槽位路由：完整组绑 triggerRight，右扳机 enter 播背心后坐力（同旧 RE_10_Bhaptics）
        return self:_apply_group(group, group_key, "haptic_feedback")
    end

    -- 武器ID路由：扳机仅 touch；背心后坐力由 execFire → triggerFireHaptics
    local touch_only_group = self:_resolve_touch_only_group(group_key, group)
    return self:_apply_group(touch_only_group, group_key, "haptic_feedback")
end

function HapticFeedbackManager:_play_group_pattern(gesture_name, group)
    if group == nil then
        return false
    end

    local pattern = group.enter or group.hold
    if pattern == nil then
        return false
    end

    local phase_name = group.enter ~= nil and "enter" or "hold"
    local haptic_player = self.environment and self.environment.hapticPlayer or nil
    if haptic_player == nil or type(haptic_player.play_registered) ~= "function" then
        return false
    end

    return haptic_player:play_registered(gesture_name, pattern, phase_name) == true
end

-- 武器ID路由专用：由 execFire hook 调用；槽位路由走 triggerRight 手势 enter。
function HapticFeedbackManager:triggerFireHaptics()
    sync_enabled_from_haptics_driver()
    if hapticFeedback.enabled == false then
        return false
    end

    if get_haptic_routing_mode() ~= 0 then
        return false
    end

    if not self:syncCurrentWeapon() then
        return false
    end

    if not self:applyHapticFeedbackGroup() then
        return false
    end

    local group = self.activeFireGroup
    if group == nil then
        group = get_haptics_from_action(self.triggerFireAction)
    end

    local gesture_name = "triggerRight"
    local trigger_right = self.gestureTracker and self.gestureTracker.triggerRight or nil
    if trigger_right ~= nil and trigger_right.name ~= nil then
        gesture_name = trigger_right.name
    end

    return self:_play_group_pattern(gesture_name, group)
end

function HapticFeedbackManager:update()
    if not self:syncCurrentWeapon() then
        return false
    end

    if hapticFeedback.enabled == false then
        return self:applyTouchOnlyGroup()
    end
    return self:applyHapticFeedbackGroup()
end

function HapticFeedbackManager:getSnapshot()
    return {
        weaponId = self.currentWeaponId,
        weaponDisplayName = get_weapon_display_name(self.currentWeaponId)
            or vr_globals.getCurrentWeaponDisplayName(),
        weaponClass = self.currentWeaponClass,
        groupKey = self.currentGroupKey,
        weaponSource = self.currentWeaponSource,
        classSource = self.currentClassSource,
    }
end

function hapticFeedback.ensureInstalled(enhancer)
    if type(enhancer) ~= "table" then
        return nil
    end

    local manager = enhancer.hapticFeedbackManager
    if type(manager) ~= "table"
        or type(manager.bindEnhancer) ~= "function"
        or type(manager.update) ~= "function"
    then
        manager = HapticFeedbackManager.new(enhancer)
        enhancer.hapticFeedbackManager = manager
    else
        manager:bindEnhancer(enhancer)
    end

    if not init_in_progress then
        hapticFeedback.init("ensureInstalled")
    end

    manager:syncCurrentWeapon()
    if hapticFeedback.enabled == false then
        manager:applyTouchOnlyGroup()
    else
        manager:applyHapticFeedbackGroup()
    end
    enhancer.hapticFeedbackEnabled = hapticFeedback.enabled
    if enhancer.environment ~= nil and type(enhancer.environment.setHapticFeedbackEnabled) == "function" then
        enhancer.environment:setHapticFeedbackEnabled(hapticFeedback.enabled)
    end
    return manager
end

function hapticFeedback.getEnabled()
    if type(haptics_driver.get_haptics_config) == "function" then
        local cfg = haptics_driver.get_haptics_config()
        if type(cfg) == "table" then
            hapticFeedback.enabled = cfg.enabled == true
            _G.VR_HAPTIC_FEEDBACK_ENABLED = hapticFeedback.enabled
        end
    end
    return hapticFeedback.enabled ~= false
end

function hapticFeedback.setEnabled(enabled, enhancer)
    if type(haptics_driver.set_haptics_enabled) == "function" then
        haptics_driver.set_haptics_enabled(enabled)
    else
        hapticFeedback.enabled = enabled ~= false
        _G.VR_HAPTIC_FEEDBACK_ENABLED = hapticFeedback.enabled
    end
    sync_enabled_from_haptics_driver()

    local target_enhancer = enhancer
    if type(target_enhancer) ~= "table" then
        target_enhancer = get_enhancer_global()
    end

    if type(target_enhancer) == "table" then
        target_enhancer.hapticFeedbackEnabled = hapticFeedback.enabled
        local manager = hapticFeedback.ensureInstalled(target_enhancer)
        if type(manager) == "table" then
            manager:syncCurrentWeapon()
            if hapticFeedback.enabled == false then
                manager:applyTouchOnlyGroup()
            else
                manager:applyHapticFeedbackGroup()
            end
        end
    end

    return hapticFeedback.enabled
end

function hapticFeedback.getState()
    local snapshot = rawget(_G, "HAPTIC_FEEDBACK_STATE")
    if type(snapshot) ~= "table" then
        return nil
    end

    return {
        weaponId = snapshot.weaponId,
        weaponDisplayName = snapshot.weaponDisplayName,
        weaponClass = snapshot.weaponClass,
        groupKey = snapshot.groupKey,
        weaponSource = snapshot.weaponSource,
        classSource = snapshot.classSource,
        hapticRoutingMode = snapshot.hapticRoutingMode,
        lastSlotHapticClass = snapshot.lastSlotHapticClass,
    }
end

hapticFeedback.HapticFeedbackManager = HapticFeedbackManager
hapticFeedback.DEFAULT_WEAPON_CLASS = DEFAULT_WEAPON_CLASS
hapticFeedback.WEAPON_CLASS_TO_GROUP_KEY = WEAPON_CLASS_TO_GROUP_KEY
hapticFeedback.WEAPON_ID_TO_CLASS = WEAPON_ID_TO_CLASS
hapticFeedback.LEON_GRENADE_WEAPONS = LEON_GRENADE_WEAPONS
hapticFeedback.WEAPON_DISPLAY_NAMES = WEAPON_DISPLAY_NAMES
hapticFeedback.normalizeWeaponId = normalize_weapon_id
hapticFeedback.resolveWeaponIdFromValue = resolve_weapon_id_from_value
hapticFeedback.ensureWeaponInfoCache = ensure_weapon_info_cache
hapticFeedback.getWeaponInfo = get_weapon_info
hapticFeedback.getWeaponDisplayName = get_weapon_display_name
hapticFeedback.readEquippedWeaponId = read_equipped_weapon_id
hapticFeedback.publishCurrentWeapon = publish_current_weapon
hapticFeedback.isLeonGrenadeWeaponName = is_leon_grenade_weapon_name
hapticFeedback.syncLeonGrenade = sync_leon_grenade
hapticFeedback.isLeonGrenadeEquipped = is_leon_grenade_equipped
hapticFeedback.isManualThrowAllowedForCurrentWeapon = is_manual_throw_allowed_for_current_weapon
hapticFeedback.readCurrentWeaponId = read_current_weapon_id
hapticFeedback.resolveWeaponClass = resolve_weapon_class
hapticFeedback.weaponProbe = weapon_probe
hapticFeedback.weaponProbeTick = weapon_probe_tick
hapticFeedback.new = HapticFeedbackManager.new
hapticFeedback.hapticsDriver = haptics_driver

package.loaded[module_name] = hapticFeedback
_G.HAPTIC_FEEDBACK = hapticFeedback

-- Installed only via RE_08.installHapticFeedbackManager / ensureInstalled (no autorun self-bootstrap).

return hapticFeedback
