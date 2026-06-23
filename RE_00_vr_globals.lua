local module_name = "RE_00_vr_globals"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_00_vr_globals.lua
-- RE7：VR 运行时全局状态的只读访问层。
--
-- Consumers:
--   RE_09_Immersion_Enhancer_RE7.lua  -> KEYS.weapon_slot_*, KEYS.last_slot_haptic_class
--   RE_10_HapticFeedback.lua          -> KEYS.current_weapon_*, haptic_routing_mode, leon_grenade, pullpin_active
--   RE_12_diagnose.lua                -> getWeaponId, getHapticRoutingMode, isPullpinActive, ...
--
-- Publishers:
--   re8_vr.lua                        -> g_is_two_handing_weapon, g_is_heal_active
--   RE_09_Immersion_Enhancer_RE7.lua  -> pullpin_active, __vr_weapon_slot_*, __vr_last_slot_haptic_class
--   RE_04_input.lua                   -> resetRuntimeGlobals()（输入通道重启时调用）
--   RE_10_HapticFeedback.lua          -> __vr_current_weapon_*, leon_grenade

local KEYS = {
    current_weapon_id = "__vr_current_weapon_id",
    current_weapon_display_name = "__vr_current_weapon_display_name",
    haptic_routing_mode = "__vr_haptic_routing_mode",
    last_slot_haptic_class = "__vr_last_slot_haptic_class",
    weapon_slot_region = "__vr_weapon_slot_region",
    weapon_slot_binding = "__vr_weapon_slot_binding",
    weapon_slot_key = "__vr_weapon_slot_key",
    weapon_slot_source = "__vr_weapon_slot_source",
    weapon_slot_at = "__vr_weapon_slot_at",
    two_handing_weapon = "g_is_two_handing_weapon",
    heal_active = "g_is_heal_active",
    pullpin_active = "pullpin_active",
    aim_pistol_active = "g_is_aim_pistol_active",
    leon_grenade = "leon_grenade",
}

local function ensure_bool_default(key)
    if rawget(_G, key) == nil then
        _G[key] = false
    end
end

local function ensure_global_default(key, default_value)
    if rawget(_G, key) == nil then
        _G[key] = default_value
    end
end

ensure_global_default(KEYS.current_weapon_id, "")
ensure_global_default(KEYS.current_weapon_display_name, "")
-- =============================================================================
-- 【HAPTIC_ROUTING_MODE】武器震动路由模式
-- =============================================================================
-- 选择武器体感震动的分类方式：
--   0 = 按武器ID分类（从游戏内存读取武器ID，查表 WEAPON_ID_TO_CLASS）
--   1 = 按武器槽位分类（从 RE_09 手势槽位获取，如 holsterWeaponRight.grip -> Pistol）
--
-- 修改此值后重启游戏或重新加载脚本生效。
-- =============================================================================
ensure_global_default(KEYS.haptic_routing_mode, 1)
ensure_global_default(KEYS.last_slot_haptic_class, "Pistol")
ensure_global_default(KEYS.weapon_slot_region, "none")
ensure_global_default(KEYS.weapon_slot_binding, "none")
ensure_global_default(KEYS.weapon_slot_key, "none")
ensure_global_default(KEYS.weapon_slot_source, "none")
ensure_global_default(KEYS.weapon_slot_at, 0.0)

ensure_bool_default(KEYS.two_handing_weapon)
ensure_bool_default(KEYS.heal_active)
ensure_bool_default(KEYS.pullpin_active)
ensure_bool_default(KEYS.aim_pistol_active)

-- 输入通道 reset 时只清瞬态 motion/输入标志；武器 ID、槽位、震动路由等上下文保留。
local RUNTIME_RESET_DEFAULTS = {
    [KEYS.two_handing_weapon] = false,
    [KEYS.heal_active] = false,
    [KEYS.pullpin_active] = false,
    [KEYS.aim_pistol_active] = false,
}

local vr_globals = {
    KEYS = KEYS,
}

function vr_globals.resetRuntimeGlobals()
    for key, default_value in pairs(RUNTIME_RESET_DEFAULTS) do
        _G[key] = default_value
    end
end

function vr_globals.getWeaponId()
    local weapon_id = rawget(_G, KEYS.current_weapon_id)
    if type(weapon_id) == "string" and weapon_id ~= "" then
        return weapon_id
    end
    return nil
end

function vr_globals.getCurrentWeaponDisplayName()
    local display_name = rawget(_G, KEYS.current_weapon_display_name)
    if type(display_name) == "string" and display_name ~= "" then
        return display_name
    end
    return nil
end

function vr_globals.getHapticRoutingMode()
    return tonumber(rawget(_G, KEYS.haptic_routing_mode)) or 0
end

function vr_globals.getLastSlotHapticClass()
    return rawget(_G, KEYS.last_slot_haptic_class)
end

function vr_globals.getLastWeaponSlotEvent()
    return {
        region = rawget(_G, KEYS.weapon_slot_region),
        binding = rawget(_G, KEYS.weapon_slot_binding),
        key = rawget(_G, KEYS.weapon_slot_key),
        source = rawget(_G, KEYS.weapon_slot_source),
        at = rawget(_G, KEYS.weapon_slot_at),
    }
end

function vr_globals.isTwoHandingWeapon()
    return rawget(_G, KEYS.two_handing_weapon) == true
end

function vr_globals.isHealActive()
    return rawget(_G, KEYS.heal_active) == true
end

function vr_globals.isMotionPaused()
    return rawget(_G, KEYS.motion_paused) == true
end

function vr_globals.isPullpinActive()
    return rawget(_G, KEYS.pullpin_active) == true
end

function vr_globals.isAimPistolActive()
    return rawget(_G, KEYS.aim_pistol_active) == true
end

package.loaded[module_name] = vr_globals

return vr_globals
