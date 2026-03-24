-- Load from mission trigger: Do Script → dofile(lfs.writedir() .. "DebugMission/Scripts/loader.lua")

-- PREVENT SERVER FROM HALTING ON MISSION LUA ERROR
env.setErrorMessageBoxEnabled(false)

local basePath = lfs.writedir() .. "DebugMission\\Scripts\\"

-- Safe load + error reporting to server chat
local success, err = pcall(function()
    dofile(basePath .. "debug.lua")

    if Debug and Debug.Init then
        Debug.Init()
    end
end)

if success then
    trigger.action.outText("Debug system loaded", 12)
    env.info("DEBUG LOADER: Executed successfully")
else
    -- Send the full error to server/global chat so you see it instantly
    local errorMsg = "[DEBUG MISSION ERROR] " .. tostring(err)
    if net and net.send_chat then
        net.send_chat(errorMsg, true)   -- true = visible to everyone (including server console)
    end
    env.error("DEBUG LOADER FAILED: " .. tostring(err), true)
    trigger.action.outText(errorMsg, 30, true)
end