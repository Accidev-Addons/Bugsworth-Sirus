-----------------------------------------------------------------------
-- BUGSWORTH · minimap.lua
-- Simple minimap button (no LDB dependency)
-----------------------------------------------------------------------

local BC = _G.Bugsworth
if not BC then return end

local ICON_NORMAL = "Interface\\AddOns\\!Bugsworth\\Media\\icon"
local ICON_RED    = "Interface\\AddOns\\!Bugsworth\\Media\\icon_red"

local button = CreateFrame("Button", "BugsworthMinimapButton", Minimap)
button:SetWidth(33)
button:SetHeight(33)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:SetMovable(true)
button:RegisterForDrag("LeftButton")
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

-- Icon texture
local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetWidth(21)
icon:SetHeight(21)
icon:SetTexture(ICON_NORMAL)
icon:SetPoint("CENTER", 0, 1)
button.icon = icon

-- Border overlay
local border = button:CreateTexture(nil, "OVERLAY")
border:SetWidth(54)
border:SetHeight(54)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetPoint("TOPLEFT", 0, 0)

-----------------------------------------------------------------------
-- Position on minimap edge
-----------------------------------------------------------------------
local function updatePosition(angle)
    local x = 80 * math.cos(angle)
    local y = 80 * math.sin(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function getAngle()
    local cx, cy = Minimap:GetCenter()
    local mx, my = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    return math.atan2(my / scale - cy, mx / scale - cx)
end

-- Drag handlers
local isDragging = false
button:SetScript("OnDragStart", function(self)
    isDragging = true
    self:SetScript("OnUpdate", function()
        local angle = getAngle()
        BugsworthDB.minimapAngle = angle
        updatePosition(angle)
    end)
end)

button:SetScript("OnDragStop", function(self)
    isDragging = false
    self:SetScript("OnUpdate", nil)
end)

-----------------------------------------------------------------------
-- Click handlers
-----------------------------------------------------------------------
button:SetScript("OnClick", function(self, btn)
    if btn == "RightButton" then
        InterfaceOptionsFrame_OpenToCategory("Bugsworth")
        InterfaceOptionsFrame_OpenToCategory("Bugsworth")
    else
        if IsShiftKeyDown() then
            ReloadUI()
        elseif IsAltKeyDown() then
            BC:Reset()
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: Все ошибки очищены.")
            BC:OnErrorCountChanged()
            -- Refresh viewer if it's open
            if BugsworthFrame and BugsworthFrame:IsShown() then
                BC:OpenViewer()
            end
        elseif BugsworthFrame and BugsworthFrame:IsShown() then
            BC:CloseViewer()
        else
            BC:OpenViewer()
        end
    end
end)

-----------------------------------------------------------------------
-- Tooltip
-----------------------------------------------------------------------
button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cFFEDA55fBugs|rworth")

    local sessionId = BC:GetSessionId()
    local errs = BC:GetErrors(sessionId)
    if #errs == 0 then
        GameTooltip:AddLine("Нет ошибок за сессию!", 0.2, 1, 0.2)
    else
        GameTooltip:AddLine(string.format("Ошибок за сессию: %d", #errs), 1, 0.8, 0.2)
        local pattern = "^(.-)\n"
        local count = 0
        for _, err in ipairs(errs) do
            local m = err.message
            if type(m) == "table" then m = table.concat(m, "") end
            local firstLine = m:match(pattern) or m:sub(1, 80)
            -- Truncate long lines
            if firstLine:len() > 60 then
                firstLine = firstLine:sub(1, 60) .. "..."
            end
            GameTooltip:AddLine(string.format("  %dx %s", err.counter or 1, firstLine), 0.8, 0.8, 0.8, true)
            count = count + 1
            if count >= 8 then
                local remaining = #errs - count
                if remaining > 0 then
                    GameTooltip:AddLine(string.format("  ... и ещё %d", remaining), 0.6, 0.6, 0.6)
                end
                break
            end
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffeda55fЛКМ|r Открыть просмотрщик", 0.5, 0.8, 1)
    GameTooltip:AddLine("|cffeda55fShift+ЛКМ|r Перезагрузить UI", 0.5, 0.8, 1)
    GameTooltip:AddLine("|cffeda55fAlt+ЛКМ|r Очистить ошибки", 0.5, 0.8, 1)
    GameTooltip:AddLine("|cffeda55fПКМ|r Настройки", 0.5, 0.8, 1)
    GameTooltip:Show()
end)

button:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-----------------------------------------------------------------------
-- Error count badge (bottom-right corner of button)
-----------------------------------------------------------------------
local badge = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
badge:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 4)
badge:SetJustifyH("RIGHT")
badge:SetTextColor(1, 1, 1, 1)
badge:Hide()

-----------------------------------------------------------------------
-- Update icon state (called when error count changes)
-----------------------------------------------------------------------
function BC:OnErrorCountChanged()
    local sessionId = BC:GetSessionId()
    local errs = BC:GetErrors(sessionId)
    local count = #errs
    local hasErrors = count > 0
    icon:SetTexture(hasErrors and ICON_RED or ICON_NORMAL)
    -- Update badge
    if hasErrors then
        badge:SetText(count)
        badge:Show()
    else
        badge:Hide()
    end
end

-----------------------------------------------------------------------
-- Initialize position on login
-----------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    local angle = BugsworthDB.minimapAngle or 4.4  -- Default: ~252 degrees
    updatePosition(angle)

    -- Initial icon update
    BC:OnErrorCountChanged()
end)
