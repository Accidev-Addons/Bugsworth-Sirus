local BC = _G.Bugsworth
if not BC then return end

local function safeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth CopyAll: " .. tostring(err))
        end
    end
end

-----------------------------------------------------------------------
-- Flatten an error message field (can be string or chunk-table)
-----------------------------------------------------------------------
local function flattenMessage(m)
    if type(m) == "table" then
        return table.concat(m, "")
    end
    return m or ""
end

-----------------------------------------------------------------------
-- Produce the plain-text dump for one error (no color codes)
-----------------------------------------------------------------------
local function formatOne(err, idx, total)
    local counter = err.counter or 1
    local session = err.session or 0
    local timeStr = err.time or "?"
    local typeStr = err.type or "error"
    local source = err.source and (" from " .. tostring(err.source)) or ""
    local header = string.format(
        "=== Error %d/%d | session %d | %s | %dx | %s%s ===",
        idx, total, session, timeStr, counter, typeStr, source
    )
    local body = flattenMessage(err.message)
    return header .. "\n" .. body
end

local function gatherErrors()
    local list
    if type(BC.GetCurrentContents) == "function" then
        list = BC:GetCurrentContents()
    end
    if type(list) ~= "table" then
        list = BC:GetErrors()
    end
    return list or {}
end

local function dedupeErrors(list)
    local seen = {}
    local out = {}
    for _, err in ipairs(list) do
        local msg = flattenMessage(err.message)
        local firstLine = msg:match("^[^\n]*") or msg
        local existing = seen[firstLine]
        if existing then
            existing.counter = (existing.counter or 1) + (err.counter or 1)
        else
            local copy = {}
            for k, v in pairs(err) do copy[k] = v end
            seen[firstLine] = copy
            out[#out + 1] = copy
        end
    end
    return out
end

local function buildBlob()
    local raw = gatherErrors()
    local rawTotal = #raw
    if rawTotal == 0 then
        return "(ошибок нет / no errors)"
    end
    local list = dedupeErrors(raw)
    local total = #list
    local parts = {}
    parts[#parts + 1] = string.format(
        "Bugsworth — уникальных ошибок: %d (из %d всего)  (экспорт %s)\n",
        total, rawTotal, date("%Y/%m/%d %H:%M:%S")
    )
    for i, err in ipairs(list) do
        parts[#parts + 1] = formatOne(err, i, total)
        if i < total then
            parts[#parts + 1] = "\n--- divider ---\n"
        end
    end
    return table.concat(parts, "\n")
end

-----------------------------------------------------------------------
-- Popup frame (lazy-created, reused)
-----------------------------------------------------------------------
local popup
local waiter

local function createPopup()
    local f = CreateFrame("Frame", "BugsworthCopyFrame", UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetWidth(560)
    f:SetHeight(380)
    f:SetPoint("CENTER")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.97)
    f:SetBackdropBorderColor(0.6, 0.2, 0.2, 0.9)

    -- Title bar (also the drag handle visual)
    local titleBg = f:CreateTexture(nil, "BORDER")
    titleBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    titleBg:SetPoint("TOPLEFT", 6, -6)
    titleBg:SetPoint("TOPRIGHT", -6, -6)
    titleBg:SetHeight(22)
    titleBg:SetVertexColor(0.4, 0.1, 0.1, 0.8)

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", titleBg, "TOPLEFT", 8, -3)
    title:SetText("|cFFEDA55fBugs|rworth — Копировать все (Ctrl+A, Ctrl+C)")
    title:SetTextColor(1, 1, 1, 1)

    -- Close button (top-right)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 1)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Hint label (bottom)
    local hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", 10, 10)
    hint:SetTextColor(0.8, 0.8, 0.8, 1)
    hint:SetText("Нажмите Ctrl+A, затем Ctrl+C. Escape — закрыть.")

    -- Bottom close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetWidth(90)
    closeBtn:SetHeight(22)
    closeBtn:SetPoint("BOTTOMRIGHT", -10, 8)
    closeBtn:SetText("Закрыть")
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Scroll frame + multiline EditBox
    local scroll = CreateFrame("ScrollFrame", "BugsworthCopyScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -30, 38)

    local edit = CreateFrame("EditBox", "BugsworthCopyEdit", scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetMaxLetters(99999)
    if edit.SetCountInvisibleLetters then
        edit:SetCountInvisibleLetters(false)
    end
    edit:SetWidth(scroll:GetWidth())
    edit:EnableMouse(true)
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        f:Hide()
    end)
    edit:SetScript("OnEnterPressed", function(self) self:Insert("\n") end)
    scroll:SetScrollChild(edit)

    f.editBox = edit
    f.scrollFrame = scroll
    f.titleBar = titleBg

    f:SetScript("OnShow", function(self)
        if self.editBox and self.scrollFrame then
            self.editBox:SetWidth(self.scrollFrame:GetWidth())
        end
    end)

    return f
end

-----------------------------------------------------------------------
-- Public: show the popup populated with all errors
-----------------------------------------------------------------------
function BC:ShowCopyAllPopup()
    if not popup then
        popup = createPopup()
    end
    local blob = buildBlob()
    local edit = popup.editBox
    if blob:len() > 60000 then
        blob = blob:sub(1, 60000) .. "\n\n(...truncated — слишком много ошибок, показаны первые 60000 символов)"
    end
    edit:SetText(blob)
    popup:Show()
    if not waiter then waiter = CreateFrame("Frame") end
    local elapsed = 0
    waiter:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.05 then
            self:SetScript("OnUpdate", nil)
            if popup:IsShown() then
                edit:SetFocus()
                edit:HighlightText(0, -1)
            end
        end
    end)
end

local function attachButton()
    local copyBtn = _G.BugsworthCopyButton
    if not copyBtn then return false end
    if _G.BugsworthCopyAllButton then return true end -- already created

    local parent = copyBtn:GetParent()
    local btn = CreateFrame("Button", "BugsworthCopyAllButton", parent, "UIPanelButtonTemplate")
    btn:SetWidth(110)
    btn:SetHeight(22)
    btn:SetPoint("LEFT", copyBtn, "RIGHT", 4, 0)
    btn:SetText("Копировать все")
    btn:SetScript("OnClick", function()
        safeCall(function() BC:ShowCopyAllPopup() end)
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Копировать все ошибки")
        GameTooltip:AddLine("Собирает все показанные ошибки в одно поле", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("(текущая вкладка: Все / Сессия / Предыдущая).", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Ctrl+A, Ctrl+C для копирования.", 0.5, 0.8, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return true
end

if not attachButton() then
    local origOpenViewer = BC.OpenViewer
    if type(origOpenViewer) == "function" then
        BC.OpenViewer = function(self, ...)
            local r1, r2, r3 = origOpenViewer(self, ...)
            safeCall(attachButton)
            return r1, r2, r3
        end
    end
end

-----------------------------------------------------------------------
-- Slash shortcut: /bugscopy dumps everything without opening the viewer.
-----------------------------------------------------------------------
SLASH_BUGSCOPY1 = "/bugscopy"
SlashCmdList["BUGSCOPY"] = function()
    safeCall(function() BC:ShowCopyAllPopup() end)
end
