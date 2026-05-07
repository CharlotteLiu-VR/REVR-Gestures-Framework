local module_name = "RE_01_numerics"
if package.loaded[module_name] ~= nil then
    return package.loaded[module_name]
end

-- RE_01_numerics.lua
-- Shared math helpers for vectors, angles, motion metrics, and pose transforms.
local numerics = {}

local math_abs = math.abs
local math_asin = math.asin
local math_atan = math.atan
local math_cos = math.cos
local math_max = math.max
local math_min = math.min
local math_pi = math.pi
local math_sin = math.sin
local math_sqrt = math.sqrt

local EPSILON = 1e-6

local function raw_vec3(x, y, z)
    return { x = x or 0.0, y = y or 0.0, z = z or 0.0 }
end

numerics.shared = {
    epsilon = EPSILON,
    zero = raw_vec3(0.0, 0.0, 0.0),
    temp = {
        vector_a = raw_vec3(0.0, 0.0, 0.0),
        vector_b = raw_vec3(0.0, 0.0, 0.0),
        head_basis = { fx = 0.0, fz = 1.0, lx = 1.0, lz = 0.0, rx = -1.0, rz = 0.0 },
        left_metrics = {},
        right_metrics = {},
        relative_metrics = {},
    },
}

function numerics.clamp(value, lower, upper)
    if value < lower then
        return lower
    end
    if value > upper then
        return upper
    end
    return value
end

function numerics.wrap_angle(angle)
    if angle > math_pi then
        return angle - math_pi * 2.0
    end
    if angle < -math_pi then
        return angle + math_pi * 2.0
    end
    return angle
end

function numerics.new_vector(x, y, z)
    return raw_vec3(x, y, z)
end

function numerics.set_vector(out, x, y, z)
    out.x = x or 0.0
    out.y = y or 0.0
    out.z = z or 0.0
    return out
end

function numerics.copy_vector(out, source)
    if source == nil then
        return numerics.set_vector(out, 0.0, 0.0, 0.0)
    end
    return numerics.set_vector(out, source.x, source.y, source.z)
end

function numerics.subtract(out, left, right)
    return numerics.set_vector(out, left.x - right.x, left.y - right.y, left.z - right.z)
end

function numerics.add(out, left, right)
    return numerics.set_vector(out, left.x + right.x, left.y + right.y, left.z + right.z)
end

function numerics.scale(out, vector, scalar)
    return numerics.set_vector(out, vector.x * scalar, vector.y * scalar, vector.z * scalar)
end

function numerics.dot_product(left, right)
    return (left.x * right.x) + (left.y * right.y) + (left.z * right.z)
end

function numerics.length_squared(vector)
    return (vector.x * vector.x) + (vector.y * vector.y) + (vector.z * vector.z)
end

function numerics.length(vector)
    return math_sqrt(numerics.length_squared(vector))
end

function numerics.distance_squared(left, right)
    local dx = left.x - right.x
    local dy = left.y - right.y
    local dz = left.z - right.z
    return (dx * dx) + (dy * dy) + (dz * dz)
end

function numerics.normalize_xz(x, z)
    local magnitude = math_sqrt((x * x) + (z * z))
    if magnitude < EPSILON then
        return 0.0, 1.0, 1.0
    end
    return x / magnitude, z / magnitude, magnitude
end

function numerics.rotate_yaw(out, vector, angle)
    local s = math_sin(angle)
    local c = math_cos(angle)
    return numerics.set_vector(out, (c * vector.x) - (s * vector.z), vector.y, (s * vector.x) + (c * vector.z))
end

function numerics.get_yaw_pitch(pose)
    local yaw = math_atan(pose.left.z, pose.left.x)
    local pitch = math_asin(numerics.clamp(pose.forward.y, -1.0, 1.0))
    return yaw, pitch
end

function numerics.get_yaw_pitch_roll(pose)
    local yaw = math_atan(pose.forward.z, pose.forward.x)
    local pitch = math_asin(numerics.clamp(pose.forward.y, -1.0, 1.0))
    local plane_right_x = math_sin(yaw)
    local plane_right_z = -math_cos(yaw)
    local roll = math_asin(numerics.clamp((pose.up.x * plane_right_x) + (pose.up.z * plane_right_z), -1.0, 1.0))
    yaw = math_atan(pose.left.z, pose.left.x)
    return yaw, pitch, roll
end

function numerics.get_roll(pose)
    local yaw = math_atan(pose.forward.z, pose.forward.x)
    local plane_right_x = math_sin(yaw)
    local plane_right_z = -math_cos(yaw)
    return math_asin(numerics.clamp((pose.up.x * plane_right_x) + (pose.up.z * plane_right_z), -1.0, 1.0))
end

function numerics.compute_head_basis(head_pose, out)
    out = out or numerics.shared.temp.head_basis
    local fx, fz = numerics.normalize_xz(head_pose.forward.x or 0.0, head_pose.forward.z or 0.0)
    local lx, lz = numerics.normalize_xz(head_pose.left.x or 1.0, head_pose.left.z or 0.0)
    out.fx = fx
    out.fz = fz
    out.lx = lx
    out.lz = lz
    out.rx = -lx
    out.rz = -lz
    return out
end

function numerics.compute_motion_metrics(pose, previous_position, delta_time, basis, out, vertical_threshold)
    out = out or {}
    local safe_delta = delta_time or 0.0
    if safe_delta < EPSILON then
        safe_delta = EPSILON
    end

    local dwx = ((pose.position.x or 0.0) - (previous_position.x or 0.0)) / safe_delta
    local dy = ((pose.position.y or 0.0) - (previous_position.y or 0.0)) / safe_delta
    local dwz = ((pose.position.z or 0.0) - (previous_position.z or 0.0)) / safe_delta
    local dx = (dwx * basis.rx) + (dwz * basis.rz)
    local dz = (dwx * basis.fx) + (dwz * basis.fz)
    local distance2 = (dwx * dwx) + (dy * dy) + (dwz * dwz)

    out.dwx = dwx
    out.dy = dy
    out.dwz = dwz
    out.dx = dx
    out.dz = dz
    out.distance2 = distance2
    out.speed = math_sqrt(distance2)
    out.speed_xz = math_sqrt((dx * dx) + (dz * dz))
    out.is_horizontal = math_abs(pose.forward.y or 0.0) < 0.5
    out.is_vertical = math_abs(pose.forward.y or 0.0) > (vertical_threshold or 0.9)
    return out
end

function numerics.is_pure_axis(primary, secondary_a, secondary_b, purity)
    return math_abs(primary) > ((math_abs(secondary_a) + math_abs(secondary_b)) * purity)
end

function numerics.compute_relative_velocity(left_pose, right_pose, left_metrics, right_metrics, out)
    out = out or numerics.shared.temp.relative_metrics
    local dx = (right_pose.position.x or 0.0) - (left_pose.position.x or 0.0)
    local dy = (right_pose.position.y or 0.0) - (left_pose.position.y or 0.0)
    local dz = (right_pose.position.z or 0.0) - (left_pose.position.z or 0.0)
    local distance = math_sqrt((dx * dx) + (dy * dy) + (dz * dz))

    if distance < EPSILON then
        out.velocity = 0.0
        out.distance = 0.0
        return out
    end

    local nx = dx / distance
    local ny = dy / distance
    local nz = dz / distance

    out.nx = nx
    out.ny = ny
    out.nz = nz
    out.distance = distance
    out.velocity = ((right_metrics.dwx * nx) + (right_metrics.dy * ny) + (right_metrics.dwz * nz))
        - ((left_metrics.dwx * nx) + (left_metrics.dy * ny) + (left_metrics.dwz * nz))
    return out
end

function numerics.location_distance_squared(head_pose, offset, controller_pose)
    local gesture_y = (head_pose.position.y or 0.0) + (offset.y or 0.0)
    local gesture_x = (head_pose.position.x or 0.0)
        - ((head_pose.left.x or 0.0) * (offset.x or 0.0))
        + ((head_pose.forward.x or 0.0) * (offset.z or 0.0))
    local gesture_z = (head_pose.position.z or 0.0)
        - ((head_pose.left.z or 0.0) * (offset.x or 0.0))
        + ((head_pose.forward.z or 0.0) * (offset.z or 0.0))
    local dx = (controller_pose.position.x or 0.0) - gesture_x
    local dy = (controller_pose.position.y or 0.0) - gesture_y
    local dz = (controller_pose.position.z or 0.0) - gesture_z
    return (dx * dx) + (dy * dy) + (dz * dz)
end

function numerics.forward_offset_distance_squared(source_pose, target_pose, distance, invert)
    local direction = invert and 1.0 or -1.0
    local target_x = (source_pose.position.x or 0.0) + ((source_pose.forward.x or 0.0) * distance * direction)
    local target_y = (source_pose.position.y or 0.0) + ((source_pose.forward.y or 0.0) * distance * direction)
    local target_z = (source_pose.position.z or 0.0) + ((source_pose.forward.z or 0.0) * distance * direction)
    local dx = (target_pose.position.x or 0.0) - target_x
    local dy = (target_pose.position.y or 0.0) - target_y
    local dz = (target_pose.position.z or 0.0) - target_z
    return (dx * dx) + (dy * dy) + (dz * dz)
end

function numerics.quaternion_to_axes(quaternion, out)
    out = out or {}
    local w = quaternion.w or quaternion[1] or 1.0
    local x = quaternion.x or quaternion[2] or 0.0
    local y = quaternion.y or quaternion[3] or 0.0
    local z = quaternion.z or quaternion[4] or 0.0

    out.forward = out.forward or raw_vec3(0.0, 0.0, 1.0)
    out.left = out.left or raw_vec3(-1.0, 0.0, 0.0)
    out.up = out.up or raw_vec3(0.0, 1.0, 0.0)

    out.forward.x = 2.0 * ((x * z) + (w * y))
    out.forward.y = 2.0 * ((y * z) - (w * x))
    out.forward.z = 1.0 - (2.0 * ((x * x) + (y * y)))

    local right_x = 1.0 - (2.0 * ((y * y) + (z * z)))
    local right_y = 2.0 * ((x * y) + (w * z))
    local right_z = 2.0 * ((x * z) - (w * y))

    out.left.x = -right_x
    out.left.y = -right_y
    out.left.z = -right_z

    out.up.x = 2.0 * ((x * y) - (w * z))
    out.up.y = 1.0 - (2.0 * ((x * x) + (z * z)))
    out.up.z = 2.0 * ((y * z) + (w * x))

    return out
end

_G.RE9Numerics = numerics

package.loaded[module_name] = numerics

return numerics