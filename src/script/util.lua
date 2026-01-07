---@param entity LuaEntity The entity to check.
---@return boolean # `true` if the entity is a train carriage, `false` otherwise.
local function is_entity_carriage(entity)
    if not (entity and entity.valid) then return false end
    if not entity.train then return false end
    if entity.type == "locomotive" or entity.type:sub(-6) == "-wagon" then
        return true
    else
        return false
    end
end

local function get_carriage_connected_side(carriage1, carriage2)
    if not (carriage1 and carriage1.valid) then return nil end
    if not (carriage2 and carriage2.valid) then return nil end
    local train1 = carriage1.train
    local train2 = carriage2.train
    if not (train1 and train1.valid) then return nil end
    if not (train2 and train2.valid) then return nil end
    if train1 ~= train2 then return nil end -- If they're not on the same train, they can't be connected
    local carriages = train1.carriages
    for i = 1, #carriages do
        if carriages[i] == carriage1 then
            if carriages[i+1] and carriages[i+1].unit_number == carriage2.unit_number then
                return "front"
            elseif carriages[i-1] and carriages[i-1].unit_number == carriage2.unit_number then
                return "back"
            else
                return nil
            end
        end
    end
    return nil
end

---Checks if two carriages are connected.
---@param carriage1 LuaEntity The first carriage entity.
---@param carriage2 LuaEntity The second carriage entity.
---@return boolean # `true` if the carriages are connected, `false` otherwise.
local function are_carriages_connected(carriage1, carriage2)
    if not (carriage1 and carriage1.valid) then return false end
    if not (carriage2 and carriage2.valid) then return false end
    local back_carriage = carriage1.get_connected_rolling_stock(defines.rail_direction.back)
    if back_carriage and back_carriage.valid and back_carriage.unit_number == carriage2.unit_number then
        return true
    end
    local front_carriage = carriage1.get_connected_rolling_stock(defines.rail_direction.front)
    if front_carriage and front_carriage.valid and front_carriage.unit_number == carriage2.unit_number then
        return true
    end
    return false
end

---Calculates the back center point of box1 relative to box2 based on orientation
---@param box1 BoundingBox The first bounding box.
---@param box2 BoundingBox The second bounding box.
---@param orientation number The orientation (0 to 1) representing rotation.
---@return Vector # The calculated back center position.
local function calculate_back_center(box1, box2, orientation)
    -- Determine the bounds of the first bounding box
    local box1_x = (box1.left_top.x + box1.right_bottom.x) / 2
    local box1_y = (box1.left_top.y + box1.right_bottom.y) / 2
    local box1_width = box1.right_bottom.x - box1.left_top.x
    local box1_height = box1.right_bottom.y - box1.left_top.y

    -- Determine the width/height of the second bounding box
    local box2_width = box2.right_bottom.x - box2.left_top.x
    local box2_height = box2.right_bottom.y - box2.left_top.y

    -- Determine the half-size of each bounding box
    local box1_length = math.max(box1_width, box1_height) / 2
    local box2_length = math.max(box2_width, box2_height) / 2

    -- Base direction
    local fx = 0
    local fy = 1

    -- Apply the orientation as a rotation to the direction vector
    local angle = orientation * 2 * math.pi
    local cos_angle = math.cos(angle)
    local sin_angle = math.sin(angle)
    local relative_fx = fx * cos_angle - fy * sin_angle
    local relative_fy = fx * sin_angle + fy * cos_angle

    -- Calculate the back center point of box1 relative to box2
    local back_center_x = box1_x - relative_fx * (box1_length + box2_length)
    local back_center_y = box1_y - relative_fy * (box1_length + box2_length)
    return {
        x = back_center_x,
        y = back_center_y
    }
end

---Flips a back_center point into the corresponding front_center.
---@param box1 BoundingBox
---@param back_center Vector
---@return Vector
local function flip_to_front_center(box1, back_center)
    local box1_x = (box1.left_top.x + box1.right_bottom.x) / 2
    local box1_y = (box1.left_top.y + box1.right_bottom.y) / 2
    return {
        x = 2 * box1_x - back_center.x,
        y = 2 * box1_y - back_center.y
    }
end

---Finds the nearest couplers around a position on a surface.
---@param surface LuaSurface The surface to search on.
---@param position MapPosition The position to search around.
---@param radius number The search radius.
---@return LuaEntity[] # An array of found coupler entities.
local function find_nearest_couplers(surface, position, radius)
    local couplers = surface.find_entities_filtered{
        surface = surface,
        position = position,
        radius = radius,
        name = "ftrainworks-coupler"
    }
    return couplers
end

---Finds the nearest inserters around a position on a surface.
---@param surface LuaSurface The surface to search on.
---@param position MapPosition The position to search around.
---@param radius number The search radius.
---@return LuaEntity[] # An array of found inserter entities.
local function find_nearest_inserters(surface, position, radius)
    local inserters = surface.find_entities_filtered{
        surface = surface,
        position = position,
        radius = radius,
        name = "ftrainworks-coupler-inserter"
    }
    return inserters
end

---Finds the nearest carriages around a position on a surface.
---@param surface LuaSurface The surface to search on.
---@param position MapPosition The position to search around.
---@param radius number The search radius.
---@return LuaEntity[] # An array of found carriage entities.
local function find_nearest_carriages(surface, position, radius)
    local carriages = surface.find_entities_filtered{
        surface = surface,
        position = position,
        radius = radius,
        type = { "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon" }
    }
    return carriages
end

---Connects or disconnects carriages near a position on a surface.
---@param carriage1 LuaEntity The first carriage entity.
---@param carriage2 LuaEntity The second carriage entity.
---@param surface LuaSurface The surface where the operation takes place.
---@param position MapPosition The position to check for carriages.
---@param desired_state string "connect" to connect, "disconnect" to disconnect, or "toggle" to toggle the connection state.
local function connect_disconnect_carriages(carriage1, carriage2, surface, position, desired_state)
    if not (carriage1 and carriage1.valid) then return end
    if not (carriage2 and carriage2.valid) then return end
    local is_connected = are_carriages_connected(carriage1, carriage2)

    -- Decide whether we should disconnect based on the desired state
    local should_disconnect
    if desired_state == "toggle" then
        should_disconnect = is_connected
    else
        should_disconnect = (desired_state == "disconnect")
    end

    -- Short-circuit if no action is needed
    if should_disconnect and not is_connected then return end
    if not should_disconnect and is_connected then return end

    -- Determine if the carriage is closest to the back or front
    local back_center = calculate_back_center(carriage1.bounding_box, carriage2.bounding_box, (carriage1.orientation + 0.5) % 1)
    local front_center = flip_to_front_center(carriage1.bounding_box, back_center)
    local dist_to_back = ((position.x - back_center.x) ^ 2 + (position.y - back_center.y) ^ 2) ^ 0.5
    local dist_to_front = ((position.x - front_center.x) ^ 2 + (position.y - front_center.y) ^ 2) ^ 0.5
    local closest_side = (dist_to_back <= dist_to_front) and "back" or "front"


    -- Perform the connection change
    if should_disconnect then
        if closest_side == "front" then
            carriage1.disconnect_rolling_stock(defines.rail_direction.front)
        else
            carriage1.disconnect_rolling_stock(defines.rail_direction.back)
        end
        surface.play_sound{ path = "ftrainworks-decouple", position = position }
    else
        if closest_side == "front" then
            carriage1.connect_rolling_stock(defines.rail_direction.front)
        else
            carriage1.connect_rolling_stock(defines.rail_direction.back)
        end
        surface.play_sound{ path = "ftrainworks-couple", position = position }
    end

    -- if should_disconnect then
    --     if not is_connected then return end

    --     -- Determine if the carriage is reversed
    --     local reversed = false
    --     local carriages = carriage1.train.carriages
    --     local i = nil
    --     for index, c in ipairs(carriages) do
    --         if c.unit_number == carriage1.unit_number then
    --             i = index
    --             break
    --         end
    --     end
    --     if not i then return end

    --     -- Determine if we're flipped relative to the train's front direction
    --     local reversed = false
    --     local prev = carriages[i - 1]
    --     if prev then
    --         if carriage1.get_connected_rolling_stock(defines.rail_direction.front) == prev then
    --             reversed = true
    --         end
    --     end

    --     local side = get_carriage_connected_side(carriage1, carriage2)
    --     if side == "front" then
    --         if reversed then
    --             carriage1.disconnect_rolling_stock(defines.rail_direction.back)
    --         else
    --             carriage1.disconnect_rolling_stock(defines.rail_direction.front)
    --         end
    --     else
    --         if reversed then
    --             carriage1.disconnect_rolling_stock(defines.rail_direction.front)
    --         else
    --             carriage1.disconnect_rolling_stock(defines.rail_direction.back)
    --         end
    --     end
    --     surface.play_sound{ path = "ftrainworks-decouple", position = position }
    -- else
    --     if is_connected then return end

    --     -- If we're already connected on the front, connect on the back, and vice versa
    --     local connected = carriage1.get_connected_rolling_stock(defines.rail_direction.front)
    --     if connected then
    --         carriage1.connect_rolling_stock(defines.rail_direction.back)
    --     else
    --         carriage1.connect_rolling_stock(defines.rail_direction.front)
    --     end

    --     surface.play_sound{ path = "ftrainworks-couple", position = position }
    -- end
end

return {
    is_entity_carriage = is_entity_carriage,
    are_carriages_connected = are_carriages_connected,
    calculate_back_center = calculate_back_center,
    flip_to_front_center = flip_to_front_center,
    find_nearest_couplers = find_nearest_couplers,
    find_nearest_inserters = find_nearest_inserters,
    find_nearest_carriages = find_nearest_carriages,
    connect_disconnect_carriages = connect_disconnect_carriages
}