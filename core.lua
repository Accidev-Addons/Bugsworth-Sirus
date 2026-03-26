-----------------------------------------------------------------------
-- BUGSWORTH · core.lua
-- Error capture engine (merged from !BugGrabber + BugSack)
-----------------------------------------------------------------------

local ADDON_NAME = ...

-- Cached globals for hot paths
local format = string.format
local find, match, sub, len, gsub, gmatch = string.find, string.match, string.sub, string.len, string.gsub, string.gmatch
local floor, min = math.floor, math.min
local concat, sort = table.concat, table.sort
local tostring, type, pairs, ipairs, date = tostring, type, pairs, ipairs, date

-- SavedVariables
BugsworthDB = BugsworthDB or {}

local BC = {}
_G.Bugsworth = BC

local real_seterrorhandler = seterrorhandler

local frame = CreateFrame("Frame")
local callbacks = nil

-- Defaults
local MAX_ERRORS = 1000
local MAX_STACK_LEN = 500
local ERRORS_PER_SEC_BEFORE_THROTTLE = 20
local TIME_TO_RESUME = 60

-- Runtime state
local totalElapsed = 0
local errorsSinceLastReset = 0
local paused = nil
local looping = false

-- Performance: session-scoped dedup index (Fix 2)
local dedupIndex = {}

-- Performance: addon version cache (Fix 3)
local addonVersionCache = {}

-----------------------------------------------------------------------
-- Performance: O(n) bulk trim helper (Fix 1)
-- Replaces O(n²) table.remove(db, 1) loops
-----------------------------------------------------------------------
local function trimDB(limit)
    local db = BugsworthDB.errors
    if not db or #db <= limit then return end
    local overflow = #db - limit
    local trimmed = {}
    for i = overflow + 1, #db do
        trimmed[#trimmed + 1] = db[i]
    end
    BugsworthDB.errors = trimmed
end

-----------------------------------------------------------------------
-- Callback system
-----------------------------------------------------------------------
local function setupCallbacks()
    if not callbacks and LibStub and LibStub("CallbackHandler-1.0", true) then
        callbacks = LibStub("CallbackHandler-1.0"):New(BC)
    end
end

local function triggerEvent(...)
    if not callbacks then setupCallbacks() end
    if callbacks then callbacks:Fire(...) end
end

-----------------------------------------------------------------------
-- Database helpers
-----------------------------------------------------------------------
function BC:GetDB()
    return BugsworthDB.errors or {}
end

function BC:GetSessionId()
    return BugsworthDB.session or 0
end

function BC:StoreError(errorObject)
    local db = BugsworthDB.errors
    db[#db + 1] = errorObject
    local limit = BugsworthDB.limit or MAX_ERRORS
    trimDB(limit)
end

function BC:Reset()
    BugsworthDB.errors = {}
    dedupIndex = {}
end

-----------------------------------------------------------------------
-- Addon extraction & ignore list helpers
-----------------------------------------------------------------------
function BC:GetAddonFromError(err)
    local m = err.message
    if type(m) == "table" then m = m[1] or "" end
    if type(m) ~= "string" then return "Unknown" end
    -- Try to extract addon name from stack trace path
    local addon = m:match("[Aa][Dd][Dd][Oo][Nn][Ss]\\([^\\]+)")
    if addon then return addon end
    -- Try string eval pattern
    addon = m:match('%[string ".-([^\\]+)\\')
    if addon then return addon end
    return "Unknown"
end

function BC:IsAddonIgnored(addonName)
    if not BugsworthDB.ignoreList then return false end
    return BugsworthDB.ignoreList[addonName] and true or false
end

function BC:SetAddonIgnored(addonName, ignored)
    if not BugsworthDB.ignoreList then BugsworthDB.ignoreList = {} end
    BugsworthDB.ignoreList[addonName] = ignored and true or nil
end

function BC:GetIgnoredAddons()
    return BugsworthDB.ignoreList or {}
end

function BC:GetLimit()
    return BugsworthDB.limit or 50
end

function BC:SetLimit(l)
    if type(l) ~= "number" or l < 10 or l > MAX_ERRORS then return end
    BugsworthDB.limit = floor(l)
    trimDB(l)
end

function BC:IsThrottling()
    return BugsworthDB.throttle
end

function BC:UseThrottling(flag)
    BugsworthDB.throttle = flag and true or false
    if flag then
        frame:SetScript("OnUpdate", BC._onUpdate)
    else
        frame:SetScript("OnUpdate", nil)
    end
end

-----------------------------------------------------------------------
-- Addon action events
-----------------------------------------------------------------------
function BC:RegisterAddonActionEvents()
    frame:RegisterEvent("ADDON_ACTION_BLOCKED")
    frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    triggerEvent("Bugsworth_AddonActionEventsRegistered")
end

function BC:UnregisterAddonActionEvents()
    frame:UnregisterEvent("ADDON_ACTION_BLOCKED")
    frame:UnregisterEvent("ADDON_ACTION_FORBIDDEN")
    triggerEvent("Bugsworth_AddonActionEventsUnregistered")
end

-----------------------------------------------------------------------
-- Throttle / pause
-----------------------------------------------------------------------
function BC:IsPaused()
    return paused
end

function BC:Pause()
    if paused then return end
    DEFAULT_CHAT_FRAME:AddMessage(format(
        "|cffff4444BUGSWORTH|r has stopped capturing (>%d errors/sec). Resuming in %ds.",
        ERRORS_PER_SEC_BEFORE_THROTTLE, TIME_TO_RESUME
    ))
    self:UnregisterAddonActionEvents()
    paused = true
    triggerEvent("Bugsworth_CapturePaused")
end

function BC:Resume()
    if not paused then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cffff4444BUGSWORTH|r is capturing errors again.")
    self:RegisterAddonActionEvents()
    paused = nil
    triggerEvent("Bugsworth_CaptureResumed")
    totalElapsed = 0
end

function BC._onUpdate(self, elapsed)
    totalElapsed = totalElapsed + elapsed
    if totalElapsed > 1 then
        if not paused then
            if errorsSinceLastReset > ERRORS_PER_SEC_BEFORE_THROTTLE then
                BC:Pause()
            end
            errorsSinceLastReset = 0
            totalElapsed = 0
        elseif totalElapsed > TIME_TO_RESUME and paused then
            BC:Resume()
        end
    end
end

-----------------------------------------------------------------------
-- Stack trace normalization (from BugGrabber)
-----------------------------------------------------------------------
local ADDON_CALL_PROTECTED = "[%s] AddOn '%s' tried to call the protected function '%s'."
local ADDON_CALL_PROTECTED_MATCH = "^%[(.*)%] (AddOn '.*' tried to call the protected function '.*'.)$"

local function scan(o)
    local version, revision = nil, nil
    for k, v in pairs(o) do
        if type(k) == "string" then
            local low = k:lower()
            if not version and (low == "version" or low:find("version")) and (type(v) == "string" or type(v) == "number") then
                version = v
            elseif not revision and (low == "rev" or low:find("revision")) and (type(v) == "string" or type(v) == "number") then
                revision = v
            end
        end
        if version and revision then break end
    end
    return version, revision
end

-----------------------------------------------------------------------
-- Save an error into the database
-----------------------------------------------------------------------
local function saveError(message, errorType)
    local oe = {}
    oe.message = message .. "\n  ---"
    oe.session = BugsworthDB.session
    oe.time = date("%Y/%m/%d %H:%M:%S")
    oe.type = errorType
    oe.counter = 1

    -- WoW crashes when strings > 983 chars are stored in SV,
    -- so chunk long messages.
    if type(oe.message) == "string" and oe.message:len() > 980 then
        local m = oe.message
        oe.message = {}
        local maxChunks, chunks = 5, 0
        while m:len() > 980 and chunks <= maxChunks do
            local q
            q, m = m:sub(1, 980), m:sub(981)
            oe.message[#oe.message + 1] = q
            chunks = chunks + 1
        end
        if m:len() > 980 then m = m:sub(1, 980) end
        oe.message[#oe.message + 1] = m
    end

    -- Dedup: strip Locals section for comparison
    local oe_message = oe.message
    if type(oe_message) == "table" then
        oe_message = oe_message[1]
    end
    local dedupKey = oe_message and (oe_message:match("^(.-)\nLocals:") or oe_message) or ""

    -- O(1) dedup lookup (Fix 2)
    local existing = dedupIndex[dedupKey]
    local found = false
    if existing and existing.session == oe.session then
        if type(existing.counter) ~= "number" then existing.counter = 1 end
        existing.counter = existing.counter + 1
        oe = existing
        found = true
    else
        dedupIndex[dedupKey] = oe
    end

    if not found then
        BC:StoreError(oe)
    end

    -- Fire callbacks
    if not looping then
        local eventName = "Bugsworth_" .. (errorType == "event" and "Event" or "Bug") .. "Grabbed" .. (found and "Again" or "")
        triggerEvent(eventName, oe)

    end
end

-----------------------------------------------------------------------
-- Core error handler (from BugGrabber)
-----------------------------------------------------------------------
local function grabError(err)
    if paused then return end
    err = tostring(err)

    local real =
        err:find("^.-([^\\]+\\)([^\\]-)(:%d+):(.*)$") or
        err:find("^%[string \".-([^\\]+\\)([^\\]-)\"%](:%d+):(.*)$") or
        err:find("^%[string (\".-\")%](:%d+):(.*)$") or err:find("^%[C%]:(.*)$")

    err = err .. "\n" .. debugstack(real and 4 or 3)
    local errorType = "error"

    local errmsg = ""
    looping = false

    for trace in err:gmatch("(.-)\n") do
        local match, found, path, file, line, msg, _
        found = false

        if trace:find("Bugsworth") or trace:find("BugGrabber") then
            looping = true
        end

        -- Library path pattern
        if not found then
            match, _, path, file, line, msg = trace:find("^.-([^\\]+\\)([^\\]-%-%d+%.%d+%.lua)(:%d+):(.*)$")
            local addon = trace:match("^.-[A%.][d%.][d%.][Oo]ns\\([^\\]-)\\")
            if match then
                if LibStub then
                    local major = file:gsub("%.lua$", "")
                    local lib, minor = LibStub(major, true)
                    path = major .. "-" .. (minor or "?")
                    if addon then
                        file = " (" .. addon .. ")"
                    else
                        file = ""
                    end
                end
                found = true
            end
        end

        -- AddOns path pattern
        if not found then
            match, _, path, file, line, msg = trace:find("^.-[A%.][d%.][d%.][Oo]ns\\(.*)([^\\]-)(:%d+):(.*)$")
            if match then
                found = true
                local addon = path:gsub("\\.*$", "")
                -- Cached version lookup (Fix 3)
                local cachedVersion = addonVersionCache[addon]
                if cachedVersion == nil then
                    local addonObject = _G[addon]
                    if not addonObject then
                        addonObject = _G[addon:match("^[^_]+_(.*)$")]
                    end
                    local version, revision = nil, nil
                    if LibStub and LibStub(addon, true) then
                        local _, r = LibStub(addon, true)
                        version = r
                    end
                    if type(addonObject) == "table" then
                        local v, r = scan(addonObject)
                        if v then version = v end
                        if r then revision = r end
                    end
                    local objectName = addon:upper()
                    if not version then version = _G[objectName .. "_VERSION"] end
                    if not revision then revision = _G[objectName .. "_REVISION"] or _G[objectName .. "_REV"] end
                    if not version and GetAddOnMetadata then version = GetAddOnMetadata(addon, "Version") end
                    if not version and revision then version = revision
                    elseif type(version) == "string" and revision and not version:find(revision) then
                        version = version .. "." .. revision
                    end
                    addonVersionCache[addon] = version or false
                    cachedVersion = version or false
                end
                if cachedVersion then
                    path = addon .. "-" .. cachedVersion .. path:gsub("^[^\\]*", "")
                end
            end
        end

        -- Generic path pattern
        if not found then
            match, _, path, file, line, msg = trace:find("^.-([^\\]+\\)([^\\])(:%d+):(.*)$")
            if match then found = true end
        end

        -- String eval pattern
        if not found then
            match, _, path, file, line, msg = trace:find("^%[string \".-([^\\]+\\)([^\\]-)\"%](:%d+):(.*)$")
            if match then found = true end
        end

        -- Short string pattern
        if not found then
            match, _, file, line, msg = trace:find("^%[string (\".-\")%](:%d+):(.*)$")
            if match then
                found = true
                path = "<string>:"
            end
        end

        -- [C] pattern
        if not found then
            match, _, msg = trace:find("^%[C%]:(.*)$")
            if match then
                found = true
                path = "<in C code>"
                file = ""
                line = ""
            end
        end

        -- ADDON_ACTION_BLOCKED
        if not found then
            match, _, file, msg = trace:find(ADDON_CALL_PROTECTED_MATCH)
            if match then
                found = true
                path = "<event>"
                file = "ADDON_ACTION_BLOCKED"
                line = ""
                errorType = "event"
            end
        end

        -- Fallback
        if not found then
            path = trace
            file = ""
            line = ""
            msg = line
        end

        errmsg = errmsg .. (path or "") .. (file or "") .. (line or "") .. ":" .. (msg or "") .. "\n"
    end

    errorsSinceLastReset = errorsSinceLastReset + 1

    local locals = debuglocals(real and 4 or 3)
    if locals then
        errmsg = errmsg .. "\nLocals:|r\n" .. locals
    end

    saveError(errmsg, errorType)
end

-----------------------------------------------------------------------
-- Swatter compat (for Stubby/Auctioneer)
-----------------------------------------------------------------------
local function createSwatter()
    _G.Swatter = {
        IsEnabled = function() return true end,
        OnError = function(msg, frame, stack, etype, ...)
            grabError(tostring(msg) .. tostring(stack))
        end,
    }
end

-----------------------------------------------------------------------
-- ADDON_LOADED handler
-----------------------------------------------------------------------
local function onAddonLoaded(addon)
    if addon == ADDON_NAME then
        real_seterrorhandler(grabError)

        -- Initialize SavedVariables
        if type(BugsworthDB) ~= "table" then BugsworthDB = {} end
        local sv = BugsworthDB
        if type(sv.session) ~= "number" then sv.session = 0 end
        if type(sv.errors) ~= "table" then sv.errors = {} end
        if type(sv.limit) ~= "number" then sv.limit = 50 end
        if type(sv.throttle) ~= "boolean" then sv.throttle = true end
        -- Display settings (used by viewer/config)
        if type(sv.auto) ~= "boolean" then sv.auto = false end
        if type(sv.chatframe) ~= "boolean" then sv.chatframe = false end
        if type(sv.mute) ~= "boolean" then sv.mute = false end
        if type(sv.filterAddonMistakes) ~= "boolean" then sv.filterAddonMistakes = true end
        if type(sv.suppressDefault) ~= "boolean" then sv.suppressDefault = true end
        if type(sv.ignoreList) ~= "table" then sv.ignoreList = {} end

        -- New session
        sv.session = sv.session + 1

        -- Trim database
        trimDB(sv.limit)

        -- Rebuild dedup index for current session (Fix 2)
        dedupIndex = {}
        for _, err in ipairs(sv.errors) do
            if err.session == sv.session then
                local m = type(err.message) == "table" and err.message[1] or err.message
                local key = m and (m:match("^(.-)\nLocals:") or m) or ""
                dedupIndex[key] = err
            end
        end

        -- Start throttle if enabled
        if sv.throttle then
            frame:SetScript("OnUpdate", BC._onUpdate)
        end

        -- Register for addon action events unless filtered
        if not sv.filterAddonMistakes then
            BC:RegisterAddonActionEvents()
        end

    elseif (addon == "!Swatter" or (type(SwatterData) == "table" and SwatterData.enabled)) and Swatter then
        -- Disable Swatter if present
        DisableAddOn("!Swatter")
        SwatterData.enabled = nil
        real_seterrorhandler(grabError)
    elseif addon == "Stubby" then
        createSwatter()
    end
end

-----------------------------------------------------------------------
-- Event dispatcher
-----------------------------------------------------------------------
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        grabError(ADDON_CALL_PROTECTED:format(event, arg1 or "?", arg2 or "?"))
    elseif event == "ADDON_LOADED" then
        onAddonLoaded(arg1 or "?")
        if not callbacks then setupCallbacks() end
    elseif event == "PLAYER_LOGIN" then
        real_seterrorhandler(grabError)
        if IsAddOnLoaded("Stubby") and type(_G.Swatter) ~= "table" then
            createSwatter()
        end

        -- Auto-suppress default error frame
        if BugsworthDB.suppressDefault then
            local function suppressFrame(f)
                if f and f.SetScript then
                    f:SetScript("OnShow", function(self) self:Hide() end)
                end
            end
            suppressFrame(_G.BasicScriptErrors)
            suppressFrame(_G.ScriptErrorsFrame)
        end

        -- Startup notification
        local errCount = #(BugsworthDB.errors or {})
        local sessionId = BugsworthDB.session or 0
        DEFAULT_CHAT_FRAME:AddMessage(format(
            "|cFFEDA55fBugs|rworth: Session |cff44ff44%d|r started. |cff88ccff%d|r errors in database.",
            sessionId, errCount
        ))
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

-- Hook the error handler immediately
real_seterrorhandler(grabError)
function seterrorhandler() --[[ noop — prevent other addons from unhooking us ]] end

-----------------------------------------------------------------------
-- Slash commands
-----------------------------------------------------------------------
SLASH_BUGSWORTH1 = "/bugs"
SLASH_BUGSWORTH2 = "/BUGSWORTH"
SlashCmdList["BUGSWORTH"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "clear" then
        BC:Reset()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: All errors cleared.")
        if BC.OnErrorCountChanged then BC:OnErrorCountChanged() end
        return
    end

    if msg == "count" then
        local db = BugsworthDB.errors or {}
        local sessionId = BugsworthDB.session or 0
        local thisSession, prevSessions = 0, 0
        for _, err in ipairs(db) do
            if err.session == sessionId then
                thisSession = thisSession + (err.counter or 1)
            else
                prevSessions = prevSessions + (err.counter or 1)
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage(format(
            "|cFFEDA55fBugs|rworth: %d unique errors (%d this session, %d previous).",
            #db, thisSession, prevSessions
        ))
        return
    end

    if msg == "config" then
        InterfaceOptionsFrame_OpenToCategory("Bugsworth")
        InterfaceOptionsFrame_OpenToCategory("Bugsworth")
        return
    end

    -- /bugs last [N]
    local lastN = msg:match("^last%s*(%d*)$")
    if msg == "last" or lastN then
        local n = tonumber(lastN) or 1
        local db = BugsworthDB.errors or {}
        if #db == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: No errors in database.")
            return
        end
        n = min(n, #db)
        DEFAULT_CHAT_FRAME:AddMessage(format("|cFFEDA55fBugs|rworth: Last %d error(s):", n))
        for i = #db, #db - n + 1, -1 do
            local err = db[i]
            local m = err.message
            if type(m) == "table" then m = concat(m, "") end
            -- Get meaningful first line
            local line = (m or ""):match("^(.-)\n") or (m or ""):sub(1, 120)
            line = line:gsub("[Ii]nterface\\[Aa]dd[Oo]ns\\", "")
            if line:len() > 120 then line = line:sub(1, 120) .. "..." end
            DEFAULT_CHAT_FRAME:AddMessage(format(
                "  |cff999999%dx|r |cffeda55f[S%d]|r %s",
                err.counter or 1, err.session or 0, line
            ))
        end
        return
    end

    -- /bugs export
    if msg == "export" then
        local db = BugsworthDB.errors or {}
        if #db == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: No errors to export.")
            return
        end
        local lines = {}
        lines[#lines + 1] = format("Bugsworth Error Export — %s — %d errors", date("%Y-%m-%d %H:%M:%S"), #db)
        lines[#lines + 1] = string.rep("=", 60)
        for i, err in ipairs(db) do
            local m = err.message
            if type(m) == "table" then m = concat(m, "") end
            lines[#lines + 1] = format("\n--- Error %d [Session %d] [%s] [%dx] ---",
                i, err.session or 0, err.time or "?", err.counter or 1)
            lines[#lines + 1] = m or "(no message)"
        end
        BugsworthExport = concat(lines, "\n")
        DEFAULT_CHAT_FRAME:AddMessage(format(
            "|cFFEDA55fBugs|rworth: Exported %d errors to BugsworthExport. |cff88ccff/reload|r then check WTF/Account/<name>/SavedVariables/Bugsworth.lua",
            #db
        ))
        return
    end

    -- /bugs ignore [addon]
    if msg:match("^ignore") then
        local addon = msg:match("^ignore%s+(.+)$")
        if addon then
            BC:SetAddonIgnored(addon, true)
            DEFAULT_CHAT_FRAME:AddMessage(format(
                "|cFFEDA55fBugs|rworth: Now ignoring errors from |cffff8800%s|r.", addon
            ))
        else
            local list = BC:GetIgnoredAddons()
            local count = 0
            DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: Ignored addons:")
            for name, _ in pairs(list) do
                DEFAULT_CHAT_FRAME:AddMessage("  - " .. name)
                count = count + 1
            end
            if count == 0 then
                DEFAULT_CHAT_FRAME:AddMessage("  (none)")
            end
        end
        return
    end

    -- /bugs unignore [addon]
    if msg:match("^unignore") then
        local addon = msg:match("^unignore%s+(.+)$")
        if addon then
            BC:SetAddonIgnored(addon, false)
            DEFAULT_CHAT_FRAME:AddMessage(format(
                "|cFFEDA55fBugs|rworth: No longer ignoring |cff44ff44%s|r.", addon
            ))
        end
        return
    end

    -- /bugs help
    if msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs|r — Open viewer")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs count|r — Error summary")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs last [N]|r — Print last N errors to chat")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs clear|r — Wipe all errors")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs config|r — Open settings")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs export|r — Export errors to SavedVariable")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs ignore [addon]|r — Ignore addon errors")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs unignore [addon]|r — Stop ignoring addon")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffeda55f/bugs help|r — Show this help")
        return
    end

    -- Default: open viewer
    if BC.OpenViewer then
        BC:OpenViewer()
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFEDA55fBugs|rworth: Viewer not loaded yet.")
    end
end

-----------------------------------------------------------------------
-- BugGrabber compatibility shim
-- Other addons that call BugGrabber:RegisterCallback etc still work
-----------------------------------------------------------------------
_G.BugGrabber = _G.BugGrabber or setmetatable({}, {
    __index = function(_, key)
        -- Map BugGrabber API → BUGSWORTH API
        if BC[key] then return BC[key] end
        return nil
    end
})
-- Ensure key methods are directly accessible
_G.BugGrabber.GetDB = function() return BC:GetDB() end
_G.BugGrabber.GetSessionId = function() return BC:GetSessionId() end
_G.BugGrabber.StoreError = function(_, eo) return BC:StoreError(eo) end
_G.BugGrabber.Reset = function() return BC:Reset() end
_G.BugGrabber.GetSave = function() return true end  -- always persist
_G.BugGrabber.ToggleSave = function() end            -- noop, always save
_G.BugGrabber.GetLimit = function() return BC:GetLimit() end
_G.BugGrabber.SetLimit = function(_, l) return BC:SetLimit(l) end
_G.BugGrabber.IsThrottling = function() return BC:IsThrottling() end
_G.BugGrabber.UseThrottling = function(_, f) return BC:UseThrottling(f) end
_G.BugGrabber.RegisterAddonActionEvents = function() return BC:RegisterAddonActionEvents() end
_G.BugGrabber.UnregisterAddonActionEvents = function() return BC:UnregisterAddonActionEvents() end
_G.BugGrabber.IsPaused = function() return BC:IsPaused() end
_G.BugGrabber.Pause = function() return BC:Pause() end
_G.BugGrabber.Resume = function() return BC:Resume() end

-- Forward RegisterCallback from BugGrabber → BUGSWORTH
-- (handles BugGrabber_BugGrabbed → Bugsworth_BugGrabbed mapping)
if not _G.BugGrabber.RegisterCallback then
    local bgShim = _G.BugGrabber
    function bgShim:RegisterCallback(eventName, funcOrMethod, ...)
        if not callbacks then setupCallbacks() end
        if callbacks then
            -- Remap event names
            local bcEvent = eventName:gsub("^BugGrabber_", "Bugsworth_")
            callbacks.RegisterCallback(self, bcEvent, funcOrMethod, ...)
        end
    end
    function bgShim:UnregisterCallback(eventName)
        if callbacks then
            local bcEvent = eventName:gsub("^BugGrabber_", "Bugsworth_")
            callbacks.UnregisterCallback(self, bcEvent)
        end
    end
end
