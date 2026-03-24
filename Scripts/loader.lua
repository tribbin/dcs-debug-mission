-- loader.lua - Dedicated-server compatible (no package.path)
-- Load from mission trigger: Do Script → dofile(lfs.writedir() .. "MiG-17F/Scripts/loader.lua")

local basePath = lfs.writedir() .. "MiG-17F\\Scripts\\"

-- Use absolute path for dofile
dofile(basePath .. "debug.lua")

if Debug and Debug.Init then
    Debug.Init()
    trigger.action.outText("MiG-17F Debug system loaded (dedicated server mode)", 12)
end

env.info("DEBUG LOADER: Executed successfully on dedicated server")