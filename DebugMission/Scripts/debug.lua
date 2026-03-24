Debug = Debug or {}
Debug.players = {}          -- [groupId] = {enabled, prevVel, prevTAS, prevVS, prevHeading, prevTime, sustainedStart, seen}

-- ================== CONFIG ==================
local SUSTAINED_DURATION = 8.0        -- seconds of stability required before logging starts
local TAS_MAX_VAR        = 5.0        -- km/h variation allowed
local TURNRATE_MAX_VAR   = 0.5        -- °/s variation allowed

-- Cockpit arguments
local ARG_THROTTLE = 0
local ARG_AB       = 100
local ARG_FLAPS    = 9
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
                        Debug.players[gid] = {
                            enabled = true,
                            prevVel = nil,
                            prevTAS = nil,
                            prevVS = nil,
                            prevHeading = nil,
                            prevTime = nil,
                            sustainedStart = nil,
                            seen = true
                        }
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

-- ================== CSV LOGGING ==================
local logFile = nil
local logPath = lfs.writedir() .. "DebugMission\\Logs\\sustained_turns.csv"

local function ensureLogFile()
    if logFile then return end
    lfs.mkdir(lfs.writedir() .. "DebugMission")
    lfs.mkdir(lfs.writedir() .. "DebugMission\\Logs")
    logFile = io.open(logPath, "a")
    if logFile and logFile:seek("end") == 0 then
        logFile:write("Timestamp,TAS_km_h,TurnRate_dps,AccelG,Alt_m,Fuel_%,Wind_m_s,WindFrom_deg,Temp_C,Press_hPa,Throttle_%,AB,Flaps\n")
        logFile:flush()
    end
end

local function logSustained(gid, logData)
    ensureLogFile()
    if not logFile then return end
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    logFile:write(string.format("%s,%s\n", ts, logData))
    logFile:flush()
end

function Debug.buildTelemetry(unit, data)
    if not unit or not unit:isExist() then return "Unit lost" end

    local now = timer.getTime()

    local vel = unit:getVelocity() or {x=0, y=0, z=0}
    local tas = math.floor(math.sqrt(vel.x^2 + vel.y^2 + vel.z^2) * 3.6 + 0.5)
    local vs  = math.floor(vel.y)

    local accelG = 0
    if data.prevVel then
        local dvx = vel.x - data.prevVel.x
        local dvy = vel.y - data.prevVel.y
        local dvz = vel.z - data.prevVel.z
        local accelMS2 = math.sqrt(dvx^2 + dvy^2 + dvz^2)
        accelG = math.floor(accelMS2 / 9.81 * 10 + 0.5) / 10
    end
    data.prevVel = vel

    local pos = unit:getPosition().p
    local alt = math.floor(pos.y)

    -- Turn rate
    local heading = math.deg(math.atan2(vel.x, vel.z))
    local turnRate = 0
    if data.prevHeading and data.prevTime then
        local dt = now - data.prevTime
        if dt > 0 then
            local dH = heading - data.prevHeading
            dH = (dH + 180) % 360 - 180
            turnRate = dH / dt
            turnRate = math.floor(turnRate * 10 + 0.5) / 10
        end
    end
    data.prevHeading = heading
    data.prevTime = now

    -- Deltas
    local tasDelta = ""
    local vsDelta  = ""
    if data.prevTAS and data.prevVS then
        local dTAS = tas - data.prevTAS
        local dVS  = vs - data.prevVS
        tasDelta = string.format(" (%+.1f km/h/s)", dTAS)
        vsDelta  = string.format(" (%+d m/s²)", math.floor(dVS))
    end
    data.prevTAS = tas
    data.prevVS  = vs

    -- === SUSTAINED TURN DETECTION ===
    local isStable = false
    if data.prevTAS and data.prevHeading then
        local dTAS = math.abs(tas - data.prevTAS)
        local dTurn = math.abs(turnRate - (data.prevHeading or 0))
        isStable = (dTAS <= TAS_MAX_VAR) and (dTurn <= TURNRATE_MAX_VAR)
    end

    if isStable then
        if not data.sustainedStart then
            data.sustainedStart = now
        end
        if (now - data.sustainedStart) >= SUSTAINED_DURATION then
            -- Log to CSV
            local windVec = atmosphere.getWind(pos)
            local windSpeed = math.floor(math.sqrt(windVec.x^2 + windVec.z^2) + 0.5)
            local windDir  = math.floor((math.deg(math.atan2(windVec.x, windVec.z)) + 180) % 360 + 0.5)

            local tempK, pressPa = atmosphere.getTemperatureAndPressure(pos)
            local tempC = math.floor(tempK - 273.15)
            local pressHpa = math.floor(pressPa / 100 + 0.5)

            local fuel = unit.getFuel and math.floor((unit:getFuel() or 0) * 100 + 0.5) or 0

            local throttle = unit.getDrawArgumentValue and math.floor(unit:getDrawArgumentValue(ARG_THROTTLE) * 100 + 0.5) or 0
            local abState  = (unit.getDrawArgumentValue and unit:getDrawArgumentValue(ARG_AB) or 0) > 0.5 and 1 or 0
            local flaps    = unit.getDrawArgumentValue and math.floor(unit:getDrawArgumentValue(ARG_FLAPS) * 100 + 0.5) or 0

            local logLine = string.format("%d,%.1f,%.1f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                tas, turnRate, accelG, alt, fuel, windSpeed, windDir, tempC, pressHpa, throttle, abState, flaps)

            logSustained(gid, logLine)
        end
    else
        data.sustainedStart = nil
    end

    -- Overlay (exactly as in your current code)
    return string.format(
        "ENVIRONMENT\n"..
        "Temp: %d°C    Press: %d hPa\n"..
        "Wind: %d m/s from %d°\n"..
        "Turb: %d m/s from %d°\n\n"..
        "AIRCRAFT\n"..
        "TAS: %d km/h%s    Alt: %d m\n"..
        "Vert Speed: %+d m/s%s    Turn: %+.1f °/s\n"..
        "Accel: %.1f G    Fuel: %d%%",
        math.floor(tempK - 273.15), math.floor(pressPa / 100 + 0.5),
        windSpeed, windDir,
        math.floor(math.sqrt(atmosphere.getWindWithTurbulence(pos).x^2 + atmosphere.getWindWithTurbulence(pos).z^2) + 0.5),
        math.floor((math.deg(math.atan2(atmosphere.getWindWithTurbulence(pos).x, atmosphere.getWindWithTurbulence(pos).z)) + 180) % 360 + 0.5),
        tas, tasDelta,
        alt,
        vs, vsDelta,
        turnRate,
        accelG,
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