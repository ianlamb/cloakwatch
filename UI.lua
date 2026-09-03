local CW = CloakWatch

-- ============================================================
-- CONFIG
-- ============================================================
local ROW_HEIGHT       = 16
local ICON_SIZE        = 14
local FRAME_WIDTH      = 210
local MINIMIZED_HEIGHT = 24

local STATE_INFO = {
    unscanned = { icon = "Interface\\Common\\help-i",                r = 0.6, g = 0.6, b = 0.6, label = "not yet scanned" },
    outdated  = { icon = "Interface\\RaidFrame\\ReadyCheck-Waiting", r = 1.0, g = 0.82,b = 0.0, label = "outdated"        },
    off       = { icon = "Interface\\RaidFrame\\ReadyCheck-NotReady",r = 1.0, g = 0.2, b = 0.2, label = "CLOAK OFF"      },
    on        = { icon = "Interface\\RaidFrame\\ReadyCheck-Ready",  r = 0.2, g = 1.0, b = 0.2, label = "cloak on"        },
}

-- Display order (most dangerous first), independent of scan priority in Core.lua
local DISPLAY_ORDER = { off = 1, outdated = 2, unscanned = 3, on = 4 }

-- Overall summary status -> color, used for the minimized indicator dot
local SUMMARY_COLOR = {
    off        = { 1.0, 0.2, 0.2 }, -- someone confirmed without a cloak
    incomplete = { 1.0, 0.65, 0.0 }, -- nobody off, but someone unscanned/outdated
    on         = { 0.2, 1.0, 0.2 }, -- everyone tracked has their cloak on
    none       = { 0.6, 0.6, 0.6 }, -- nobody being tracked yet
}

-- ============================================================
-- FRAME
-- ============================================================
local main = CreateFrame("Frame", "CloakWatchFrame", UIParent, "BackdropTemplate")
main:SetSize(FRAME_WIDTH, 40)
main:SetPoint("TOPLEFT", 200, -150)
main:SetMovable(true)
main:EnableMouse(true)
main:SetClampedToScreen(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", main.StartMoving)
main:SetScript("OnDragStop", function()
    main:StopMovingOrSizing()
    -- Re-pin to an explicit TOPLEFT point so the top edge is guaranteed fixed
    -- regardless of what anchor the drag itself left behind.
    local left, top = main:GetLeft(), main:GetTop()
    main:ClearAllPoints()
    main:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end)
main:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
main:SetBackdropColor(0, 0, 0, 0.8)
main:Hide()

CW.minimized = false

-- Small colored dot showing overall status - visible whether minimized or not.
local statusDot = main:CreateTexture(nil, "OVERLAY")
statusDot:SetSize(10, 10)
statusDot:SetPoint("LEFT", main, "TOPLEFT", 8, -12)
statusDot:SetColorTexture(0.6, 0.6, 0.6, 1)

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -6)
title:SetText("CloakWatch")

local HEADER_BTN_SIZE = 16

local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
close:SetSize(HEADER_BTN_SIZE, HEADER_BTN_SIZE) -- template defaults to ~32px, too big for the minimized bar
close:SetPoint("TOPRIGHT", -4, -4)
close:SetScript("OnClick", function() main:Hide() end)

local minimizeBtn = CreateFrame("Button", nil, main)
minimizeBtn:SetSize(HEADER_BTN_SIZE, HEADER_BTN_SIZE)
minimizeBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Up")
minimizeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Down")
minimizeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Highlight")
minimizeBtn:SetScript("OnClick", function() CW.ToggleMinimize() end)

local function UpdateMinimizeButtonTexture()
    if CW.minimized then
        minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-ExpandButton-Up")
        minimizeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-ExpandButton-Down")
        minimizeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-ExpandButton-Highlight")
    else
        minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Up")
        minimizeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Down")
        minimizeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Highlight")
    end
end

-- ============================================================
-- ROWS
-- ============================================================
local rows = {}

local function GetRow(i)
    if rows[i] then return rows[i] end

    local row = CreateFrame("Frame", nil, main)
    row:SetSize(FRAME_WIDTH - 16, ROW_HEIGHT)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", 0, 0)
    row.icon = icon

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    text:SetJustifyH("LEFT")
    row.text = text

    rows[i] = row
    return row
end

local function SortedNames()
    local names = {}
    for name in pairs(CW.players) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
        local da, db = CW.players[a], CW.players[b]
        local oa = DISPLAY_ORDER[da.status] or 9
        local ob = DISPLAY_ORDER[db.status] or 9
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return names
end

-- off > incomplete (unscanned/outdated) > on > none
local function SummaryStatus()
    local any, hasOff, hasIncomplete = false, false, false
    for _, data in pairs(CW.players) do
        any = true
        if data.status == "off" then
            hasOff = true
        elseif data.status == "unscanned" or data.status == "outdated" then
            hasIncomplete = true
        end
    end
    if not any then return "none" end
    if hasOff then return "off" end
    if hasIncomplete then return "incomplete" end
    return "on"
end

-- ============================================================
-- PUBLIC API (called from Core.lua)
-- ============================================================
function CW.RefreshUI()
    local color = SUMMARY_COLOR[SummaryStatus()]
    statusDot:SetColorTexture(color[1], color[2], color[3], 1)

    if CW.minimized then
        for _, row in ipairs(rows) do row:Hide() end
        main:SetHeight(MINIMIZED_HEIGHT)
        return
    end

    local names = SortedNames()

    for i, name in ipairs(names) do
        local data = CW.players[name]
        local info = STATE_INFO[data.status] or STATE_INFO.unscanned
        local row = GetRow(i)

        row.icon:SetTexture(info.icon)
        row.text:SetText(name)
        row.text:SetTextColor(info.r, info.g, info.b)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 10, -24 - (i - 1) * ROW_HEIGHT)
        row:Show()
    end

    for i = #names + 1, #rows do
        rows[i]:Hide()
    end

    main:SetHeight(30 + math.max(#names, 1) * ROW_HEIGHT)
end

function CW.ShowUI()
    main:Show()
    CW.RefreshUI()
end

function CW.HideUI()
    main:Hide()
end

function CW.ToggleUI()
    if main:IsShown() then
        main:Hide()
    else
        CW.ShowUI()
    end
end

function CW.ToggleMinimize()
    CW.minimized = not CW.minimized
    UpdateMinimizeButtonTexture()
    CW.RefreshUI()
end
