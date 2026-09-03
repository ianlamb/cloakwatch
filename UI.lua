local ADDON_NAME = ...
local CW = CloakWatch

-- ============================================================
-- CONFIG
-- ============================================================
local ROW_HEIGHT       = 16
local ICON_SIZE        = 14
local LIST_COLUMNS     = 2                                   -- names are laid out across this many columns
local COL_WIDTH        = 112                                 -- width of one name column (icon + text)
local LIST_PAD         = 8                                   -- inner horizontal padding on each side of the list
local FRAME_WIDTH      = LIST_COLUMNS * COL_WIDTH + LIST_PAD * 2
local BAR_HEIGHT       = 24   -- the draggable header bar is always exactly this tall

local STATE_INFO = {
    unscanned = { icon = "Interface\\Common\\help-i",                r = 0.6, g = 0.6, b = 0.6, label = "not yet scanned" },
    outdated  = { icon = "Interface\\RaidFrame\\ReadyCheck-Waiting", r = 1.0, g = 0.82,b = 0.0, label = "outdated"        },
    off       = { icon = "Interface\\RaidFrame\\ReadyCheck-NotReady",r = 1.0, g = 0.2, b = 0.2, label = "CLOAK OFF"      },
    on        = { icon = "Interface\\RaidFrame\\ReadyCheck-Ready",  r = 0.2, g = 1.0, b = 0.2, label = "cloak on"        },
}

-- Display order (most dangerous first), independent of scan priority in Core.lua
local DISPLAY_ORDER = { off = 1, outdated = 2, unscanned = 3, on = 4 }

-- Overall summary status -> color, used for the minimized indicator dot.
-- Severity order mirrors Core.lua's scan priority: off > unscanned > outdated > on.
local SUMMARY_COLOR = {
    off       = { 1.0, 0.2, 0.2 },  -- someone confirmed without a cloak
    unscanned = { 1.0, 0.65, 0.0 }, -- nobody off, but someone never scanned (true unknown)
    outdated  = { 1.0, 0.82, 0.0 }, -- nobody off/unscanned, but someone's scan is stale
    on        = { 0.2, 1.0, 0.2 },  -- everyone tracked has their cloak on
    none      = { 0.6, 0.6, 0.6 },  -- nobody being tracked yet
}

-- ============================================================
-- FRAME
-- ============================================================
local PANEL_BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- The draggable header bar. Fixed size - it never resizes, so it's the one
-- thing you position and it stays put through every roster change and minimize.
local main = CreateFrame("Frame", "CloakWatchFrame", UIParent, "BackdropTemplate")
main:SetSize(FRAME_WIDTH, BAR_HEIGHT)
main:SetPoint("TOPLEFT", 200, -150)
main:SetMovable(true)
main:EnableMouse(true)
main:SetClampedToScreen(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", main.StartMoving)
main:SetScript("OnDragStop", function()
    main:StopMovingOrSizing()
    -- Re-pin to an explicit TOPLEFT point so the anchor is guaranteed fixed
    -- regardless of what anchor the drag itself left behind.
    local left, top = main:GetLeft(), main:GetTop()
    main:ClearAllPoints()
    main:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    if CW.SavePosition then CW.SavePosition() end
    -- Crossing the screen's midline can flip which way the list should grow.
    if CW.AnchorList then CW.AnchorList() end
end)
main:SetBackdrop(PANEL_BACKDROP)
main:SetBackdropColor(0, 0, 0, 0.85)
main:Hide()

CW.minimized = false

-- Overall-status dot, pinned to the vertical middle of the bar.
local statusDot = main:CreateTexture(nil, "OVERLAY")
statusDot:SetSize(10, 10)
statusDot:SetPoint("LEFT", main, "LEFT", 8, 0)
statusDot:SetColorTexture(0.6, 0.6, 0.6, 1)

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", statusDot, "RIGHT", 5, 0)
title:SetText("CloakWatch")

local HEADER_BTN_SIZE = 16

local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
close:SetSize(HEADER_BTN_SIZE, HEADER_BTN_SIZE) -- template defaults to ~32px, too big for the bar
close:SetPoint("RIGHT", main, "RIGHT", -4, 0)
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
-- LIST FRAME  (holds the name rows; resizes freely without moving `main`)
-- ============================================================
local listFrame = CreateFrame("Frame", "CloakWatchListFrame", main, "BackdropTemplate")
listFrame:SetWidth(FRAME_WIDTH)
listFrame:SetBackdrop(PANEL_BACKDROP)
listFrame:SetBackdropColor(0, 0, 0, 0.85)
listFrame:Hide()

-- Grow the list away from whichever screen edge the bar is nearest: drop it
-- downward when the bar sits in the top half of the screen, stack it upward
-- when the bar is in the bottom half. Keeps the list on-screen wherever the
-- bar is parked, with the bar itself as the fixed reference point.
function CW.AnchorList()
    local _, cy = main:GetCenter()
    local growUp = cy ~= nil and cy < (GetScreenHeight() / 2)
    listFrame:ClearAllPoints()
    if growUp then
        listFrame:SetPoint("BOTTOMLEFT", main, "TOPLEFT", 0, -1)
    else
        listFrame:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 0, 1)
    end
end

-- ============================================================
-- ROWS
-- ============================================================
local rows = {}

local function GetRow(i)
    if rows[i] then return rows[i] end

    local row = CreateFrame("Frame", nil, listFrame)
    row:SetSize(COL_WIDTH, ROW_HEIGHT)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", 0, 0)
    row.icon = icon

    -- Anchored on both sides so the name is width-clamped to its column and
    -- truncates with an ellipsis instead of bleeding into the next column.
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
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

-- off > unscanned > outdated > on > none
local function SummaryStatus()
    local any, hasOff, hasUnscanned, hasOutdated = false, false, false, false
    for _, data in pairs(CW.players) do
        any = true
        if data.status == "off" then
            hasOff = true
        elseif data.status == "unscanned" then
            hasUnscanned = true
        elseif data.status == "outdated" then
            hasOutdated = true
        end
    end
    if not any then return "none" end
    if hasOff then return "off" end
    if hasUnscanned then return "unscanned" end
    if hasOutdated then return "outdated" end
    return "on"
end

-- ============================================================
-- PUBLIC API (called from Core.lua)
-- ============================================================
function CW.RefreshUI()
    local color = SUMMARY_COLOR[SummaryStatus()]
    statusDot:SetColorTexture(color[1], color[2], color[3], 1)

    local names = SortedNames()

    -- The bar never changes size; the list frame is hidden outright when
    -- minimized or when there's nobody to show (the status dot still reports).
    if CW.minimized or #names == 0 then
        for _, row in ipairs(rows) do row:Hide() end
        listFrame:Hide()
        return
    end

    CW.AnchorList()

    -- Row-major fill: index 1 is top-left, then rightward, then down. Keeps the
    -- highest-severity names (sorted first) in the top-left reading position.
    for i, name in ipairs(names) do
        local data = CW.players[name]
        local info = STATE_INFO[data.status] or STATE_INFO.unscanned
        local row = GetRow(i)

        local col    = (i - 1) % LIST_COLUMNS
        local rowIdx = math.floor((i - 1) / LIST_COLUMNS)

        row.icon:SetTexture(info.icon)
        row.text:SetText(name)
        row.text:SetTextColor(info.r, info.g, info.b)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", listFrame, "TOPLEFT",
            LIST_PAD + col * COL_WIDTH,
            -6 - rowIdx * ROW_HEIGHT)
        row:Show()
    end

    for i = #names + 1, #rows do
        rows[i]:Hide()
    end

    local usedRows = math.ceil(#names / LIST_COLUMNS)
    listFrame:SetHeight(12 + usedRows * ROW_HEIGHT)
    listFrame:Show()
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
    if CloakWatchDB then CloakWatchDB.minimized = CW.minimized end
    UpdateMinimizeButtonTexture()
    CW.RefreshUI()
end

-- ============================================================
-- PERSISTENCE (SavedVariables: CloakWatchDB)
-- ============================================================
-- Mirrors the drag handler's anchor: frame TOPLEFT -> UIParent BOTTOMLEFT.
local DEFAULT_POINT = { "TOPLEFT", "TOPLEFT", 200, -150 }

function CW.SavePosition()
    if not CloakWatchDB then return end
    local left, top = main:GetLeft(), main:GetTop()
    if left and top then
        CloakWatchDB.point = { "TOPLEFT", "BOTTOMLEFT", left, top }
    end
end

local function RestoreState()
    CloakWatchDB = CloakWatchDB or {}
    local p = CloakWatchDB.point or DEFAULT_POINT
    main:ClearAllPoints()
    main:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    CW.minimized = CloakWatchDB.minimized and true or false
    UpdateMinimizeButtonTexture()
    CW.RefreshUI()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if name == ADDON_NAME then
        RestoreState()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
