local BC = _G.Bugsworth
if not BC then return end

local frame = CreateFrame("Frame", nil, InterfaceOptionsFramePanelContainer)
frame.name = "Bugsworth"
frame:Hide()

local function newCheckbox(label, description, onClick)
    local check = CreateFrame("CheckButton", "BugsworthCheck" .. label:gsub("%s", ""), frame, "InterfaceOptionsCheckButtonTemplate")
    check:SetScript("OnClick", function(self)
        PlaySound(self:GetChecked() and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        onClick(self, self:GetChecked() and true or false)
    end)
    check.label = _G[check:GetName() .. "Text"]
    check.label:SetText(label)
    check.tooltipText = label
    check.tooltipRequirement = description
    return check
end

local autoPopup, chatNotif, muteCheck, filterCheck, throttleCheck, suppressCheck, slider
local multiLocalsCheck, captureMemCheck
local initialized = false

local function refresh()
    if not initialized then return end
    autoPopup:SetChecked(BugsworthDB.auto)
    chatNotif:SetChecked(BugsworthDB.chatframe)
    muteCheck:SetChecked(BugsworthDB.mute)
    filterCheck:SetChecked(BugsworthDB.filterAddonMistakes)
    throttleCheck:SetChecked(BC:IsThrottling())
    slider:SetValue(BC:GetLimit())
    if suppressCheck then suppressCheck:SetChecked(BugsworthDB.suppressDefault) end
    if multiLocalsCheck then multiLocalsCheck:SetChecked(BugsworthDB.multiLocals) end
    if captureMemCheck then captureMemCheck:SetChecked(BugsworthDB.captureMemory) end
    if frame.rebuildIgnoreList then frame.rebuildIgnoreList() end
end

frame:SetScript("OnShow", function(self)
    if initialized then
        refresh()
        return
    end

    local title = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cFFEDA55fBugs|rworth")

    local subtitle = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetPoint("RIGHT", -32, 0)
    subtitle:SetHeight(24)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetJustifyV("TOP")
    subtitle:SetText("Захват, отображение и сохранение ошибок.")

    autoPopup = newCheckbox(
        "Авто-открытие при ошибке",
        "Автоматически открывать просмотрщик при появлении новой ошибки.",
        function(_, value) BugsworthDB.auto = value end
    )
    autoPopup:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -2, -8)

    chatNotif = newCheckbox(
        "Уведомление в чат",
        "Выводить сообщение в чат при захвате новой ошибки.",
        function(_, value) BugsworthDB.chatframe = value end
    )
    chatNotif:SetPoint("TOPLEFT", autoPopup, "BOTTOMLEFT", 0, -4)

    muteCheck = newCheckbox(
        "Отключить звук ошибки",
        "Отключить звуковое уведомление об ошибке.",
        function(_, value) BugsworthDB.mute = value end
    )
    muteCheck:SetPoint("TOPLEFT", chatNotif, "BOTTOMLEFT", 0, -4)

    filterCheck = newCheckbox(
        "Фильтр ошибок действий аддонов",
        "Игнорировать события ADDON_ACTION_BLOCKED/FORBIDDEN (ошибки taint).",
        function(_, value)
            BugsworthDB.filterAddonMistakes = value
            if value then
                BC:UnregisterAddonActionEvents()
            else
                BC:RegisterAddonActionEvents()
            end
        end
    )
    filterCheck:SetPoint("TOPLEFT", muteCheck, "BOTTOMLEFT", 0, -4)

    throttleCheck = newCheckbox(
        "Ограничение частых ошибок",
        "Приостановить захват, если обнаружено более 20 ошибок/сек.",
        function(_, value) BC:UseThrottling(value) end
    )
    throttleCheck:SetPoint("TOPLEFT", filterCheck, "BOTTOMLEFT", 0, -4)

    local sliderLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sliderLabel:SetJustifyH("LEFT")
    sliderLabel:SetText("Лимит ошибок:")
    sliderLabel:SetPoint("TOPLEFT", throttleCheck, "BOTTOMLEFT", 8, -16)

    local sliderValue = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sliderValue:SetJustifyH("LEFT")
    sliderValue:SetText(BC:GetLimit())

    slider = CreateFrame("Slider", nil, self)
    slider:SetHeight(17)
    slider:SetWidth(120)
    slider:SetOrientation("HORIZONTAL")
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        edgeSize = 8, tile = true, tileSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 }
    })
    slider:SetMinMaxValues(10, 1000)
    slider:SetValue(BC:GetLimit())
    slider:SetValueStep(10)
    slider:SetScript("OnValueChanged", function(_, value)
        local v = math.floor(math.abs(value))
        BC:SetLimit(v)
        sliderValue:SetText(v)
    end)
    slider:SetPoint("LEFT", sliderLabel, "RIGHT", 16, 0)
    sliderValue:SetPoint("LEFT", slider, "RIGHT", 8, 0)

    local wipeBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    wipeBtn:SetText("Очистить все ошибки")
    wipeBtn:SetWidth(140)
    wipeBtn:SetHeight(24)
    wipeBtn:SetPoint("TOPLEFT", sliderLabel, "BOTTOMLEFT", -4, -16)
    wipeBtn:SetScript("OnClick", function()
        BC:Reset()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: Все ошибки очищены.")
        if BC.OnErrorCountChanged then BC:OnErrorCountChanged() end
    end)

    suppressCheck = newCheckbox(
        "Скрыть стандартное окно ошибок",
        "Скрыть стандартный диалог Lua-ошибок Blizzard. Bugsworth захватывает все ошибки в любом случае.",
        function(_, value)
            BugsworthDB.suppressDefault = value
            local function setSuppress(f, suppress)
                if f and f.SetScript then
                    f:SetScript("OnShow", suppress and function(self) self:Hide() end or nil)
                end
            end
            setSuppress(_G.BasicScriptErrors, value)
            setSuppress(_G.ScriptErrorsFrame, value)
        end
    )
    suppressCheck:SetPoint("TOPLEFT", wipeBtn, "BOTTOMLEFT", 4, -12)

    local diagTitle = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    diagTitle:SetPoint("TOPLEFT", suppressCheck, "BOTTOMLEFT", 0, -12)
    diagTitle:SetText("|cffeda55fДиагностика|r (может увеличить размер SV)")

    multiLocalsCheck = newCheckbox(
        "Многоуровневые локальные",
        "Захватывать локальные переменные на каждом уровне стека, а не только в точке падения. Увеличивает вывод, но даёт полный контекст.",
        function(_, value) BugsworthDB.multiLocals = value end
    )
    multiLocalsCheck:SetPoint("TOPLEFT", diagTitle, "BOTTOMLEFT", -2, -4)

    captureMemCheck = newCheckbox(
        "Захват памяти аддона",
        "Записывать потребление памяти аддона в момент ошибки. Вызывает UpdateAddOnMemoryUsage() на каждую ошибку.",
        function(_, value) BugsworthDB.captureMemory = value end
    )
    captureMemCheck:SetPoint("TOPLEFT", multiLocalsCheck, "BOTTOMLEFT", 0, -4)

    local ignoreTitle = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    ignoreTitle:SetPoint("TOPLEFT", captureMemCheck, "BOTTOMLEFT", 2, -12)
    ignoreTitle:SetText("Игнорируемые аддоны:")

    local ignoreContainer = CreateFrame("Frame", nil, self)
    ignoreContainer:SetPoint("TOPLEFT", ignoreTitle, "BOTTOMLEFT", 0, -4)
    ignoreContainer:SetPoint("RIGHT", -32, 0)
    ignoreContainer:SetHeight(120)

    local ignoreRows = {}
    local ignoreRowCount = 0
    local emptyLabel = nil

    local function acquireIgnoreRow()
        ignoreRowCount = ignoreRowCount + 1
        local row = ignoreRows[ignoreRowCount]
        if not row then
            row = CreateFrame("Frame", nil, ignoreContainer)
            row:SetHeight(18)
            row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", 4, 0)
            row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.removeBtn:SetWidth(60)
            row.removeBtn:SetHeight(18)
            row.removeBtn:SetText("Убрать")
            row.removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            ignoreRows[ignoreRowCount] = row
        end
        row:ClearAllPoints()
        row:Show()
        return row
    end

    local function rebuildIgnoreList()
        for i = 1, ignoreRowCount do ignoreRows[i]:Hide() end
        ignoreRowCount = 0
        if emptyLabel then emptyLabel:Hide() end

        local list = BC:GetIgnoredAddons()
        local y = 0
        local count = 0
        for name, _ in pairs(list) do
            local row = acquireIgnoreRow()
            row:SetPoint("TOPLEFT", ignoreContainer, "TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", ignoreContainer, "RIGHT", 0, 0)
            row.label:SetText("|cffff8800" .. name .. "|r")
            row.removeBtn:SetScript("OnClick", function()
                BC:SetAddonIgnored(name, false)
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cFFEDA55fBugs|rworth: Аддон |cff44ff44%s|r больше не игнорируется.", name
                ))
                rebuildIgnoreList()
            end)
            y = y + 20
            count = count + 1
        end

        if count == 0 then
            if not emptyLabel then
                emptyLabel = ignoreContainer:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
                emptyLabel:SetPoint("TOPLEFT", 4, 0)
                emptyLabel:SetText("Нет игнорируемых аддонов. ПКМ по аддону в просмотрщике для игнорирования.")
            end
            emptyLabel:Show()
        end
    end
    rebuildIgnoreList()

    frame.rebuildIgnoreList = rebuildIgnoreList

    initialized = true
    refresh()
end)

InterfaceOptions_AddCategory(frame)
