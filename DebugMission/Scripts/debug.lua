Debug = Debug or {}

-- [groupId] = {enabled, unit, lastSeen, prevVel, prevTAS, prevVS, prevHeading, prevTurnRate, prevTime, sustainedStart}
Debug.players = {}

-- ================== CONFIG ==================
local SUSTAINED_DURATION = 8.0        -- seconds of stability required
local TAS_MAX_VAR        = 5.0        -- km/h
local TURNRATE_MAX_VAR   = 0.5        -- °/s

local ARG_THROTTLE = 0
local ARG_AB       = 100
local ARG_FLAPS    = 9

env.info("DEBUG.LUA: Loading fixed version")

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

local function logSustained(logData)
    ensureLogFile()
    if not logFile then return end
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    logFile:write(string.format("%s,%s\n", ts, logData))
    logFile:flush()
end

-- ================== PLAYER MANAGEMENT ==================
function Debug.checkPlayers()
    local activeGids = {}
    for _, side in ipairs({1, 2}) do
        local playerUnits = coalition.getPlayers(side) or {}
        for _, unit in ipairs(playerUnits) do
            if unit:isExist() and unit:getPlayerName() then
                local group = unit:getGroup()
                if group then
                    activeGids[group:getID()] = unit
                end
            end
        end
    end

    local now = timer.getTime()

    -- Cleanup stale players (disconnected/destroyed)
    for gid, data in pairs(Debug.players) do
        if not activeGids[gid] and (now - (data.lastSeen or 0)) > 10 then
            Debug.players[gid] = nil
            env.info("DEBUG: Removed stale player group " .. gid)
        end
    end

    -- Add/update active players (only once)
    for gid, unit in pairs(activeGids) do
        if not Debug.players[gid] then
            Debug.players[gid] = {
                enabled = true,
                unit = unit,
                lastSeen = now,
                prevVel = nil,
                prevTAS = nil,
                prevVS = nil,
                prevHeading = nil,
                prevTurnRate = 0,
                prevTime = nil,
                sustainedStart = nil
            }

            pcall(function()
                missionCommands.removeItemForGroup(gid, {"Debug"})
                local submenu = missionCommands.addSubMenuForGroup(gid, "Debug")
                missionCommands.addCommandForGroup(gid, "Toggle Telemetry Overlay", submenu,
                    function() Debug.toggleCallback(gid) end)
            end)

            trigger.action.outTextForGroup(gid, "DEBUG TELEMETRY ENABLED BY DEFAULT\nF10 → Debug → Toggle Telemetry Overlay", 15, true)
            env.info("DEBUG: New player detected - group " .. gid)
        else
            Debug.players[gid].lastSeen = now
            Debug.players[gid].unit = unit
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

-- ================== TELEMETRY ==================
function Debug.buildTelemetry(gid, unit, data)
    if not unit or not unit:isExist() then
        return "Unit no longer exists"
    end

    local now = timer.getTime()
    local dt = data.prevTime and (now - data.prevTime) or 1.0

    local vel = unit:getVelocity() or {x=0, y=0, z=0}
    local tas = math.floor(math.sqrt(vel.x^2 + vel.y^2 + vel.z^2) * 3.6 + 0.5)
    local vs  = math.floor(vel.y)

    -- Acceleration G (real dt)
    local accelG = 0
    if data.prevVel then
        local dvx = vel.x - data.prevVel.x
        local dvy = vel.y - data.prevVel.y
        local dvz = vel.z - data.prevVel.z
        local accelMS2 = math.sqrt(dvx^2 + dvy^2 + dvz^2) / dt
        accelG = math.floor(accelMS2 / 9.81 * 10 + 0.5) / 10
    end

    local pos = unit:getPosition().p
    local alt = math.floor(pos.y)

    -- Heading & Turn rate (real dt)
    local heading = math.deg(math.atan2(vel.x, vel.z))
    local turnRate = 0
    if data.prevHeading and data.prevTime then
        local dH = heading - data.prevHeading
        dH = (dH + 180) % 360 - 180
        turnRate = dH / dt
        turnRate = math.floor(turnRate * 10 + 0.5) / 10
    end

    -- Deltas (per second)
    local tasDelta = data.prevTAS and string.format(" (%+.1f)", (tas - data.prevTAS) / dt) or ""
    local vsDelta  = data.prevVS  and string.format(" (%+d)", math.floor((vs - data.prevVS) / dt)) or ""

    -- Sustained turn detection
    local isStable = false
    if data.prevTAS and data.prevTurnRate then
        local dTAS = math.abs(tas - data.prevTAS)
        local dTurn = math.abs(turnRate - data.prevTurnRate)
        isStable = (dTAS <= TAS_MAX_VAR) and (dTurn <= TURNRATE_MAX_VAR)
    end

    if isStable then
        if not data.sustainedStart then data.sustainedStart = now end
        if (now - data.sustainedStart) >= SUSTAINED_DURATION then
            local windVec = atmosphere.getWind(pos)
            local windSpeed = math.floor(math.sqrt(windVec.x^2 + windVec.z^2) + 0.5)
            local windDir   = math.floor((math.deg(math.atan2(windVec.x, windVec.z)) + 180) % 360 + 0.5)

            local tempK, pressPa = atmosphere.getTemperatureAndPressure(pos)
            local tempC   = math.floor(tempK - 273.15)
            local pressHpa = math.floor(pressPa / 100 + 0.5)

            local fuel     = unit.getFuel and math.floor((unit:getFuel() or 0) * 100 + 0.5) or 0
            local throttle = unit.getDrawArgumentValue and math.floor((unit:getDrawArgumentValue(ARG_THROTTLE) or 0) * 100 + 0.5) or 0
            local abState  = (unit.getDrawArgumentValue and (unit:getDrawArgumentValue(ARG_AB) or 0) > 0.5) and 1 or 0
            local flaps    = unit.getDrawArgumentValue and math.floor((unit:getDrawArgumentValue(ARG_FLAPS) or 0) * 100 + 0.5) or 0

            local logLine = string.format("%d,%.1f,%.1f,%.1f,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                tas, turnRate, accelG, alt, fuel, windSpeed, windDir, tempC, pressHpa, throttle, abState, flaps)

            logSustained(logLine)
        end
    else
        data.sustainedStart = nil
    end

    -- Update previous values
    data.prevVel      = vel
    data.prevTAS      = tas
    data.prevVS       = vs
    data.prevHeading  = heading
    data.prevTurnRate = turnRate
    data.prevTime     = now

    -- Environment values (always needed for overlay)
    local windVec = atmosphere.getWind(pos)
    local windSpeed = math.floor(math.sqrt(windVec.x^2 + windVec.z^2) + 0.5)
    local windDir   = math.floor((math.deg(math.atan2(windVec.x, windVec.z)) + 180) % 360 + 0.5)
    local tempK, pressPa = atmosphere.getTemperatureAndPressure(pos)

    -- Telemetry overlay
    return string.format(
        "ENVIRONMENT\n"..
        "Temp: %d°C   Press: %d hPa\n"..
        "Wind: %d m/s from %d°\n\n"..
        "AIRCRAFT\n"..
        "TAS: %d km/h%s\n"..
        "VS: %d m/s%s\n"..
        "Turn rate: %.1f °/s\n"..
        "Accel: %.1f G\n"..
        "Alt: %d m\n"..
        "Fuel: %d%%\n\n"..
        "Telemetry %s",
        math.floor(tempK - 273.15),
        math.floor(pressPa / 100),
        windSpeed,
        windDir,
        tas, tasDelta,
        vs, vsDelta,
        turnRate,
        accelG,
        alt,
        unit.getFuel and math.floor((unit:getFuel() or 0) * 100 + 0.5) or 0,
        data.enabled and "ON" or "OFF"
    )
end

function Debug.updateTelemetry()
    local now = timer.getTime()

    for gid, data in pairs(Debug.players) do
        if data.enabled then
            local unit = data.unit
            if unit and unit:isExist() then
                local text = Debug.buildTelemetry(gid, unit, data)
                trigger.action.outTextForGroup(gid, text, 1.1, true)   -- slightly shorter than interval = less flicker
            else
                data.unit = nil
            end
        end
    end

    return now + 1.0
end

-- ================== INIT ==================
timer.scheduleFunction(Debug.checkPlayers,    nil, timer.getTime() + 1.0)
timer.scheduleFunction(Debug.updateTelemetry, nil, timer.getTime() + 2.0)

env.info("DEBUG.LUA: Loaded successfully (all issues fixed)")