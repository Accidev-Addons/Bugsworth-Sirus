-----------------------------------------------------------------------
-- BUGSWORTH · taint.lua
-- Taint analysis mode — dedicated viewer for ADDON_ACTION_BLOCKED/FORBIDDEN
-----------------------------------------------------------------------

local BC = _G.Bugsworth
if not BC then return end

local format = string.format
local concat = table.concat

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------
local taintFrame = nil
local selectedEntry = nil
local currentList = nil       -- filtered/sorted list being displayed
local viewSession = nil       -- nil = all, number = specific session

-- UI refs
local listContainer, listScroll
local detailText, detailScroll
local summaryLabel, copyButton, copyFlash
local sessionToggle

-----------------------------------------------------------------------
-- Frame pool for list rows
-----------------------------------------------------------------------
local rowPool = {}
local rowActive = 0

local function acquireRow()
    rowActive = rowActive + 1
    local f = rowPool[rowActive]
    if not f then
        f = CreateFrame("Button", nil, listContainer)
        f.text = f:CreateFontString(nil, "OVERLAY")
        f.text:SetPoint("LEFT", 4, 0)
        f.text:SetPoint("RIGHT", -4, 0)
        f.text:SetJustifyH("LEFT")
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        rowPool[rowActive] = f
    end
    f:ClearAllPoints()
    f:SetScript("OnClick", nil)
    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)
    f:RegisterForClicks("LeftButtonUp")
    f:Show()
    return f
end

local function releaseAllRows()
    for i = 1, rowActive do
        rowPool[i]:Hide()
    end
    rowActive = 0
end

-----------------------------------------------------------------------
-- Format taint detail for display
-----------------------------------------------------------------------
local function formatTaintDetail(entry)
    local lines = {}

    -- Header
    lines[#lines + 1] = "|cffff4444=== TAINT ANALYSIS ===|r"
    lines[#lines + 1] = ""

    -- Event info
    local eventColor = entry.event == "ADDON_ACTION_FORBIDDEN" and "|cffff0000" or "|cffff8800"
    lines[#lines + 1] = format("|cFFFFFFFFСобытие:|r %s%s|r", eventColor, entry.event or "?")
    lines[#lines + 1] = format("|cFFFFFFFFАддон:|r |cffeda55f%s|r%s",
        entry.addon or "?",
        (entry.addonVersion and entry.addonVersion ~= "") and format(" |cff999999v%s|r", entry.addonVersion) or "")
    lines[#lines + 1] = format("|cFFFFFFFFФункция:|r |cff44ff44%s|r", entry.func or "?")
    lines[#lines + 1] = format("|cFFFFFFFFВремя:|r %s", entry.time or "?")
    lines[#lines + 1] = format("|cFFFFFFFFПоследнее:|r %s", entry.lastTime or "?")
    lines[#lines + 1] = format("|cFFFFFFFFСессия:|r %d", entry.session or 0)
    lines[#lines + 1] = format("|cFFFFFFFFПовторений:|r |cffff7fff%d|r", entry.counter or 1)

    -- Context
    lines[#lines + 1] = ""
    local combatStr = entry.inCombat and "|cffff0000ДА|r" or "|cff44ff44НЕТ|r"
    lines[#lines + 1] = format("|cFFFFFFFFВ бою:|r %s", combatStr)
    if entry.zone and entry.zone ~= "" then
        local zoneStr = entry.zone
        if entry.subZone and entry.subZone ~= "" then
            zoneStr = zoneStr .. " — " .. entry.subZone
        end
        lines[#lines + 1] = format("|cFFFFFFFFЗона:|r |cff88bbff%s|r", zoneStr)
    end
    if entry.instanceType and entry.instanceType ~= "none" then
        lines[#lines + 1] = format("|cFFFFFFFFТип инстанса:|r |cffff88ff%s|r", entry.instanceType)
    end

    -- Explanation
    lines[#lines + 1] = ""
    if entry.event == "ADDON_ACTION_FORBIDDEN" then
        lines[#lines + 1] = "|cffff4444FORBIDDEN — действие полностью заблокировано.|r"
        lines[#lines + 1] = "|cffff4444Аддон пытался вызвать защищённую функцию в бою.|r"
    else
        lines[#lines + 1] = "|cffff8800BLOCKED — вызов защищённой функции перехвачен.|r"
        lines[#lines + 1] = "|cffff8800Обычно из-за taint (заражения) execution path.|r"
    end

    -- Call chain
    if entry.callChain and #entry.callChain > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cFFFFFFFF--- Цепочка вызовов ---|r"
        for i, frame in ipairs(entry.callChain) do
            local cleaned = frame:gsub("[Ii]nterface\\[Aa]dd[Oo]ns\\", "")
            lines[#lines + 1] = format("  |cff999999%d.|r |cffeda55f%s|r", i, cleaned)
        end
    end

    -- Full stack trace
    if entry.stack and entry.stack ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cFFFFFFFF--- Полный стек вызовов ---|r"
        for line in entry.stack:gmatch("(.-)\n") do
            local cleaned = line:gsub("[Ii]nterface\\[Aa]dd[Oo]ns\\", "")
            cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned
            if cleaned ~= "" then
                cleaned = cleaned:gsub("(.-)(%d+):", "|cffeda55f%1|r|cff00ff00%2|r:")
                lines[#lines + 1] = "  " .. cleaned
            end
        end
    end

    -- Locals
    if entry.locals and entry.locals ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cFFFFFFFF--- Локальные переменные ---|r"
        local locText = entry.locals
        locText = locText:gsub("([ ]-)([%a_][%a_%d]+) = ", "%1|cffffff80%2|r = ")
        locText = locText:gsub("= (%d+)\n", "= |cffff7fff%1|r\n")
        locText = locText:gsub("<function>", "|cffffea00<function>|r")
        locText = locText:gsub("<table>", "|cffffea00<table>|r")
        locText = locText:gsub("= nil\n", "= |cffff7f7fnil|r\n")
        locText = locText:gsub("= true\n", "= |cffff9100true|r\n")
        locText = locText:gsub("= false\n", "= |cffff9100false|r\n")
        locText = locText:gsub("= \"([^\n]+)\"\n", "= |cff8888ff\"%1\"|r\n")
        lines[#lines + 1] = locText
    end

    -- Hint
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cff666666--- 'Копировать' — одну ошибку | 'Копировать всё' — весь лог ---|r"

    return concat(lines, "\n")
end

-----------------------------------------------------------------------
-- Plain text version for clipboard
-----------------------------------------------------------------------
local function formatTaintPlain(entry)
    local lines = {}

    lines[#lines + 1] = "=== TAINT ERROR REPORT ==="
    lines[#lines + 1] = format("Client: WoW 3.3.5a (Sirus) | Build: %s", (GetBuildInfo and GetBuildInfo()) or "unknown")
    lines[#lines + 1] = ""
    lines[#lines + 1] = format("Event: %s", entry.event or "?")
    lines[#lines + 1] = format("Addon: %s", entry.addon or "?")
    lines[#lines + 1] = format("Addon version: %s", (entry.addonVersion and entry.addonVersion ~= "") and entry.addonVersion or "unknown")
    lines[#lines + 1] = format("Protected function: %s()", entry.func or "?")
    lines[#lines + 1] = format("In combat: %s", entry.inCombat and "YES" or "NO")
    lines[#lines + 1] = format("Time: %s", entry.time or "?")
    lines[#lines + 1] = format("Last seen: %s", entry.lastTime or "?")
    lines[#lines + 1] = format("Occurrences: %d", entry.counter or 1)
    lines[#lines + 1] = format("Session: %d", entry.session or 0)
    if entry.zone and entry.zone ~= "" then
        local zoneStr = entry.zone
        if entry.subZone and entry.subZone ~= "" then
            zoneStr = zoneStr .. " / " .. entry.subZone
        end
        lines[#lines + 1] = format("Zone: %s", zoneStr)
    end
    if entry.instanceType and entry.instanceType ~= "none" then
        lines[#lines + 1] = format("Instance type: %s", entry.instanceType)
    end

    -- Error message as user sees it
    lines[#lines + 1] = ""
    lines[#lines + 1] = format("Error message: [%s] AddOn '%s' tried to call the protected function '%s'.",
        entry.event or "?", entry.addon or "?", entry.func or "?")

    if entry.callChain and #entry.callChain > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "--- Call Chain (taint propagation path) ---"
        for i, frame in ipairs(entry.callChain) do
            lines[#lines + 1] = format("  %d. %s", i, frame)
        end
    end

    if entry.stack and entry.stack ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "--- Full Stack Trace ---"
        lines[#lines + 1] = entry.stack
    end

    if entry.locals and entry.locals ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "--- Local Variables ---"
        lines[#lines + 1] = entry.locals
    end

    return concat(lines, "\n")
end

local function formatAllTaintPlain(list)
    local lines = {}

    lines[#lines + 1] = "=========================================="
    lines[#lines + 1] = "BUGSWORTH TAINT ANALYSIS — FULL REPORT"
    lines[#lines + 1] = "=========================================="
    lines[#lines + 1] = format("Client: WoW 3.3.5a (Sirus) | Build: %s", (GetBuildInfo and GetBuildInfo()) or "unknown")
    lines[#lines + 1] = format("Report generated: %s", date("%Y/%m/%d %H:%M:%S"))
    lines[#lines + 1] = format("Total unique taint errors: %d", #list)

    -- Summary table
    local totalHits = 0
    local addonSummary = {}
    local addonOrder = {}
    for _, entry in ipairs(list) do
        totalHits = totalHits + (entry.counter or 1)
        local a = entry.addon or "?"
        if not addonSummary[a] then
            addonSummary[a] = { unique = 0, total = 0, funcs = {} }
            addonOrder[#addonOrder + 1] = a
        end
        addonSummary[a].unique = addonSummary[a].unique + 1
        addonSummary[a].total = addonSummary[a].total + (entry.counter or 1)
        addonSummary[a].funcs[entry.func or "?"] = true
    end
    lines[#lines + 1] = format("Total occurrences: %d", totalHits)
    lines[#lines + 1] = format("Addons affected: %d", #addonOrder)

    -- Per-addon summary
    lines[#lines + 1] = ""
    lines[#lines + 1] = "--- Addon Summary ---"
    for _, addonName in ipairs(addonOrder) do
        local s = addonSummary[addonName]
        local funcList = {}
        for f in pairs(s.funcs) do funcList[#funcList + 1] = f .. "()" end
        lines[#lines + 1] = format("  %s: %d unique, %d total — functions: %s",
            addonName, s.unique, s.total, concat(funcList, ", "))
    end

    -- Individual entries
    for idx, entry in ipairs(list) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = format("------ Taint #%d of %d ------", idx, #list)
        lines[#lines + 1] = format("Event: %s", entry.event or "?")
        lines[#lines + 1] = format("Addon: %s (v%s)", entry.addon or "?",
            (entry.addonVersion and entry.addonVersion ~= "") and entry.addonVersion or "unknown")
        lines[#lines + 1] = format("Protected function: %s()", entry.func or "?")
        lines[#lines + 1] = format("In combat: %s", entry.inCombat and "YES" or "NO")
        lines[#lines + 1] = format("Time: %s | Last: %s | Count: %d",
            entry.time or "?", entry.lastTime or "?", entry.counter or 1)
        if entry.zone and entry.zone ~= "" then
            lines[#lines + 1] = format("Zone: %s%s",
                entry.zone, (entry.subZone and entry.subZone ~= "") and (" / " .. entry.subZone) or "")
        end
        if entry.instanceType and entry.instanceType ~= "none" then
            lines[#lines + 1] = format("Instance type: %s", entry.instanceType)
        end

        lines[#lines + 1] = format("Error: [%s] AddOn '%s' tried to call the protected function '%s'.",
            entry.event or "?", entry.addon or "?", entry.func or "?")

        if entry.callChain and #entry.callChain > 0 then
            lines[#lines + 1] = "Call chain:"
            for i, frame in ipairs(entry.callChain) do
                lines[#lines + 1] = format("  %d. %s", i, frame)
            end
        end

        if entry.stack and entry.stack ~= "" then
            lines[#lines + 1] = "Stack:"
            lines[#lines + 1] = entry.stack
        end

        if entry.locals and entry.locals ~= "" then
            lines[#lines + 1] = "Locals:"
            lines[#lines + 1] = entry.locals
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "=========================================="
    lines[#lines + 1] = "END OF TAINT REPORT"
    lines[#lines + 1] = "=========================================="

    return concat(lines, "\n")
end

-----------------------------------------------------------------------
-- Update detail panel
-----------------------------------------------------------------------
local function updateDetail()
    if not selectedEntry then
        if detailText then detailText:SetText("|cff44ff44Нет taint-ошибок. Всё чисто!|r") end
        return
    end
    detailText:SetText(formatTaintDetail(selectedEntry))
end

-----------------------------------------------------------------------
-- Update summary label
-----------------------------------------------------------------------
local function updateSummary()
    if not summaryLabel then return end
    local list = currentList or {}
    local total = 0
    local addons = {}
    for _, entry in ipairs(list) do
        total = total + (entry.counter or 1)
        addons[entry.addon] = true
    end
    local addonCount = 0
    for _ in pairs(addons) do addonCount = addonCount + 1 end

    if #list == 0 then
        summaryLabel:SetText("|cff44ff44Нет taint-ошибок|r")
    else
        summaryLabel:SetText(format(
            "|cffff8800%d|r уник. | |cffff8800%d|r всего | |cffeda55f%d|r аддонов",
            #list, total, addonCount
        ))
    end
end

-----------------------------------------------------------------------
-- Rebuild list panel
-----------------------------------------------------------------------
local ROW_HEIGHT = 22

local function rebuildList()
    if not listContainer then return end
    releaseAllRows()

    local list = currentList or {}
    local yOffset = 0
    local listWidth = listContainer:GetWidth() - 4
    if listWidth < 20 then listWidth = 260 end

    -- Group by addon
    local groups = {}
    local order = {}
    for _, entry in ipairs(list) do
        local key = entry.addon or "?"
        if not groups[key] then
            groups[key] = {}
            order[#order + 1] = key
        end
        groups[key][#groups[key] + 1] = entry
    end

    -- Sort addons by total count
    table.sort(order, function(a, b)
        local ca, cb = 0, 0
        for _, e in ipairs(groups[a]) do ca = ca + (e.counter or 1) end
        for _, e in ipairs(groups[b]) do cb = cb + (e.counter or 1) end
        return ca > cb
    end)

    for _, addonName in ipairs(order) do
        local entries = groups[addonName]

        -- Addon header
        local header = acquireRow()
        header:SetHeight(ROW_HEIGHT + 2)
        header:SetWidth(listWidth)
        header:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 2, -yOffset)
        header.text:SetFontObject(GameFontNormalSmall)

        local totalHits = 0
        for _, e in ipairs(entries) do totalHits = totalHits + (e.counter or 1) end
        header.text:SetText(format("|cffeda55f%s|r |cff999999(%d)|r", addonName, totalHits))
        header.bg:SetVertexColor(0.4, 0.15, 0.1, 0.4)

        header:SetScript("OnEnter", function()
            header.bg:SetVertexColor(0.5, 0.25, 0.1, 0.6)
        end)
        header:SetScript("OnLeave", function()
            header.bg:SetVertexColor(0.4, 0.15, 0.1, 0.4)
        end)

        yOffset = yOffset + ROW_HEIGHT + 2

        -- Error rows under this addon
        for _, entry in ipairs(entries) do
            local row = acquireRow()
            row:SetHeight(ROW_HEIGHT)
            row:SetWidth(listWidth - 8)
            row:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 10, -yOffset)

            row.text:SetFontObject(GameFontHighlightExtraSmall)
            local eventTag = entry.event == "ADDON_ACTION_FORBIDDEN" and "|cffff0000F|r" or "|cffff8800B|r"
            local funcName = entry.func or "?"
            if funcName:len() > 30 then funcName = funcName:sub(1, 30) .. "..." end
            row.text:SetText(format(
                "%s |cff44ff44%s|r |cff999999x%d|r",
                eventTag, funcName, entry.counter or 1
            ))

            if entry == selectedEntry then
                row.bg:SetVertexColor(0.2, 0.4, 0.6, 0.6)
            else
                row.bg:SetVertexColor(0, 0, 0, 0)
            end

            row:SetScript("OnEnter", function()
                if entry ~= selectedEntry then
                    row.bg:SetVertexColor(0.2, 0.3, 0.4, 0.4)
                end
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:AddLine(format("%s → %s", entry.addon, entry.func))
                GameTooltip:AddLine(format("Событие: %s", entry.event), 0.8, 0.8, 0.8)
                GameTooltip:AddLine(format("Повторений: %d", entry.counter or 1), 1, 0.8, 0.2)
                GameTooltip:AddLine(format("Время: %s", entry.time), 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                if entry ~= selectedEntry then
                    row.bg:SetVertexColor(0, 0, 0, 0)
                end
                GameTooltip:Hide()
            end)
            row:SetScript("OnClick", function()
                selectedEntry = entry
                updateDetail()
                rebuildList()
            end)

            yOffset = yOffset + ROW_HEIGHT
        end
    end

    listContainer:SetHeight(math.max(yOffset, 1))
    updateSummary()
end

-----------------------------------------------------------------------
-- Full refresh
-----------------------------------------------------------------------
local function fullRefresh()
    local source
    if viewSession then
        source = BC:GetTaintLogForSession(viewSession)
    else
        source = BC:GetTaintLog()
    end

    currentList = {}
    for i = 1, #source do
        currentList[i] = source[i]
    end

    -- Sort: most recent first
    table.sort(currentList, function(a, b)
        return (a.counter or 1) > (b.counter or 1)
    end)

    rebuildList()
    if currentList and #currentList > 0 then
        if not selectedEntry then
            selectedEntry = currentList[1]
        end
    else
        selectedEntry = nil
    end
    updateDetail()
end

-----------------------------------------------------------------------
-- Create the taint viewer frame
-----------------------------------------------------------------------
local function createTaintViewer()
    local WINDOW_W, WINDOW_H = 750, 450
    local LIST_W = 200

    local window = CreateFrame("Frame", "BugsworthTaintFrame", UIParent)
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
    window:Hide()

    -- Dark backdrop with red tint
    window:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    window:SetBackdropColor(0.1, 0.06, 0.06, 0.95)
    window:SetBackdropBorderColor(0.8, 0.2, 0.1, 0.9)

    -- Title bar
    local titleBg = window:CreateTexture(nil, "BORDER")
    titleBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    titleBg:SetPoint("TOPLEFT", 6, -6)
    titleBg:SetPoint("TOPRIGHT", -6, -6)
    titleBg:SetHeight(22)
    titleBg:SetVertexColor(0.5, 0.1, 0.05, 0.8)

    local titleText = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    titleText:SetPoint("TOPLEFT", titleBg, 8, -3)
    titleText:SetText("|cFFEDA55fBugs|rworth — |cffff4444Режим анализа Taint|r")
    titleText:SetTextColor(1, 1, 1, 1)

    -- Close button
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 1)
    close:SetScript("OnClick", function() window:Hide() end)

    -- Summary label
    summaryLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    summaryLabel:SetPoint("TOPRIGHT", titleBg, "TOPRIGHT", -30, -3)
    summaryLabel:SetJustifyH("RIGHT")

    -------------------------------------------------------------------
    -- Bottom toolbar
    -------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, window)
    toolbar:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 8, 8)
    toolbar:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, 8)
    toolbar:SetHeight(26)

    -- Session toggle
    sessionToggle = CreateFrame("Button", "BugsworthTaintSessionBtn", toolbar, "UIPanelButtonTemplate")
    sessionToggle:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    sessionToggle:SetWidth(130)
    sessionToggle:SetHeight(22)
    sessionToggle:SetText("Текущая сессия")
    sessionToggle:SetScript("OnClick", function()
        if viewSession then
            viewSession = nil
            sessionToggle:SetText("Текущая сессия")
        else
            viewSession = BC:GetSessionId()
            sessionToggle:SetText("Все сессии")
        end
        selectedEntry = nil
        fullRefresh()
    end)

    -- Clear taint log
    local clearBtn = CreateFrame("Button", "BugsworthTaintClearBtn", toolbar, "UIPanelButtonTemplate")
    clearBtn:SetPoint("LEFT", sessionToggle, "RIGHT", 4, 0)
    clearBtn:SetWidth(100)
    clearBtn:SetHeight(22)
    clearBtn:SetText("Очистить")
    clearBtn:SetScript("OnClick", function()
        BC:ClearTaintLog()
        currentList = {}
        selectedEntry = nil
        fullRefresh()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: Taint-лог очищен.")
    end)

    -- Helper: show copy flash and set text for clipboard
    local function doCopyFlash(plainText)
        if not detailText then return end
        detailText:SetText(plainText)
        detailText:SetFocus()
        detailText:HighlightText()

        if copyFlash then
            copyFlash:SetAlpha(1)
            copyFlash.text:SetText("|cff44ff44Ctrl+C для копирования!|r")
            copyFlash:Show()
            local elapsed = 0
            copyFlash:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                if elapsed > 3 then
                    self:Hide()
                    self:SetScript("OnUpdate", nil)
                    detailText:HighlightText(0, 0)
                    detailText:ClearFocus()
                    updateDetail()
                elseif elapsed > 2.5 then
                    self:SetAlpha(1 - ((elapsed - 2.5) / 0.5))
                end
            end)
        end
    end

    -- Copy single entry button
    copyButton = CreateFrame("Button", "BugsworthTaintCopyBtn", toolbar, "UIPanelButtonTemplate")
    copyButton:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    copyButton:SetWidth(100)
    copyButton:SetHeight(22)
    copyButton:SetText("Копировать")
    copyButton:SetScript("OnClick", function()
        if selectedEntry then
            doCopyFlash(formatTaintPlain(selectedEntry))
        end
    end)

    local copyAllBtn = CreateFrame("Button", "BugsworthTaintCopyAllBtn", toolbar, "UIPanelButtonTemplate")
    copyAllBtn:SetPoint("RIGHT", copyButton, "LEFT", -4, 0)
    copyAllBtn:SetWidth(120)
    copyAllBtn:SetHeight(22)
    copyAllBtn:SetText("Копировать всё")
    copyAllBtn:SetScript("OnClick", function()
        local list = currentList
        if not list or #list == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: Нет taint-ошибок для копирования.")
            return
        end
        doCopyFlash(formatAllTaintPlain(list))
    end)

    -- Copy flash
    copyFlash = CreateFrame("Frame", nil, window)
    copyFlash:SetPoint("CENTER", window, "CENTER", 0, 0)
    copyFlash:SetWidth(200)
    copyFlash:SetHeight(20)
    copyFlash.text = copyFlash:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    copyFlash.text:SetPoint("CENTER")
    copyFlash:SetFrameLevel(window:GetFrameLevel() + 10)
    copyFlash:Hide()

    -------------------------------------------------------------------
    -- LEFT PANEL: Taint list
    -------------------------------------------------------------------
    local listPanel = CreateFrame("Frame", nil, window)
    listPanel:SetPoint("TOPLEFT", window, "TOPLEFT", 8, -30)
    listPanel:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 8, 38)
    listPanel:SetWidth(LIST_W)
    listPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    listPanel:SetBackdropColor(0.05, 0.05, 0.08, 0.9)
    listPanel:SetBackdropBorderColor(0.5, 0.2, 0.2, 0.5)

    -- List scroll
    listScroll = CreateFrame("ScrollFrame", "BugsworthTaintListScroll", listPanel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 4, -4)
    listScroll:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -24, 4)

    listContainer = CreateFrame("Frame", "BugsworthTaintListContainer", listScroll)
    listContainer:SetWidth(LIST_W - 28)
    listContainer:SetHeight(1)
    listScroll:SetScrollChild(listContainer)

    -------------------------------------------------------------------
    -- RIGHT PANEL: Detail
    -------------------------------------------------------------------
    local detailPanel = CreateFrame("Frame", nil, window)
    detailPanel:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 4, 0)
    detailPanel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, 38)

    detailScroll = CreateFrame("ScrollFrame", "BugsworthTaintDetailScroll", detailPanel, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 4, -4)
    detailScroll:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -24, 4)

    detailText = CreateFrame("EditBox", "BugsworthTaintDetailText", detailScroll)
    detailText:SetAutoFocus(false)
    detailText:SetMultiLine(true)
    detailText:SetFontObject(GameFontHighlightSmall)
    detailText:SetMaxLetters(99999)
    detailText:EnableMouse(true)
    detailText:SetScript("OnEscapePressed", detailText.ClearFocus)
    detailText:SetWidth(WINDOW_W - LIST_W - 56)
    detailScroll:SetScrollChild(detailText)

    taintFrame = window
    return window
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------
function BC:OpenTaintViewer()
    if not taintFrame then createTaintViewer() end

    -- Default: show current session
    viewSession = BC:GetSessionId()
    selectedEntry = nil

    fullRefresh()
    taintFrame:Show()
end

function BC:CloseTaintViewer()
    if taintFrame then taintFrame:Hide() end
end

-----------------------------------------------------------------------
-- Auto-refresh when taint frame is open
-----------------------------------------------------------------------
function BC:OnTaintLogChanged()
    if taintFrame and taintFrame:IsShown() then
        fullRefresh()
    end
end
