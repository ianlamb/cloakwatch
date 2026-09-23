local CW = CloakWatch

-- ============================================================
-- PEER SHARING
-- ============================================================
-- Every client with CloakWatch broadcasts the results of its own inspects over
-- the raid addon channel, and merges anything fresher than what it already
-- knows. Because Core.lua skips re-scanning fresh on/off results, the raid
-- naturally splits the inspect work instead of every client scanning everyone.
--
-- Wire format (pipe-delimited, no versioning needed yet):
--   R|<name>|<1=on,0=off>|<age in seconds>   a result; age because GetTime() isn't shared across clients
--   H                                         "hello" - a client that just started scanning asks peers to share what they know

local PREFIX          = "CloakWatch"
local HELLO_REPLY_GAP = 15   -- answer at most one hello per this many seconds
local REPLY_SPACING   = 0.2  -- stagger snapshot messages to stay under addon-message throttling

CW.peers = {}   -- [shortName] = GetTime() of last message heard
local lastHelloReply = 0

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

local function Send(msg)
    if not (CW.active and IsInRaid()) then return end
    C_ChatInfo.SendAddonMessage(PREFIX, msg, "RAID")
end

function CW.BroadcastStatus(name)
    local data = CW.players[name]
    if not data or (data.status ~= "on" and data.status ~= "off") then return end
    local age = math.max(0, math.floor(GetTime() - data.lastScan))
    Send(string.format("R|%s|%d|%d", name, data.status == "on" and 1 or 0, age))
end

function CW.SendHello()
    Send("H")
end

local function ApplyReport(name, status, age)
    if name == UnitName("player") then return end -- our own cloak is always read directly
    local lastScan = GetTime() - age

    local cached = CW.shared[name]
    if not cached or cached.lastScan < lastScan then
        CW.shared[name] = { status = status, lastScan = lastScan }
    end

    local data = CW.players[name]
    if data and data.lastScan < lastScan then
        data.status   = status
        data.lastScan = lastScan
        if CW.RefreshUI then CW.RefreshUI() end
    end
end

local function ScheduleSnapshotReply()
    local now = GetTime()
    if now - lastHelloReply < HELLO_REPLY_GAP then return end
    lastHelloReply = now

    -- Random initial delay so a full raid doesn't answer one hello simultaneously.
    C_Timer.After(0.5 + math.random() * 3.5, function()
        local i = 0
        for name, data in pairs(CW.players) do
            if data.status == "on" or data.status == "off" then
                i = i + 1
                C_Timer.After(i * REPLY_SPACING, function() CW.BroadcastStatus(name) end)
            end
        end
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(_, _, prefix, text, _, sender)
    if prefix ~= PREFIX or not CW.active or type(text) ~= "string" then return end

    local short = Ambiguate(sender, "short")
    if short == UnitName("player") then return end
    CW.peers[short] = GetTime()

    local kind, name, st, age = strsplit("|", text)
    if kind == "H" then
        ScheduleSnapshotReply()
    elseif kind == "R" then
        st, age = tonumber(st), tonumber(age)
        if name and #name <= 24 and (st == 0 or st == 1)
           and age and age >= 0 and age < CW.OUTDATED_AFTER then
            ApplyReport(name, st == 1 and "on" or "off", age)
        end
    end
end)

function CW.PeerCount()
    local n, now = 0, GetTime()
    for _, t in pairs(CW.peers) do
        if now - t < 600 then n = n + 1 end
    end
    return n
end
