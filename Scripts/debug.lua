-- =============================================
-- debug.lua -- Poll-based, with guards for missing methods (MiG-17F compatible)
-- =============================================

Debug = Debug or {}
Debug.players = {}          -- [groupId] = {enabled = bool, prevVel = vec3, seen = false}

env.info("DEBUG.LUA: Poll-based version loaded (dedicated-safe)")

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
                missionCommands.removeItemForGroup(gid, {"MiG-17 Debug"})
                local submenu = missionCommands.addSubMenuForGroup(gid, "MiG-17 Debug")
                missionCommands.addCommandForGroup(gid, "Toggle Telemetry Overlay", submenu,
                    function() Debug.toggleCallback(gid) end)
            end)

            trigger.action.outTextForGroup(gid, "MiG-17F DEBUG TELEMETRY ENABLED BY DEFAULT", 10, true)
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
    if not unit or not unit:isExist() then return nil end

    local vel = unit:getVelocity() or {x=0,y=0,z=0}
    local tas = math.floor(math.sqrt(vel.x^2 + vel.y^2 + vel.z^2) * 3.6 + 0.5)

    local mach = 0
    if unit.getMachNumber then
        local m = unit:getMachNumber()
        if m then mach = m end
    else
        env.info("DEBUG: getMachNumber not available on this unit")
    end

    local turnRate = 0.0
    if unit.getAngularVelocity then
        local omega = unit:getAngularVelocity()
        if omega then
            turnRate = math.deg(math.sqrt(omega.x^2 + omega.y^2 + omega.z^2))
            turnRate = math.floor(turnRate * 10 + 0.5) / 10
        end
    else
        env.info("DEBUG: getAngularVelocity not available on this unit (common for older jets like MiG-17F)")
    end

    local vs = math.floor(vel.y or 0)

    local accelG = 0
    if data.prevVel then
        local dvx = vel.x - data.prevVel.x
        local dvy = vel.y - data.prevVel.y
        local dvz = vel.z - data.prevVel.z
        local accelMS2 = math.sqrt(dvx^2 + dvy^2 + dvz^2)
        accelG = math.floor(accelMS2 / 9.81 * 10 + 0.5) / 10
    end
    data.prevVel = vel

    return string.format(
        "TAS: %d km/h   Mach: %.2f\n"..
        "Accel: %.1f G   Turn: %.1f °/s\n"..
        "Vert Speed: %+d m/s",
        tas, mach, accelG, turnRate, vs
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
    env.info("DEBUG: Init - poll-based setup")
    timer.scheduleFunction(Debug.checkPlayers, nil, timer.getTime() + 2)
    timer.scheduleFunction(Debug.updateTelemetry, nil, timer.getTime() + 5)
end

return Debug