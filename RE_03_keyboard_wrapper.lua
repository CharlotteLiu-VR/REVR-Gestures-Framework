local module_name = "RE_03_keyboard_wrapper"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_03_keyboard_wrapper.lua
-- Reference-counted keyboard wrapper so shared key holds do not release too early.
local KeyboardWrapper = {}
KeyboardWrapper.__index = KeyboardWrapper

local function default_backend_call(_, _)
    return false
end

local function normalize_backend(backend)
    backend = backend or {}
    if backend.keyDown == nil then
        backend.keyDown = default_backend_call
    end
    if backend.keyUp == nil then
        backend.keyUp = default_backend_call
    end
    if backend.tapKey == nil then
        backend.tapKey = nil
    end
    return backend
end

function KeyboardWrapper.new(backend)
    return setmetatable({
        backend = normalize_backend(backend),
        keys = {},
    }, KeyboardWrapper)
end

function KeyboardWrapper:setBackend(backend)
    self.backend = normalize_backend(backend)
end

function KeyboardWrapper:setKeyDown(key)
    local current = self.keys[key] or 0
    if current == 0 then
        self.keys[key] = 1
        self.backend:keyDown(key)
        return true
    end

    self.keys[key] = current + 1
    return false
end

function KeyboardWrapper:setKeyUp(key)
    local current = self.keys[key]
    if current == nil or current == 0 then
        return false
    end

    if current > 1 then
        self.keys[key] = current - 1
        return false
    end

    self.keys[key] = 0
    self.backend:keyUp(key)
    return true
end

function KeyboardWrapper:setPressed(key)
    if self.backend.tapKey ~= nil then
        self.backend:tapKey(key)
        return true
    end

    self:setKeyDown(key)
    self:setKeyUp(key)
    return true
end

function KeyboardWrapper:reset()
    for key, count in pairs(self.keys) do
        if count ~= nil and count > 0 then
            self.keys[key] = 0
            self.backend:keyUp(key)
        end
    end
end

package.loaded[module_name] = KeyboardWrapper

return KeyboardWrapper