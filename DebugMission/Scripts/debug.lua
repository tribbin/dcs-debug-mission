Debug = Debug or {}
Debug.players = {}          -- [groupId] = {enabled = bool, prevVel = vec3, seen = false}

env.info("DEBUG.LUA: Loading")

function Debug.checkPlayers()
    local newPlayers = {}

    for _, side in ipairs({1, 2}) do
        local playerUnits = coalition.getPlayers(side) or {}
        for _, unit in ipairs(playerUnits) do
            if unit:isExist() and unit:getPlayerName() then
                local group = unit:getGroup()
                if group then
                    local gid = group:getID()
                    if not Debug.players[gid] then
                        Debug.players[gid] = {enabled = true, prevVel = nil, seen = true}
                        newPlayers[gid] = unit
                        env.info("DEBUG: New player detected via poll - group " .. gid)
                    elseif not Debug.players[gid].seen then
                        Debug.players[gid].seen = true
                        newPlayers[gid] = unit
                    end
                end
            end
        end
    end

    for gid, unit in pairs(newPlayers) do
        local data = Debug.players[gid]
        if data then
            pcall(function()
                missionCommands.removeItemForGroup(gid, {"Debug"})
                local submenu = missionCommands.addSubMenuForGroup(gid, "Debug")
                missionCommands.addCommandForGroup(gid, "Toggle Telemetry Overlay", submenu,
                    function() Debug.toggleCallback(gid) end)
            end)

            trigger.action.outTextForGroup(gid, "DEBUG TELEMETRY ENABLED BY DEFAULT", 10, true)
        end
    end

    return timer.getTime() + 3.0
end

function Debug.toggleCallback(groupId)
    local data = Debug.players[groupId]
    if not data then return end

    data.enabled = not data.enabled
    local msg = data.enabled and "TELEMETRY ENABLED" or "TELEMETRY DISABLED"
    trigger.action.outTextForGroup(groupId, msg, 8, true)
end

function Debug.buildTelemetry(unit, data)
    if not unit or not unit:isExist() then return "Unit lost" end

    -- Velocity-based values
    local vel = unit:getVelocity() or {x=0, y=0, z=0}
    local tas = math.floor(math.sqrt(vel.x^2 + vel.y^2 + vel.z^2) * 3.6 + 0.5)
    local vs  = math.floor(vel.y)

    -- Acceleration from delta
    local accelG = 0
    if data.prevVel then
        local dvx = vel.x - data.prevVel.x
        local dvy = vel.y - data.prevVel.y
        local dvz = vel.z - data.prevVel.z
        local accelMS2 = math.sqrt(dvx^2 + dvy^2 + dvz^2)
        accelG = math.floor(accelMS2 / 9.81 * 10 + 0.5) / 10
    end
    data.prevVel = vel

    -- Position
    local pos = unit:getPosition().p
    local alt = math.floor(pos.y)

    -- Normal wind
    local windVec = atmosphere.getWind(pos)
    local windSpeed = math.floor(math.sqrt(windVec.x^2 + windVec.z^2) + 0.5)
    local windDir  = math.floor((math.deg(math.atan2(windVec.x, windVec.z)) + 180) % 360 + 0.5)

    -- Turbulence wind
    local turbVec = atmosphere.getWindWithTurbulence(pos)
    local turbSpeed = math.floor(math.sqrt(turbVec.x^2 + turbVec.z^2) + 0.5)
    local turbDir  = math.floor((math.deg(math.atan2(turbVec.x, turbVec.z)) + 180) % 360 + 0.5)

    -- Temperature & Pressure (correct return: two numbers)
    local tempK, pressurePa = atmosphere.getTemperatureAndPressure(pos)
    local tempC = math.floor(tempK - 273.15)
    local pressHpa = math.floor(pressurePa / 100 + 0.5)

    -- Fuel
    local fuel = unit.getFuel and math.floor((unit:getFuel() or 0) * 100 + 0.5) or 0

    return string.format(
        "ENVIRONMENT\n"..
        "Temp: %d°C    Press: %d hPa\n"..
        "Wind: %d m/s from %d°\n"..
        "Turb: %d m/s from %d°\n\n"..
        "AIRCRAFT\n"..
        "TAS: %d km/h    Alt: %d m\n"..
        "Vert Speed: %+d m/s    Accel: %.1f G\n"..
        "Fuel: %d%%",
        tempC, pressHpa,
        windSpeed, windDir,
        turbSpeed, turbDir,
        tas, alt,
        vs, accelG,
        fuel
    )
end

function Debug.updateTelemetry()
    for gid, data in pairs(Debug.players) do
        if data.enabled then
            local foundUnit = nil
            for _, side in ipairs({1, 2}) do
                local players = coalition.getPlayers(side) or {}
                for _, unit in ipairs(players) do
                    if unit:isExist() and unit:getPlayerName() then
                        local uGroup = unit:getGroup()
                        if uGroup and uGroup:getID() == gid then
                            foundUnit = unit
                            break
                        end
                    end
                end
                if foundUnit then break end
            end

            if foundUnit then
                local text = Debug.buildTelemetry(foundUnit, data)
                if text then
                    trigger.action.outTextForGroup(gid, text, 1.5, true)
                end
            end
        end
    end

    return timer.getTime() + 1.0
end

function Debug.Init()
    env.info("DEBUG.LUA: Init")
    timer.scheduleFunction(Debug.checkPlayers, nil, timer.getTime() + 2)
    timer.scheduleFunction(Debug.updateTelemetry, nil, timer.getTime() + 5)
end

return Debug