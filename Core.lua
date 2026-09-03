local ADDON_NAME = ...
CloakWatch = CloakWatch or {}
local CW = CloakWatch

-- ============================================================
-- CONFIG
-- ============================================================
local ZONE_NAME        = "Blackwing Lair"
local CLOAK_SLOT       = 15                    -- back slot
local CLOAK_ITEM_NAME  = "Onyxia Scale Cloak"
local OUTDATED_AFTER   = 300                    -- seconds before a scan is considered stale
local SCAN_INTERVAL    = 1.0                    -- seconds between inspect attempts
local INSPECT_TIMEOUT  = 2.0                    -- give up on a stuck inspect after this long
local AGE_CHECK_PERIOD = 15                     -- how often we re-check for outdated entries

-- Lower number = scanned sooner. Matches the priority you asked for:
-- unscanned > outdated > cloak off > cloak on
local STATE_PRIORITY = {
    unscanned = 1,
    outdated  = 2,
    off       = 3,
    on        = 4,
}

-- ============================================================
-- STATE
-- ============================================================
CW.players = {}   -- [name] = { status, lastScan, guid, class }
CW.active  = false
CW.pendingUnit  = nil
CW.pendingGUID  = nil
CW.pendingSince = nil

local scanTicker, ageTicker, rosterTicker
local ROSTER_CHECK_PERIOD = 2.0 -- how often we sweep for units entering/leaving visibility
local savedErrorSpeechCVar = nil -- holds the user's original Sound_EnableErrorSpeech value while scanning

-- ============================================================
-- ERROR SUPPRESSION
-- ============================================================
-- NotifyInspect on a raid member who isn't actually nearby/inspectable can throw
-- client-side error toasts ("Unknown unit", "Out of range"). Our presence/range
-- checks should prevent these at the source, but this filter is a narrow backstop
-- for any race between those checks and the call.
local SUPPRESSED_ERROR_PATTERNS = {
    "Unknown unit",
    "Out of range",
}

do
    local origAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, msg, ...)
        if type(msg) == "string" then
            for _, pattern in ipairs(SUPPRESSED_ERROR_PATTERNS) do
                if msg:find(pattern) then
                    return
                end
            end
        end
        return origAddMessage(self, msg, ...)
    end
end

-- ============================================================
-- HELPERS
-- ============================================================
local function InZone()
    return GetRealZoneText() == ZONE_NAME
end

local function InRelevantGroup()
    return IsInRaid()
end

-- A raid member only counts as "in the dungeon" if they're actually rendered
-- nearby - this is the closest proxy Classic Era exposes to "same instance".
local function IsUnitPresent(unit)
    return UnitExists(unit) and UnitIsConnected(unit) and UnitIsVisible(unit)
end

-- CanInspect() alone doesn't reliably confirm inspect range; UnitInRange gives
-- an extra signal so we skip attempts that would just throw "Out of range."
local function IsInInspectRange(unit)
    local inRange, checkedRange = UnitInRange(unit)
    if not checkedRange then return true end -- unit not in the "checked" radius at all; don't block on an unreliable read
    return inRange and true or false
end

local function UpdateOwnCloak()
    local name = UnitName("player")
    if not name or not CW.players[name] then return end
    local link = GetInventoryItemLink("player", CLOAK_SLOT)
    local hasCloak = link ~= nil and link:find(CLOAK_ITEM_NAME, 1, true) ~= nil
    CW.players[name].status   = hasCloak and "on" or "off"
    CW.players[name].lastScan = GetTime()
    if CW.RefreshUI then CW.RefreshUI() end
end

-- Adds newly-visible raid members, drops anyone who left the group or is no
-- longer present (including "not in the instance yet"). Our own entry is
-- exempt from the visibility check and is kept continuously up to date here
-- as a safety net, since PLAYER_EQUIPMENT_CHANGED should normally cover it.
local function RefreshRoster()
    local seen = {}
    local myName = UnitName("player")

    if IsInRaid() then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local unit = "raid" .. i
            local name = UnitName(unit)
            if name then
                local isSelf = (name == myName)
                if isSelf or IsUnitPresent(unit) then
                    seen[name] = true
                    if not CW.players[name] then
                        CW.players[name] = {
                            status   = "unscanned",
                            lastScan = 0,
                            guid     = UnitGUID(unit),
                            class    = select(2, UnitClass(unit)),
                        }
                    else
                        CW.players[name].guid = UnitGUID(unit)
                    end
                    if isSelf then
                        UpdateOwnCloak() -- always read live, never left to expire or get re-scanned
                    end
                end
            end
        end
    end

    for name in pairs(CW.players) do
        if not seen[name] then
            CW.players[name] = nil
        end
    end

    if CW.RefreshUI then CW.RefreshUI() end
end

-- Demotes "on"/"off" entries to "outdated" once they've aged past the threshold.
local function RefreshAges()
    local now = GetTime()
    local changed = false
    for _, data in pairs(CW.players) do
        if (data.status == "on" or data.status == "off")
           and (now - data.lastScan > OUTDATED_AFTER) then
            data.status = "outdated"
            changed = true
        end
    end
    if changed and CW.RefreshUI then CW.RefreshUI() end
end

-- Finds the current unit token ("raidN") for a player name, if they're still in the raid.
local function UnitTokenForName(name)
    if not IsInRaid() then return nil end
    local n = GetNumGroupMembers()
    for i = 1, n do
        local unit = "raid" .. i
        if UnitName(unit) == name then
            return unit
        end
    end
    return nil
end

-- Picks the highest-priority name to scan next. Skips ourselves - our own
-- cloak status is read directly via UpdateOwnCloak(), not inspected.
local function NextScanTarget()
    local myName = UnitName("player")
    local bestName, bestPriority
    for name, data in pairs(CW.players) do
        if name ~= myName then
            local prio = STATE_PRIORITY[data.status] or 99
            if not bestPriority or prio < bestPriority then
                bestPriority = prio
                bestName = name
            end
        end
    end
    return bestName
end

local function ClearPending()
    if CW.pendingUnit then
        ClearInspectPlayer()
    end
    CW.pendingUnit  = nil
    CW.pendingGUID  = nil
    CW.pendingSince = nil
end

-- ============================================================
-- SCAN LOOP
-- ============================================================
local function TryScanNext()
    if not (InZone() and InRelevantGroup()) then return end

    if CW.pendingUnit then
        if GetTime() - CW.pendingSince > INSPECT_TIMEOUT then
            ClearPending() -- stuck request, drop it and try someone else next tick
        else
            return -- still waiting on INSPECT_READY
        end
    end

    local name = NextScanTarget()
    if not name then return end

    local unit = UnitTokenForName(name)
    if not unit then return end

    -- Requires: present/rendered, inspectable, and within inspect range - missing
    -- any of these just retries next tick rather than throwing a client error.
    if not (IsUnitPresent(unit) and CanInspect(unit) and IsInInspectRange(unit)) then return end

    CW.pendingUnit  = unit
    CW.pendingGUID  = UnitGUID(unit)
    CW.pendingSince = GetTime()
    NotifyInspect(unit)
end

local function OnInspectReady(guid)
    if guid ~= CW.pendingGUID then return end

    local unit = CW.pendingUnit
    local name = unit and UnitName(unit)
    if name and CW.players[name] then
        local link = GetInventoryItemLink(unit, CLOAK_SLOT)
        local hasCloak = link ~= nil and link:find(CLOAK_ITEM_NAME, 1, true) ~= nil
        CW.players[name].status   = hasCloak and "on" or "off"
        CW.players[name].lastScan = GetTime()
    end

    ClearPending()
    if CW.RefreshUI then CW.RefreshUI() end
end

-- ============================================================
-- ACTIVATION
-- ============================================================
local function StartScanning()
    if CW.active then return end
    CW.active = true
    RefreshRoster()
    scanTicker   = C_Timer.NewTicker(SCAN_INTERVAL, TryScanNext)
    ageTicker    = C_Timer.NewTicker(AGE_CHECK_PERIOD, RefreshAges)
    -- Periodic sweep (not just on GROUP_ROSTER_UPDATE) so players who walk into
    -- render range after already being in the raid group get picked up.
    rosterTicker = C_Timer.NewTicker(ROSTER_CHECK_PERIOD, RefreshRoster)
    -- "Out of range" inspect attempts trigger Blizzard's voiced error-speech line
    -- ("It's too far away"), which isn't routed through UIErrorsFrame and can't be
    -- filtered by message text. Disabling it here is global while it's on, so we
    -- only touch it for the window CloakWatch is actually scanning.
    if savedErrorSpeechCVar == nil then
        savedErrorSpeechCVar = GetCVar("Sound_EnableErrorSpeech")
        SetCVar("Sound_EnableErrorSpeech", "0")
    end
    if CW.ShowUI then CW.ShowUI() end
end

local function StopScanning()
    if not CW.active then return end
    CW.active = false
    ClearPending()
    if scanTicker then scanTicker:Cancel(); scanTicker = nil end
    if ageTicker then ageTicker:Cancel(); ageTicker = nil end
    if rosterTicker then rosterTicker:Cancel(); rosterTicker = nil end
    if savedErrorSpeechCVar ~= nil then
        SetCVar("Sound_EnableErrorSpeech", savedErrorSpeechCVar)
        savedErrorSpeechCVar = nil
    end
    if CW.HideUI then CW.HideUI() end
end

local function EvaluateActive()
    if InZone() and InRelevantGroup() then
        StartScanning()
    else
        StopScanning()
    end
end

-- ============================================================
-- EVENTS
-- ============================================================
local f = CreateFrame("Frame", "CloakWatchEventFrame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("INSPECT_READY")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        EvaluateActive()
    elseif event == "GROUP_ROSTER_UPDATE" then
        if CW.active then RefreshRoster() end
        EvaluateActive()
    elseif event == "INSPECT_READY" then
        local guid = ...
        OnInspectReady(guid)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        if not slot or slot == CLOAK_SLOT then
            UpdateOwnCloak()
        end
    end
end)

-- ============================================================
-- SLASH COMMANDS
-- ============================================================
SLASH_CLOAKWATCH1 = "/cloakwatch"
SLASH_CLOAKWATCH2 = "/cw"
SlashCmdList["CLOAKWATCH"] = function(msg)
    msg = (msg or ""):lower()
    msg = msg:match("^%s*(.-)%s*$") -- trim

    if msg == "rescan" then
        for _, data in pairs(CW.players) do
            data.status   = "unscanned"
            data.lastScan = 0
        end
        if CW.RefreshUI then CW.RefreshUI() end
        print("|cff33ff99CloakWatch|r: requeued all raid members for scanning.")
    elseif msg == "toggle" or msg == "" then
        if CW.ToggleUI then CW.ToggleUI() end
    else
        print("|cff33ff99CloakWatch|r: /cw to toggle the window, /cw rescan to requeue everyone.")
    end
end
