Debug = Debug or {}
Debug.players = {}

-- ================== CONFIG ==================
local SAMPLE_INTERVAL    = 0.5     -- seconds
local SUSTAINED_DURATION = 3.8     -- seconds
local TAS_MAX_VAR        = 5.0     -- km/h/s
local TURNRATE_MAX_VAR   = 0.5     -- deg/s
local ALT_MAX_VAR        = 5.0     -- m/s

local TARGET_ALTITUDES   = {20, 1000, 5000, 10000, 20000, 30000}

--local ARG_THROTTLE = 722 -- Has no animation
local ARG_AB       = 28
local ARG_FLAPS    = 9

local missionStartTime = os.date("%Y%m%d_%H%M%S")

env.info("DEBUG.LUA: Loading - Mission start time: " .. missionStartTime)

-- ================== CSV LOGGING (per-player) ==================
local function ensurePlayerLogFile(data)
    if data.logFile then return end

    lfs.mkdir(lfs.writedir() .. "DebugMission")
    lfs.mkdir(lfs.writedir() .. "DebugMission\\Logs")

    local safePlayer = (data.playerName or "Unknown"):gsub("[^%w_]", "_")
    local safeAc     = (data.aircraftType or "Unknown"):gsub("[^%w_]", "_")

    local filename = string.format("sustained_turns_%s_%s_%s.csv", missionStartTime, safeAc, safePlayer)
    local logPath = lfs.writedir() .. "DebugMission\\Logs\\" .. filename

    local fileExists = lfs.attributes(logPath) ~= nil

    local file = io.open(logPath, "a")
    if file then
        if not fileExists then
            file:write("Timestamp,Player,Aircraft,TAS_km_h,GS_km_h,TurnRate_dps,AccelG,Alt_m,Fuel_%,Wind_m_s,WindFrom_deg,Temp_C,Press_hPa,AB,Flaps\n")
            file:flush()
        end
        data.logFile = file
        env.info("DEBUG: Created/opened log file -> " .. filename)
    else
        env.error("DEBUG: Failed to open log file: " .. logPath)
    end
end

local function logSustained(data, logData)
    ensurePlayerLogFile(data)
    if not data.logFile then return end
    
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    data.logFile:write(string.format("%s,%s\n", ts, logData))
    data.logFile:flush()
end

-- ================== VISUAL BAR HELPERS (from better-ergonomics branch) ==================
local function makeCorrectionBar(value, maxVal)
    local width = 21
    local half  = 10
    local pos   = math.floor(half + (value / maxVal) * half)
    pos = math.max(0, math.min(width - 1, pos))

    local bar = {}
    for i = 0, width - 1 do
        if i == half then
            bar[i+1] = "0"
        else
            bar[i+1] = "="
        end
    end
    if pos ~= half then
        bar[pos+1] = (value > 0) and ">" or "<"
    end
    return table.concat(bar)
end

local function makeAltDeviationBar(deviation)
    local maxDev = 300
    local width = 41
    local half  = 20
    local pos   = math.floor(half + (deviation / maxDev) * half)
    pos = math.max(0, math.min(width - 1, pos))

    local bar = {}
    for i = 0, width - 1 do
        if i == half then
            bar[i+1] = "0"
        else
            bar[i+1] = "="
        end
    end
    if pos ~= half then
        bar[pos+1] = (deviation > 0) and ">" or "<"
    end
    return table.concat(bar)
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

    -- Cleanup stale players + close their log files
    for gid, data in pairs(Debug.players) do
        if not activeGids[gid] and (now - (data.lastSeen or 0)) > 10 then
            if data.logFile then
                data.logFile:close()
            end
            Debug.players[gid] = nil
            env.info("DEBUG: Removed stale player group " .. gid)
        end
    end

    -- Add/update active players (capture name + type once)
    for gid, unit in pairs(activeGids) do
        if not Debug.players[gid] then
            local playerName = unit:getPlayerName() or "Unknown"
            local aircraftType = unit:getTypeName() or "Unknown"

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
                prevAlt = nil,
                sustainedStart = nil,
                lastSustainedLog = nil,
                logFile = nil,
                playerName = playerName,
                aircraftType = aircraftType,
                stableBuffer = {}      -- rolling buffer of stable samples for averaging
            }

            pcall(function()
                missionCommands.removeItemForGroup(gid, {"Debug"})
                local submenu = missionCommands.addSubMenuForGroup(gid, "Debug")
                missionCommands.addCommandForGroup(gid, "Toggle Telemetry Overlay", submenu,
                    function() Debug.toggleCallback(gid) end)
            end)

            trigger.action.outTextForGroup(gid, "DEBUG TELEMETRY ENABLED\nAircraft: " .. aircraftType .. "\nF10 → Debug → Toggle Telemetry Overlay", 15, true)
            env.info("DEBUG: New player " .. playerName .. " (" .. aircraftType .. ") - group " .. gid)
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
    local fullPos = unit:getPosition()
    local pos = fullPos.p

    -- === CALCULATIONS ===
    local gs_ms = math.sqrt(vel.x^2 + vel.y^2 + vel.z^2)
    local gs    = math.floor(gs_ms * 3.6 + 0.5)

    local wind    = atmosphere.getWind(pos)
    local airVelX = vel.x - wind.x
    local airVelY = vel.y - wind.y
    local airVelZ = vel.z - wind.z
    local tas_ms  = math.sqrt(airVelX^2 + airVelY^2 + airVelZ^2)
    local tas     = math.floor(tas_ms * 3.6 + 0.5)

    local vs = math.floor(vel.y)
    local alt = math.floor(pos.y)

    local accelG = 0
    if data.prevVel then
        local dvx = vel.x - data.prevVel.x
        local dvy = vel.y - data.prevVel.y
        local dvz = vel.z - data.prevVel.z
        local accelMS2 = math.sqrt(dvx^2 + dvy^2 + dvz^2) / dt
        accelG = math.floor(accelMS2 / 9.81 * 10 + 0.5) / 10
    end

    local heading = math.deg(math.atan2(fullPos.z.x, fullPos.z.z))
    heading = (heading + 360) % 360

    local turnRate = 0
    if data.prevHeading and data.prevTime then
        local dH = heading - data.prevHeading
        dH = (dH + 180) % 360 - 180
        turnRate = dH / dt
        turnRate = math.floor(turnRate * 10 + 0.5) / 10
    end

    local tasDelta = data.prevTAS and string.format(" (%+.1f)", (tas - data.prevTAS) / dt) or ""
    local vsDelta  = data.prevVS  and string.format(" (%+d)", math.floor((vs - data.prevVS) / dt)) or ""

    local dTAS_rate  = data.prevTAS and dt > 0.1 and (tas - data.prevTAS) / dt or 0
    local dTurn_rate = data.prevTurnRate and (turnRate - data.prevTurnRate) or 0
    local dAlt_rate  = data.prevAlt and dt > 0.1 and (alt - data.prevAlt) / dt or 0

    -- Find nearest pre-programmed altitude for snapping (ergonomics branch)
    local nearestTarget = TARGET_ALTITUDES[1]
    local minDist = math.abs(alt - TARGET_ALTITUDES[1])
    for _, target in ipairs(TARGET_ALTITUDES) do
        local dist = math.abs(alt - target)
        if dist < minDist then
            minDist = dist
            nearestTarget = target
        end
    end

    local altDeviation = alt - nearestTarget

    -- Auto-scale tolerance: wider band at higher altitude
    local ALTITUDE_TOLERANCE = 40 + math.floor(nearestTarget / 180)   -- ~50 m low → ~200 m at 30 km

    -- Target altitude band check (kept for logging trigger)
    local isInTargetBand = false
    for _, targetAlt in ipairs(TARGET_ALTITUDES) do
        if math.abs(alt - targetAlt) <= ALTITUDE_TOLERANCE then
            isInTargetBand = true
            break
        end
    end

    -- === SUSTAINED TURN DETECTION + LOGGING WITH AVERAGING ===
    local isStable = false
    if data.prevTAS and data.prevTurnRate and data.prevAlt and dt > 0.1 then
        local dTAS_rate_abs  = math.abs(dTAS_rate)
        local dTurn_rate_abs = math.abs(dTurn_rate)
        local dAlt_rate_abs  = math.abs(dAlt_rate)
        isStable = (dTAS_rate_abs <= TAS_MAX_VAR) and
                   (dTurn_rate_abs <= TURNRATE_MAX_VAR) and
                   (dAlt_rate_abs <= ALT_MAX_VAR)
    end

    if isStable and isInTargetBand then
        if not data.sustainedStart then
            data.sustainedStart = now
            data.stableBuffer = {}
        end

        -- Collect current values
        table.insert(data.stableBuffer, {
            tas      = tas,
            gs       = gs,
            turnRate = turnRate,
            accelG   = accelG,
            alt      = alt,
            fuel     = unit.getFuel and math.floor((unit:getFuel() or 0) * 100 + 0.5) or 0,
            abState  = (unit.getDrawArgumentValue and (unit:getDrawArgumentValue(ARG_AB) or 0) > 0.5) and 1 or 0,
            flaps    = unit.getDrawArgumentValue and math.floor((unit:getDrawArgumentValue(ARG_FLAPS) or 0) * 100 + 0.5) or 0,
        })

        -- Once we have confirmed sustained performance for the required duration...
        if (now - data.sustainedStart) >= SUSTAINED_DURATION then
            if not data.lastSustainedLog or (now - data.lastSustainedLog) >= 10.0 then

                -- === AVERAGE ALL STABLE SAMPLES ===
                local n = #data.stableBuffer
                if n > 0 then
                    local sumTAS = 0; local sumGS = 0; local sumTurn = 0; local sumG = 0; local sumAlt = 0
                    local sumFuel = 0; local sumAB = 0; local sumFlaps = 0

                    for _, sample in ipairs(data.stableBuffer) do
                        sumTAS   = sumTAS   + sample.tas
                        sumGS    = sumGS    + sample.gs
                        sumTurn  = sumTurn  + sample.turnRate
                        sumG     = sumG     + sample.accelG
                        sumAlt   = sumAlt   + sample.alt
                        sumFuel  = sumFuel  + sample.fuel
                        sumAB    = sumAB    + sample.abState
                        sumFlaps = sumFlaps + sample.flaps
                    end

                    local avgTAS      = math.floor(sumTAS / n + 0.5)
                    local avgGS       = math.floor(sumGS / n + 0.5)
                    local avgTurnRate = math.floor(sumTurn / n * 10 + 0.5) / 10
                    local avgG        = math.floor(sumG / n * 10 + 0.5) / 10
                    local avgAlt      = math.floor(sumAlt / n + 0.5)
                    local avgFuel     = math.floor(sumFuel / n + 0.5)
                    local avgAB       = (sumAB / n > 0.5) and 1 or 0
                    local avgFlaps    = math.floor(sumFlaps / n + 0.5)

                    -- Environmental data
                    local windVec = atmosphere.getWind(pos)
                    local windSpeed = math.floor(math.sqrt(windVec.x^2 + windVec.z^2) + 0.5)
                    local windDir   = math.floor((math.deg(math.atan2(windVec.x, windVec.z)) + 180) % 360 + 0.5)
                    local tempK, pressPa = atmosphere.getTemperatureAndPressure(pos)
                    local tempC    = math.floor(tempK - 273.15)
                    local pressHpa = math.floor(pressPa / 100 + 0.5)

                    local logLine = string.format("%s,%s,%d,%d,%.1f,%.1f,%d,%d,%d,%d,%d,%d,%d,%d",
                        data.playerName, data.aircraftType,
                        avgTAS, avgGS, avgTurnRate, avgG, avgAlt, avgFuel,
                        windSpeed, windDir, tempC, pressHpa,
                        avgAB, avgFlaps)

                    logSustained(data, logLine)
                    data.lastSustainedLog = now
                    trigger.action.outSoundForGroup(gid, "pluck_high.ogg")   -- "logged" sound
                end
            end
        else
            trigger.action.outSoundForGroup(gid, "pluck.ogg")   -- "still building stability" sound
        end
    else
        -- Stability lost: reset everything
        data.sustainedStart = nil
        data.lastSustainedLog = nil
        data.stableBuffer = {}
    end

    -- Environment
    local tempK, pressPa = atmosphere.getTemperatureAndPressure(pos)
    local windVec = atmosphere.getWind(pos)
    local windSpeed = math.floor(math.sqrt(windVec.x^2 + windVec.z^2) + 0.5)
    local windDir   = math.floor((math.deg(math.atan2(windVec.x, windVec.z)) + 180) % 360 + 0.5)

    local fuel     = unit.getFuel and math.floor((unit:getFuel() or 0) * 100 + 0.5) or 0
    local abState  = (unit.getDrawArgumentValue and (unit:getDrawArgumentValue(ARG_AB) or 0) > 0.5) and "ON" or "OFF"
    local flaps    = unit.getDrawArgumentValue and math.floor((unit:getDrawArgumentValue(ARG_FLAPS) or 0) * 100 + 0.5) or 0

    -- Update previous values
    data.prevVel      = vel
    data.prevTAS      = tas
    data.prevVS       = vs
    data.prevHeading  = heading
    data.prevTurnRate = turnRate
    data.prevAlt      = alt
    data.prevTime     = now

    return string.format(
        "DCS SUSTAINED TURN TELEMETRY                                      Telemetry %s\n\n"..
        "ENVIRONMENT\n"..
        "Temp: %d°C    Press: %d hPa\n"..
        "Wind: %d m/s from %d°\n\n"..
        "TURN PERFORMANCE\n"..
        "TAS: %d km/h%s    GS: %d km/h\n"..
        "VS: %d m/s%s\n"..
        "Turn Rate: %.1f °/s     G: %.1f\n"..
        "Fuel: %d%%    AB: %s    Flaps: %d%%\n\n"..
        "SUSTAINED TURN STABILITY (stay near center)\n"..
        "TAS Δ: %.1f km/h/s\n%s\n"..
        "Turn Δ: %.2f °/s²\n%s\n"..
        "Alt Δ: %.1f m/s\n%s\n\n"..
        "\n"..
        "PRIMARY FLIGHT REFERENCE\n\n"..
        "TAS:    %d km/h\n"..
        "TARGET: %d m\n"..
        "CURRENT:%d m\n\n"..
        "Altitude Deviation Bar (0 = target altitude)\n"..
        "%s\n\n"..
        "Player: %s | %s",
        data.enabled and "ON" or "OFF",
        math.floor(tempK - 273.15),
        math.floor(pressPa / 100),
        windSpeed,
        windDir,
        tas, tasDelta, gs,
        vs, vsDelta,
        turnRate, accelG,
        fuel, abState, flaps,
        dTAS_rate, makeCorrectionBar(dTAS_rate, TAS_MAX_VAR),
        dTurn_rate, makeCorrectionBar(dTurn_rate, TURNRATE_MAX_VAR),
        dAlt_rate,  makeCorrectionBar(dAlt_rate, ALT_MAX_VAR),
        tas,
        nearestTarget,
        alt,
        makeAltDeviationBar(altDeviation),
        data.playerName,
        data.aircraftType
    )
end

function Debug.updateTelemetry()
    local now = timer.getTime()

    for gid, data in pairs(Debug.players) do
        if data.enabled then
            local unit = data.unit
            if unit and unit:isExist() then
                local text = Debug.buildTelemetry(gid, unit, data)
                trigger.action.outTextForGroup(gid, text, 1.1, true)
            else
                data.unit = nil
            end
        end
    end

    return now + SAMPLE_INTERVAL
end

-- ================== INIT ==================
timer.scheduleFunction(Debug.checkPlayers,    nil, timer.getTime() + 1.0)
timer.scheduleFunction(Debug.updateTelemetry, nil, timer.getTime() + 2.0)

env.info("DEBUG.LUA: Loaded successfully")