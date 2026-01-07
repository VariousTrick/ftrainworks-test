local registry = require("script.registry")
local util = require("script.util")

----------------------------
-- USED STORAGE VARIABLES --
----------------------------
-- storage.sensors: Table of all sensor entities indexed by unit number.
----------------------------

---@alias ActiveSensorData {train:LuaTrain, carriage:LuaEntity, sensor:LuaEntity}
local active_sensors = {} ---@type table<uint64, ActiveSensorData> -- All active sensors with detected carriages indexed by sensor unit number.

--[[
    Data storage functions.
--]]

---Creates the data structure for a sensor in storage.
---Does not perform any validation.
---@param sensor_unit_number uint64 The sensor entity unit number.
local function create_sensor_data(sensor_unit_number)
    storage.sensors = storage.sensors or {}
    table.insert(storage.sensors, sensor_unit_number)
end

---Validates that the data structure for a sensor exists in storage.
---If it does not exist, it is created.
---@param sensor_unit_number uint64 The sensor entity unit number.
local function validate_sensor_data(sensor_unit_number)
    storage.sensors = storage.sensors or {}
    for _, unit_number in ipairs(storage.sensors) do
        if unit_number == sensor_unit_number then
            return
        end
    end
    create_sensor_data(sensor_unit_number)
end

---Removes the data structure for a sensor from storage.
---Does not perform any validation.
---@param sensor_unit_number uint64 The sensor entity unit number.
local function remove_sensor_data(sensor_unit_number)
    if not storage.sensors then return end
    for index, unit_number in ipairs(storage.sensors) do
        if unit_number == sensor_unit_number then
            table.remove(storage.sensors, index)
            return
        end
    end
end

--[[
    Sensor functions.
--]]

---Activates sensors for a train by checking which sensors are near its carriages.
---@param train LuaTrain The train to check for nearby sensors.
local function activate_sensors(train)
    for _, carriage in pairs(train.carriages) do
        local box = carriage.selection_box
        local search_area = {
            { box.left_top.x - 1, box.left_top.y },
            { box.right_bottom.x + 1, box.right_bottom.y }
        }
        local nearby_sensors = carriage.surface.find_entities_filtered{
            area = search_area,
            name = "ftrainworks-sensor"
        }
        for _, sensor in pairs(nearby_sensors) do
            validate_sensor_data(sensor.unit_number)
            active_sensors[sensor.unit_number] = {
                train = train,
                carriage = carriage,
                sensor = sensor
            }
        end
    end
end

---Deactivates a sensor.
---@param sensor_unit_number uint64 The sensor entity unit number.
---@param sensor LuaEntity The sensor entity.
local function deactivate_sensor(sensor_unit_number, sensor)
    active_sensors[sensor_unit_number] = nil
    if sensor.valid then
        -- Reset the control behavior
        local control_behavior = sensor.get_or_create_control_behavior() ---@type LuaConstantCombinatorControlBehavior
        if not (control_behavior and control_behavior.valid) then return end
        if not control_behavior.enabled then control_behavior.enabled = true end
        local section = control_behavior.get_section(1)
        if not (section and section.is_manual) then return end -- TODO: Can we fix this in code?
        if not section.active then section.active = true end

        -- Clear all filters
        if #section.filters > 0 then
            section.filters = {}
        end
    end
end

---@param sensor_unit_number uint64 The sensor entity unit number.
---@param active_sensor_data ActiveSensorData The active sensor data.
local function sensor_report(sensor_unit_number, active_sensor_data)
    -- Validate sensor
    local sensor = active_sensor_data.sensor
    if not (sensor and sensor.valid) then
        remove_sensor_data(sensor_unit_number)
        deactivate_sensor(sensor_unit_number, sensor)
        return
    end

    -- Validate carriage
    local carriage = active_sensor_data.carriage
    if not (carriage and carriage.valid) then
        deactivate_sensor(sensor_unit_number, sensor)
        return
    end

    -- Validate train
    local train = carriage.train
    if not (train and train.valid) then
        -- Invalid state? Can a carriage exist without a train?
        deactivate_sensor(sensor_unit_number, sensor)
        return
    end
    if train.speed ~= 0 then
        -- Train is moving; deactivate sensor.
        deactivate_sensor(sensor_unit_number, sensor)
        return
    end
    if train.id ~= train.id then
        -- Carriage is no longer part of the same train; update sensor data.
        active_sensor_data.train = train
        active_sensors[sensor_unit_number] = active_sensor_data
    end

    -- Fetch the control behavior
    local control_behavior = sensor.get_or_create_control_behavior() ---@type LuaConstantCombinatorControlBehavior
    if not (control_behavior and control_behavior.valid) then return end
    if not control_behavior.enabled then control_behavior.enabled = true end
    local section = control_behavior.get_section(1)
    if not (section and section.is_manual) then return end -- TODO: Can we fix this in code?
    if not section.active then section.active = true end

    -- If the description says to do nothing, then exit
    local read_type = string.find(sensor.combinator_description, "read-type", 1, true) ~= nil
    local read_contents = string.find(sensor.combinator_description, "read-contents", 1, true) ~= nil
    local read_fuel = string.find(sensor.combinator_description, "read-fuel", 1, true) ~= nil
    if not (read_type or read_contents or read_fuel) then
        if #section.filters > 0 then
            section.filters = {}
        end
        return
    end

    -- Depending on configuration, set filters and emit signals
    local filters = {}
    if carriage.type == "cargo-wagon" then
        if read_type then
            -- Emit carriage type signal
            table.insert(filters, {
                value = { type = "item", name = carriage.name, quality = "normal" },
                min = 1,
                max = 1
            })
        end
        if read_contents then
            -- Read contents and emit signals
            local inventory = carriage.get_inventory(defines.inventory.cargo_wagon)
            if not (inventory and inventory.valid) then return end

            -- Loop through contents and set filters
            for _, item in pairs(inventory.get_contents()) do
                table.insert(filters, {
                    value = { type = "item", name = item.name, quality = item.quality },
                    min = item.count,
                    max = item.count
                })
            end
        end
    elseif carriage.type == "fluid-wagon" then
        if read_type then
            -- Emit carriage type signal
            table.insert(filters, {
                value = { type = "item", name = carriage.name, quality = "normal" },
                min = 1,
                max = 1
            })
        end
        if read_contents then
            -- Read contents and emit signals
            for fluid, amount in pairs(carriage.get_fluid_contents()) do
                table.insert(filters, {
                    value = { type = "fluid", name = fluid, quality = "normal" },
                    min = amount,
                    max = amount
                })
            end
        end
    elseif carriage.type == "artillery-wagon" then
        if read_type then
            -- Emit carriage type signal
            table.insert(filters, {
                value = { type = "item", name = carriage.name, quality = "normal" },
                min = 1,
                max = 1
            })
        end
        if read_contents then
            -- Read contents and emit signals
            local inventory = carriage.get_inventory(defines.inventory.artillery_wagon_ammo)
            if not (inventory and inventory.valid) then return end

            -- Loop through contents and set filters
            for _, item in pairs(inventory.get_contents()) do
                table.insert(filters, {
                    value = { type = "item", name = item.name, quality = item.quality },
                    min = item.count,
                    max = item.count
                })
            end
        end
    elseif carriage.type == "locomotive" then
        if read_type then
            -- Emit carriage type signal
            table.insert(filters, {
                value = { type = "item", name = carriage.name, quality = "normal" },
                min = 1,
                max = 1
            })
        end
        if read_fuel then
            -- Read fuel and emit signals
            local fuel_inventory = carriage.get_fuel_inventory()

            -- Fix: Support locomotives without fuel inventory (e.g. void energy sources)
            if fuel_inventory and fuel_inventory.valid then
                -- Loop through fuel contents and set filters
                for _, item in pairs(fuel_inventory.get_contents()) do
                    table.insert(filters, {
                        value = { type = "item", name = item.name, quality = item.quality },
                        min = item.count,
                        max = item.count
                    })
                end
            end
        end
    end

    -- If this filters didn't change, don't update
    local previous_filters = section.filters or {}
    local filters_changed = false
    if #filters ~= #previous_filters then
        filters_changed = true
    else
        for i = 1, #filters do
            local new_filter = filters[i]
            local old_filter = previous_filters[i]
            if not old_filter or new_filter.value.type ~= old_filter.value.type or new_filter.value.name ~= old_filter.value.name or new_filter.min ~= old_filter.min then
                filters_changed = true
                break
            end
        end
    end

    -- Emit all the filters
    if filters_changed then
        section.filters = filters
    end
end

--[[
    Sensor event handlers.
--]]

---Handler for when a sensor is built.
---@param sensor LuaEntity The sensor entity.
local function on_sensor_built(sensor)
    create_sensor_data(sensor.unit_number)

    -- Set default params
    if sensor.combinator_description == "" then
        sensor.combinator_description = " read-contents"
    end

    -- Check if a train is nearby
    local nearby_carriages = util.find_nearest_carriages(sensor.surface, sensor.position, 5)
    if not nearby_carriages then return end
    if #nearby_carriages == 0 then return end
    local closest_carriage = nearby_carriages[1]
    activate_sensors(closest_carriage.train)
end

---Handler for when a sensor is removed.
---@param sensor LuaEntity The sensor entity.
local function on_sensor_removed(sensor)
    active_sensors[sensor.unit_number] = nil
    remove_sensor_data(sensor.unit_number)
end

--[[
    Train state event handlers.
--]]

---Handler for when a train is created.
---@param train LuaTrain The train that was created.
local function on_train_created(train)
    -- When a train is created, check for nearby sensors to activate.
    activate_sensors(train)
end

---Handler for when a train's state changes.
---@param train LuaTrain The train whose state has changed.
local function on_train_state_changed(train)
    if train.speed == 0 then
        -- Train is stopped, find sensors which should be activated.
        activate_sensors(train)
    else
        -- Sensors deactivate themselves when the train starts moving.
    end
end

--[[
    Registry event handlers.
--]]

---@param event EventData.on_built_entity
registry.register(defines.events.on_built_entity, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_built(entity)
    end
end)

---@param event EventData.on_robot_built_entity
registry.register(defines.events.on_robot_built_entity, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_built(entity)
    end
end)

---@param event EventData.script_raised_built
registry.register(defines.events.script_raised_built, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_built(entity)
    end
end)

---@param event EventData.on_entity_died
registry.register(defines.events.on_entity_died, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_removed(entity)
    end
end)

---@param event EventData.on_player_mined_entity
registry.register(defines.events.on_player_mined_entity, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_removed(entity)
    end
end)

---@param event EventData.on_robot_mined_entity
registry.register(defines.events.on_robot_mined_entity, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_removed(entity)
    end
end)

---@param event EventData.script_raised_destroy
registry.register(defines.events.script_raised_destroy, function(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name == "ftrainworks-sensor" then
        on_sensor_removed(entity)
    end
end)

---@param event EventData.on_train_created
registry.register(defines.events.on_train_created, function(event)
    local train = event.train
    if not (train and train.valid) then return end
    on_train_created(train)
end)

---@param event EventData.on_train_changed_state
registry.register(defines.events.on_train_changed_state, function(event)
    local train = event.train
    if not (train and train.valid) then return end
    on_train_state_changed(train)
end)

local first_tick = true
---@param event EventData.on_tick
registry.register(defines.events.on_tick, function(event)
    if first_tick then
        first_tick = false

        -- Activate sensors for all existing trains.
        for _, train in ipairs(game.train_manager.get_trains{}) do
            if train.speed == 0 then
                activate_sensors(train)
            end
        end
    end

    for sensor_unit_number, active_sensor_data in pairs(active_sensors) do
        sensor_report(sensor_unit_number, active_sensor_data)
    end
end)

return {
    validate_sensor_data = validate_sensor_data,
    remove_sensor_data = remove_sensor_data,
    activate_sensors = activate_sensors,
    deactivate_sensor = deactivate_sensor,
    sensor_report = sensor_report,
    on_sensor_built = on_sensor_built,
    on_sensor_removed = on_sensor_removed,
    on_train_created = on_train_created,
    on_train_state_changed = on_train_state_changed
}
