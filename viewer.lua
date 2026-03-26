-----------------------------------------------------------------------
-- BUGSWORTH · viewer.lua
-- Two-panel GUI: addon-grouped navigation + error detail viewer
-----------------------------------------------------------------------

local BC = _G.Bugsworth
if not BC then return end

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------
local viewerFrame = nil
local currentContents = nil   -- flat list of errors being viewed
local currentSession = nil    -- session filter (nil = all)
local selectedError = nil     -- currently displayed error object
local searchFilter = ""       -- active search string
local initialized = false

-- UI element refs
local navScroll, navContainer, detailScroll, textArea
local countLabel, sessionLabel
local nextButton, prevButton, copyButton
local searchBox, copyFlash
local tabs

-- Accordion state: which addons are expanded
local expandedAddons = {}

-----------------------------------------------------------------------
-- Error formatting + syntax highlighting
-----------------------------------------------------------------------
function BC:FormatError(err)
    local m = err.message
    if type(m) == "table" then m = table.concat(m, "") end
    return string.format("|cff999999%dx|r %s", err.counter or 1, BC:ColorError(m or ""))
end

function BC:ColorError(err)
    local ret = err
    ret = ret:gsub("|([^chHr])", "||%1")
    ret = ret:gsub("|$", "||")
    ret = ret:gsub("\nLocals:\n", "\n|cFFFFFFFFLocals:|r\n")
    ret = ret:gsub("[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\\[Aa][Dd][Dd][Oo][Nn][Ss]\\", "")
    ret = ret:gsub("{%\n +%}", "{}")
    ret = ret:gsub("([ ]-)([%a_][%a_%d]+) = ", "%1|cffffff80%2|r = ")
    ret = ret:gsub("= (%d+)\n", "= |cffff7fff%1|r\n")
    ret = ret:gsub("<function>", "|cffffea00<function>|r")
    ret = ret:gsub("<table>", "|cffffea00<table>|r")
    ret = ret:gsub("= nil\n", "= |cffff7f7fnil|r\n")
    ret = ret:gsub("= true\n", "= |cffff9100true|r\n")
    ret = ret:gsub("= false\n", "= |cffff9100false|r\n")
    ret = ret:gsub("= \"([^\n]+)\"\n", "= |cff8888ff\"%1\"|r\n")
    ret = ret:gsub("defined %@(.-):(%d+)", "@ |cffeda55f%1|r:|cff00ff00%2|r:")
    ret = ret:gsub("\n(.-):(%d+):", "\n|cffeda55f%1|r:|cff00ff00%2|r:")
    ret = ret:gsub("%-%d+%p+.-%\\", "|cffffff00%1|cffeda55f")
    ret = ret:gsub("%(.-%)", "|cff999999%1|r")
    ret = ret:gsub("([`'])(.-)([`'])", "|cff8888ff%1%2%3|r")
    return ret
end

-----------------------------------------------------------------------
-- Get errors for a session or all
-----------------------------------------------------------------------
function BC:GetErrors(sessionId)
    local db = BC:GetDB()
    if not sessionId then return db end
    local result = {}
    for _, err in ipairs(db) do
        if err.session == sessionId then
            result[#result + 1] = err
        end
    end
    return result
end

-----------------------------------------------------------------------
-- Group errors by addon, respecting ignore list and search filter
-----------------------------------------------------------------------
local function groupByAddon(errors, filter)
    local groups = {}      -- { addonName = { errors = {}, count = 0 } }
    local order = {}       -- insertion order
    local filterLow = filter and filter:lower() or ""

    for _, err in ipairs(errors) do
        local addon = BC:GetAddonFromError(err)

        -- Skip ignored addons
        if not BC:IsAddonIgnored(addon) then
            -- Apply search filter
            local passesFilter = true
            if filterLow ~= "" then
                local m = err.message
                if type(m) == "table" then m = table.concat(m, "") end
                passesFilter = (addon:lower():find(filterLow, 1, true) ~= nil) or
                               (m and m:lower():find(filterLow, 1, true) ~= nil)
            end

            if passesFilter then
                if not groups[addon] then
                    groups[addon] = { errors = {}, count = 0, totalHits = 0 }
                    order[#order + 1] = addon
                end
                groups[addon].errors[#groups[addon].errors + 1] = err
                groups[addon].count = groups[addon].count + 1
                groups[addon].totalHits = groups[addon].totalHits + (err.counter or 1)
            end
        end
    end

    -- Sort by count descending (top offenders first)
    table.sort(order, function(a, b) return groups[a].totalHits > groups[b].totalHits end)

    return groups, order
end

-----------------------------------------------------------------------
-- Get first line of an error message for nav display
-----------------------------------------------------------------------
local function getFirstLine(err)
    local m = err.message
    if type(m) == "table" then m = table.concat(m, "") end
    if type(m) ~= "string" then return "?" end
    local first = m:match("^(.-)\n") or m:sub(1, 80)
    -- Strip Interface\AddOns\ prefix for brevity
    first = first:gsub("[Ii]nterface\\[Aa]dd[Oo]ns\\", "")
    if first:len() > 50 then first = first:sub(1, 50) .. "..." end
    return first
end

-----------------------------------------------------------------------
-- Session navigation
-----------------------------------------------------------------------
local function findPreviousSessionWithBugs(current)
    for i = (current - 1), 0, -1 do
        local bugs = BC:GetErrors(i)
        if #bugs > 0 then return i, bugs end
    end
end

-----------------------------------------------------------------------
-- Update the right-hand detail panel
-----------------------------------------------------------------------
local function updateDetail()
    if not selectedError then
        if textArea then textArea:SetText("|cff44ff44No bugs captured. Nice work!|r") end
        if countLabel then countLabel:SetText("") end
        if sessionLabel then sessionLabel:SetText("") end
        return
    end

    local eo = selectedError
    local source = eo.source and ("Sent by " .. eo.source) or "Local"
    local timeStr = (eo.session == BC:GetSessionId()) and "Today" or (eo.time or "unknown")
    sessionLabel:SetText(string.format(
        "%s - |cffff4411%s|r - Session |cff44ff44%d|r",
        timeStr, source, eo.session
    ))

    -- Find position in currentContents
    local idx, total = 0, #currentContents
    for i, e in ipairs(currentContents) do
        if e == eo then idx = i; break end
    end
    if idx == 0 then idx = 1 end
    countLabel:SetText(string.format("%d/%d", idx, total))

    textArea:SetText(BC:FormatError(eo))

    nextButton[idx >= total and "Disable" or "Enable"](nextButton)
    prevButton[idx <= 1 and "Disable" or "Enable"](prevButton)
end

-----------------------------------------------------------------------
-- Navigate prev/next in currentContents relative to selectedError
-----------------------------------------------------------------------
local function navigateError(delta)
    if not currentContents or #currentContents == 0 then return end
    local idx = 1
    for i, e in ipairs(currentContents) do
        if e == selectedError then idx = i; break end
    end
    idx = idx + delta
    if idx < 1 then idx = 1 end
    if idx > #currentContents then idx = #currentContents end
    selectedError = currentContents[idx]
    updateDetail()
end

-----------------------------------------------------------------------
-- Rebuild the left nav panel
-----------------------------------------------------------------------
local NAV_ROW_HEIGHT = 14
local NAV_ADDON_HEIGHT = 20
local NAV_INDENT = 12

-- Frame pool: reuse frames instead of creating/leaking new ones each rebuild
local navFramePool = {}
local navFrameActive = 0

local function acquireNavFrame()
    navFrameActive = navFrameActive + 1
    local f = navFramePool[navFrameActive]
    if not f then
        f = CreateFrame("Button", nil, navContainer)
        f.text = f:CreateFontString(nil, "OVERLAY")
        f.text:SetPoint("LEFT", 2, 0)
        f.text:SetPoint("RIGHT", -2, 0)
        f.text:SetJustifyH("LEFT")
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        navFramePool[navFrameActive] = f
    end
    f:ClearAllPoints()
    f:SetScript("OnClick", nil)
    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)
    f:RegisterForClicks("LeftButtonUp")
    f:Show()
    return f
end

local function releaseAllNavFrames()
    for i = 1, navFrameActive do
        navFramePool[i]:Hide()
    end
    navFrameActive = 0
end

local function rebuildNav()
    if not navContainer then return end

    releaseAllNavFrames()

    local errors = currentContents or {}
    local groups, order = groupByAddon(errors, searchFilter)

    local yOffset = 0
    local navWidth = navContainer:GetWidth() - 4
    if navWidth < 20 then navWidth = 140 end  -- guard against pre-layout zero width

    for _, addonName in ipairs(order) do
        local group = groups[addonName]

        -- Addon header
        local header = acquireNavFrame()
        header:SetHeight(NAV_ADDON_HEIGHT)
        header:SetWidth(navWidth)
        header:SetPoint("TOPLEFT", navContainer, "TOPLEFT", 2, -yOffset)

        header.text:SetFontObject(GameFontNormalSmall)
        local arrow = expandedAddons[addonName] and "|cffcc9933v|r " or "|cffcc9933>|r "
        header.text:SetText(string.format("%s|cffeda55f%s|r |cff999999(%d)|r", arrow, addonName, group.totalHits))

        header.bg:SetVertexColor(0.3, 0.2, 0.1, 0.3)

        header:SetScript("OnEnter", function(self)
            header.bg:SetVertexColor(0.5, 0.3, 0.1, 0.5)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(addonName)
            GameTooltip:AddLine(string.format("%d unique errors, %d total hits", group.count, group.totalHits), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("|cffeda55fClick|r to expand/collapse", 0.5, 0.8, 1)
            GameTooltip:AddLine("|cffeda55fRight-click|r to ignore addon", 0.5, 0.8, 1)
            GameTooltip:Show()
        end)
        header:SetScript("OnLeave", function()
            header.bg:SetVertexColor(0.3, 0.2, 0.1, 0.3)
            GameTooltip:Hide()
        end)

        header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        header:SetScript("OnClick", function(self, btn)
            if btn == "RightButton" then
                BC:SetAddonIgnored(addonName, true)
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cFFEDA55fBugs|rworth: Now ignoring errors from |cffff8800%s|r. Remove via /bugs config.",
                    addonName
                ))
                rebuildNav()
            else
                expandedAddons[addonName] = not expandedAddons[addonName]
                rebuildNav()
            end
        end)

        yOffset = yOffset + NAV_ADDON_HEIGHT

        -- Error rows (if expanded)
        if expandedAddons[addonName] then
            for _, err in ipairs(group.errors) do
                local row = acquireNavFrame()
                row:SetHeight(NAV_ROW_HEIGHT)
                row:SetWidth(navWidth - NAV_INDENT)
                row:SetPoint("TOPLEFT", navContainer, "TOPLEFT", 2 + NAV_INDENT, -yOffset)

                row.text:SetFontObject(GameFontHighlightExtraSmall)
                local prefix = (err.counter and err.counter > 1) and string.format("|cff999999%dx|r ", err.counter) or ""
                row.text:SetText(prefix .. getFirstLine(err))

                if err == selectedError then
                    row.bg:SetVertexColor(0.2, 0.4, 0.6, 0.6)
                else
                    row.bg:SetVertexColor(0, 0, 0, 0)
                end

                row:SetScript("OnEnter", function()
                    if err ~= selectedError then
                        row.bg:SetVertexColor(0.2, 0.3, 0.4, 0.4)
                    end
                end)
                row:SetScript("OnLeave", function()
                    if err ~= selectedError then
                        row.bg:SetVertexColor(0, 0, 0, 0)
                    end
                end)

                row:SetScript("OnClick", function()
                    selectedError = err
                    updateDetail()
                    rebuildNav()
                end)

                yOffset = yOffset + NAV_ROW_HEIGHT
            end
        end
    end

    -- Set scroll content height
    navContainer:SetHeight(math.max(yOffset, 1))
end

-----------------------------------------------------------------------
-- Update the entire viewer (nav + detail)
-----------------------------------------------------------------------
local function fullRefresh()
    rebuildNav()
    if currentContents and #currentContents > 0 then
        if not selectedError then
            selectedError = currentContents[#currentContents]
        end
    else
        selectedError = nil
    end
    updateDetail()
end

-----------------------------------------------------------------------
-- Tab click handler
-----------------------------------------------------------------------
local function setActiveTab(tab)
    if not tab.bugs then
        -- All bugs
        currentContents = BC:GetErrors()
        currentSession = nil
    elseif tab.bugs == 0 then
        -- Current session
        local session = BC:GetSessionId()
        currentContents = BC:GetErrors(session)
        currentSession = session
    else
        -- Previous session
        local session = tab.bugs == -1 and BC:GetSessionId() or tab.bugs
        local s, b = findPreviousSessionWithBugs(session)
        if not s or not b or #b == 0 then
            tab.bugs = -1
            return
        end
        tab.bugs, currentContents = s, b
        currentSession = s
    end

    for _, t in ipairs(tabs) do
        if t == tab then
            t:SetNormalFontObject(GameFontHighlight)
        else
            t:SetNormalFontObject(GameFontNormal)
        end
    end

    selectedError = nil
    expandedAddons = {}
    BC:OpenViewer()
end

-----------------------------------------------------------------------
-- Create the viewer frame (lazy init)
-----------------------------------------------------------------------
local function createViewer()
    local WINDOW_W, WINDOW_H = 700, 420
    local NAV_W = 170
    local TOOLBAR_H = 28

    local window = CreateFrame("Frame", "BugsworthFrame", UIParent)
    UIPanelWindows["BugsworthFrame"] = { area = "center", pushable = 0, whileDead = 1 }
    HideUIPanel(window)

    window:SetFrameStrata("FULLSCREEN_DIALOG")
    window:SetWidth(WINDOW_W)
    window:SetHeight(WINDOW_H)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetScript("OnShow", function() PlaySound("igQuestLogOpen") end)
    window:SetScript("OnHide", function() PlaySound("igQuestLogClose") end)

    -- Dark backdrop
    window:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    window:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
    window:SetBackdropBorderColor(0.6, 0.2, 0.2, 0.9)

    -- Title bar
    local titleBg = window:CreateTexture(nil, "BORDER")
    titleBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    titleBg:SetPoint("TOPLEFT", 6, -6)
    titleBg:SetPoint("TOPRIGHT", -6, -6)
    titleBg:SetHeight(22)
    titleBg:SetVertexColor(0.4, 0.1, 0.1, 0.8)

    local titleText = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    titleText:SetPoint("TOPLEFT", titleBg, 8, -3)
    titleText:SetText("|cFFEDA55fBugs|rworth")
    titleText:SetTextColor(1, 1, 1, 1)

    -- Close button
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 1)
    close:SetScript("OnClick", function() BC:CloseViewer() end)

    -------------------------------------------------------------------
    -- LEFT PANEL: Navigation
    -------------------------------------------------------------------
    local navPanel = CreateFrame("Frame", nil, window)
    navPanel:SetPoint("TOPLEFT", window, "TOPLEFT", 8, -30)
    navPanel:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 8, 38)
    navPanel:SetWidth(NAV_W)
    navPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    navPanel:SetBackdropColor(0.05, 0.05, 0.08, 0.9)
    navPanel:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.5)

    -- Search box
    searchBox = CreateFrame("EditBox", "BugsworthSearchBox", navPanel, "InputBoxTemplate")
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", navPanel, "TOPLEFT", 8, -6)
    searchBox:SetPoint("TOPRIGHT", navPanel, "TOPRIGHT", -8, -6)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(GameFontHighlightSmall)
    searchBox:SetScript("OnTextChanged", function(self)
        searchFilter = self:GetText() or ""
        rebuildNav()
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    -- Search placeholder text
    local placeholder = searchBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", 4, 0)
    placeholder:SetText("Search errors...")
    searchBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then placeholder:Show() end
    end)

    -- Nav scroll frame
    navScroll = CreateFrame("ScrollFrame", "BugsworthNavScroll", navPanel, "UIPanelScrollFrameTemplate")
    navScroll:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -4, -4)
    navScroll:SetPoint("BOTTOMRIGHT", navPanel, "BOTTOMRIGHT", -24, 4)

    navContainer = CreateFrame("Frame", "BugsworthNavContainer", navScroll)
    navContainer:SetWidth(NAV_W - 28)
    navContainer:SetHeight(1)
    navScroll:SetScrollChild(navContainer)

    -------------------------------------------------------------------
    -- RIGHT PANEL: Error detail
    -------------------------------------------------------------------
    local detailPanel = CreateFrame("Frame", nil, window)
    detailPanel:SetPoint("TOPLEFT", navPanel, "TOPRIGHT", 4, 0)
    detailPanel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, 38)

    -- Session label (top of detail panel)
    sessionLabel = detailPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    sessionLabel:SetJustifyH("LEFT")
    sessionLabel:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 4, -2)
    sessionLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    -- Count label (top right of detail panel)
    countLabel = detailPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    countLabel:SetPoint("TOPRIGHT", detailPanel, "TOPRIGHT", -4, -2)
    countLabel:SetJustifyH("RIGHT")
    countLabel:SetTextColor(1, 0.8, 0.2, 1)

    -- Bottom buttons
    nextButton = CreateFrame("Button", "BugsworthNextButton", detailPanel, "UIPanelButtonTemplate")
    nextButton:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", 0, 0)
    nextButton:SetWidth(80)
    nextButton:SetHeight(22)
    nextButton:SetText("Next >")
    nextButton:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            selectedError = currentContents[#currentContents]
            updateDetail()
            rebuildNav()
        else
            navigateError(1)
            rebuildNav()
        end
    end)

    prevButton = CreateFrame("Button", "BugsworthPrevButton", detailPanel, "UIPanelButtonTemplate")
    prevButton:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", 0, 0)
    prevButton:SetWidth(80)
    prevButton:SetHeight(22)
    prevButton:SetText("< Previous")
    prevButton:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            selectedError = currentContents[1]
            updateDetail()
            rebuildNav()
        else
            navigateError(-1)
            rebuildNav()
        end
    end)

    -- Clear All button (left of center)
    local clearButton = CreateFrame("Button", "BugsworthClearButton", detailPanel, "UIPanelButtonTemplate")
    clearButton:SetPoint("BOTTOM", detailPanel, "BOTTOM", -50, 0)
    clearButton:SetWidth(90)
    clearButton:SetHeight(22)
    clearButton:SetText("Clear All")
    clearButton:SetScript("OnClick", function()
        BC:Reset()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: All errors cleared.")
        if BC.OnErrorCountChanged then BC:OnErrorCountChanged() end
        currentContents = {}
        selectedError = nil
        expandedAddons = {}
        fullRefresh()
    end)

    -- Copy All button (right of center)
    copyButton = CreateFrame("Button", "BugsworthCopyButton", detailPanel, "UIPanelButtonTemplate")
    copyButton:SetPoint("BOTTOM", detailPanel, "BOTTOM", 50, 0)
    copyButton:SetWidth(90)
    copyButton:SetHeight(22)
    copyButton:SetText("Copy All")
    copyButton:SetScript("OnClick", function()
        if textArea then
            textArea:SetFocus()
            textArea:HighlightText()
            -- Flash a "Press Ctrl+C" reminder
            if copyFlash then
                copyFlash:SetAlpha(1)
                copyFlash.text:SetText("|cff44ff44Press Ctrl+C to copy!|r")
                copyFlash:Show()
                -- Fade out after 2 seconds
                local elapsed = 0
                copyFlash:SetScript("OnUpdate", function(self, dt)
                    elapsed = elapsed + dt
                    if elapsed > 2 then
                        self:Hide()
                        self:SetScript("OnUpdate", nil)
                        textArea:HighlightText(0, 0)
                        textArea:ClearFocus()
                    elseif elapsed > 1.5 then
                        self:SetAlpha(1 - ((elapsed - 1.5) / 0.5))
                    end
                end)
            end
        end
    end)

    -- Copy flash label (Frame so we can use SetScript/SetAlpha for fade)
    copyFlash = CreateFrame("Frame", nil, detailPanel)
    copyFlash:SetPoint("CENTER", detailPanel, "CENTER", 0, 0)
    copyFlash:SetWidth(200)
    copyFlash:SetHeight(20)
    copyFlash.text = copyFlash:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    copyFlash.text:SetPoint("CENTER")
    copyFlash:Hide()

    -- Scroll frame for error text
    detailScroll = CreateFrame("ScrollFrame", "BugsworthDetailScroll", detailPanel, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 4, -18)
    detailScroll:SetPoint("BOTTOMRIGHT", nextButton, "TOPRIGHT", -24, 4)

    -- Text area (editable for copy-paste)
    textArea = CreateFrame("EditBox", "BugsworthDetailText", detailScroll)
    textArea:SetAutoFocus(false)
    textArea:SetMultiLine(true)
    textArea:SetFontObject(GameFontHighlightSmall)
    textArea:SetMaxLetters(99999)
    textArea:EnableMouse(true)
    textArea:SetScript("OnEscapePressed", textArea.ClearFocus)
    textArea:SetWidth(WINDOW_W - NAV_W - 56)
    detailScroll:SetScrollChild(textArea)

    -------------------------------------------------------------------
    -- TABS (bottom of window)
    -------------------------------------------------------------------
    local allTab = CreateFrame("Button", "BugsworthTabAll", window, "CharacterFrameTabButtonTemplate")
    allTab:SetFrameStrata("FULLSCREEN")
    allTab:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 0, 8)
    allTab:SetText("All Bugs")
    allTab:SetScript("OnLoad", nil)
    allTab:SetScript("OnShow", nil)
    allTab:SetScript("OnClick", setActiveTab)
    allTab:SetNormalFontObject(GameFontNormal)
    allTab.bugs = nil

    local sessionTab = CreateFrame("Button", "BugsworthTabSession", window, "CharacterFrameTabButtonTemplate")
    sessionTab:SetFrameStrata("FULLSCREEN")
    sessionTab:SetPoint("LEFT", allTab, "RIGHT")
    sessionTab:SetText("This Session")
    sessionTab:SetScript("OnLoad", nil)
    sessionTab:SetScript("OnShow", nil)
    sessionTab:SetScript("OnClick", setActiveTab)
    sessionTab:SetNormalFontObject(GameFontHighlight)
    sessionTab.bugs = 0

    local prevTab = CreateFrame("Button", "BugsworthTabPrev", window, "CharacterFrameTabButtonTemplate")
    prevTab:SetFrameStrata("FULLSCREEN")
    prevTab:SetPoint("LEFT", sessionTab, "RIGHT")
    prevTab:SetText("Previous")
    prevTab:SetScript("OnLoad", nil)
    prevTab:SetScript("OnShow", nil)
    prevTab:SetScript("OnClick", setActiveTab)
    prevTab:SetNormalFontObject(GameFontNormal)
    prevTab.bugs = -1

    tabs = { allTab, sessionTab, prevTab }
    local tabWidth = WINDOW_W / 3
    for _, t in ipairs(tabs) do
        PanelTemplates_TabResize(t, nil, tabWidth, tabWidth)
        PanelTemplates_DeselectTab(t)
    end

    viewerFrame = window
    initialized = true
    return window
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------
function BC:OpenViewer()
    if not viewerFrame then createViewer() end

    if not currentContents then
        currentContents = BC:GetErrors(BC:GetSessionId())
    end

    fullRefresh()
    ShowUIPanel(BugsworthFrame)
end

function BC:CloseViewer()
    if viewerFrame then HideUIPanel(BugsworthFrame) end
end

-----------------------------------------------------------------------
-- Error notification (sound + chat + auto-open)
-----------------------------------------------------------------------
local lastErrorTime = nil
function BC:OnError()
    if not lastErrorTime or GetTime() > (lastErrorTime + 2) then
        -- Sound
        if not BugsworthDB.mute then
            PlaySoundFile("Interface\\AddOns\\!Bugsworth\\Media\\error.wav")
        end
        -- Auto-open
        if BugsworthDB.auto then
            self:OpenViewer()
        end
        -- Chat notification
        if BugsworthDB.chatframe then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: There's a bug in your soup!")
        end
        lastErrorTime = GetTime()
    end
    -- Update minimap icon
    if BC.OnErrorCountChanged then
        BC:OnErrorCountChanged()
    end
    -- If viewer is open, refresh nav
    if viewerFrame and viewerFrame:IsShown() and currentContents then
        -- Re-fetch current view
        if currentSession then
            currentContents = BC:GetErrors(currentSession)
        else
            currentContents = BC:GetErrors()
        end
        fullRefresh()
    end
end

-----------------------------------------------------------------------
-- Register for error callbacks
-----------------------------------------------------------------------
local function initViewerCallbacks()
    if not LibStub then return end
    local CBH = LibStub("CallbackHandler-1.0", true)
    if not CBH then return end

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")

        if BC.RegisterCallback then
            BC:RegisterCallback("Bugsworth_BugGrabbed", function() BC:OnError() end)
            BC:RegisterCallback("Bugsworth_EventGrabbed", function() BC:OnError() end)
        end

        -- Show any startup errors
        local session = BC:GetErrors(BC:GetSessionId())
        if #session > 0 then
            BC:OnError()
        end
    end)
end
initViewerCallbacks()
