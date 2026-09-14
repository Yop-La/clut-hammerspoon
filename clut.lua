-- CLUT without an extension: switch between the most recently used Chrome
-- tabs, across all windows and profiles.
--
--   ⌥W   : toggle between the last 2 tabs
--   ⌥S   : go back through history (hold ⌥, press S repeatedly;
--          releasing ⌥ confirms the selected tab)
--   ⌥⇧S  : same, in the other direction
--
-- Shortcuts are only active while Chrome is the frontmost app.

local M = {}

local BUNDLE = "com.google.Chrome"
local APP = "Google Chrome"
local MAX_HISTORY = 100
local POLL_INTERVAL = 0.5   -- safety net while Chrome is frontmost
local SHOW_HUD = true       -- show the target tab while cycling with ⌥S
local SETTINGS_KEY = "clut.mru"

M.mru = {}        -- tab ids, [1] = current tab
M.cycling = nil   -- { list, pos } during a ⌥S cycle

-- ---------------------------------------------------------------------------
-- Chrome access (AppleScript)
-- ---------------------------------------------------------------------------

local function toId(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

local function chromeRunning()
    return hs.application.get(BUNDLE) ~= nil
end

local function chromeFront()
    local app = hs.application.frontmostApplication()
    return app ~= nil and app:bundleID() == BUNDLE
end

-- Never call when Chrome is not running: "tell" would launch it.
local function tell(body)
    local ok, res = hs.osascript.applescript(
        'tell application "' .. APP .. '"\n' .. body .. '\nend tell')
    if not ok then return nil end
    return res
end

local function activeTabId()
    return toId(tell([[
if (count of windows) is 0 then return ""
return (id of active tab of front window) as text]]))
end

-- Set of open tab ids, or nil if the query fails.
local function openTabSet()
    local r = tell("return id of every tab of every window")
    if type(r) ~= "table" then return nil end
    local set = {}
    for _, win in ipairs(r) do
        if type(win) == "table" then
            for _, id in ipairs(win) do
                local i = toId(id)
                if i then set[i] = true end
            end
        else
            local i = toId(win)
            if i then set[i] = true end
        end
    end
    return set
end

-- Give keyboard focus to the Chrome window that was just brought forward.
-- Several windows can share the same frame (maximized): prefer the one whose
-- title matches, otherwise the frontmost one.
local function focusWindow(title, x, y)
    local app = hs.application.get(BUNDLE)
    if not app then return end
    local pid = app:pid()
    local best
    for _, w in ipairs(hs.window.orderedWindows()) do
        local wapp = w:application()
        if wapp and wapp:pid() == pid then
            local f = w:frame()
            if math.abs(f.x - x) < 4 and math.abs(f.y - y) < 4 then
                if w:title() == title then
                    best = w
                    break
                end
                best = best or w
            end
        end
    end
    local focused = hs.window.focusedWindow()
    if best and (not focused or focused:id() ~= best:id()) then
        best:focus()
    end
end

-- Activate the tab and bring its window forward. Returns the tab title, or nil
-- if the tab no longer exists. Chrome returns tab ids as text, hence the
-- string comparison.
local function activateTab(id)
    local r = tell(string.format([[
repeat with w in (every window)
    set ids to id of every tab of w
    repeat with i from 1 to count of ids
        if ((item i of ids) as text) is "%d" then
            set wid to id of w
            if minimized of window id wid then set minimized of window id wid to false
            set active tab index of window id wid to i
            set index of window id wid to 1
            activate
            set b to bounds of window id wid
            return (title of active tab of window id wid) & "\t" & ¬
                ((item 1 of b) as text) & "\t" & ((item 2 of b) as text)
        end if
    end repeat
end repeat
return ""]], id))
    if type(r) ~= "string" or r == "" then return nil end
    local title, x, y = r:match("^(.*)\t(-?%d+)\t(-?%d+)$")
    if not title then return r end
    hs.timer.doAfter(0.08, function()
        focusWindow(title, tonumber(x), tonumber(y))
    end)
    return title
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

local function save()
    hs.settings.set(SETTINGS_KEY, M.mru)
end

local function removeId(list, id)
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
end

local function record(id)
    if not id or M.mru[1] == id then return end
    removeId(M.mru, id)
    table.insert(M.mru, 1, id)
    while #M.mru > MAX_HISTORY do table.remove(M.mru) end
    save()
end

function M.refresh()
    if M.cycling or not chromeRunning() then return end
    record(activeTabId())
end

-- Drop closed tabs from the history.
function M.prune()
    if not chromeRunning() then return end
    local open = openTabSet()
    if not open then return end
    local kept = {}
    for _, id in ipairs(M.mru) do
        if open[id] then table.insert(kept, id) end
    end
    M.mru = kept
    save()
end

local function hud(text)
    if not SHOW_HUD then return end
    if M.hudId then hs.alert.closeSpecific(M.hudId, 0) end
    M.hudId = hs.alert.show(text, { textSize = 16, radius = 8,
        fadeInDuration = 0, fadeOutDuration = 0.1 }, hs.screen.mainScreen(), 1.2)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function M.toggle()
    if not chromeRunning() then return end
    if M.cycling then M.commit() end
    M.refresh()
    M.prune()
    while #M.mru >= 2 do
        local id = M.mru[2]
        if activateTab(id) then
            record(id)
            return
        end
        table.remove(M.mru, 2)
    end
end

function M.commit()
    local c = M.cycling
    M.cycling = nil
    if M.modTimer then
        M.modTimer:stop()
        M.modTimer = nil
    end
    if M.hudId then
        hs.alert.closeSpecific(M.hudId)
        M.hudId = nil
    end
    if c then record(c.list[c.pos]) end
end

function M.cycle(dir)
    if not chromeRunning() then return end
    if not M.cycling then
        M.refresh()
        M.prune()
        if #M.mru < 2 then return end
        M.cycling = { list = { table.unpack(M.mru) }, pos = 1 }
        -- Releasing ⌥ confirms the choice (no event tap needed for that).
        M.modTimer = hs.timer.doEvery(0.05, function()
            if not hs.eventtap.checkKeyboardModifiers().alt then M.commit() end
        end)
    end
    local c = M.cycling
    for _ = 1, #c.list do
        local n = #c.list
        if n < 2 then break end
        local pos = ((c.pos - 1 + dir) % n) + 1
        local title = activateTab(c.list[pos])
        if title then
            c.pos = pos
            hud(string.format("↶ %d/%d   %s", pos - 1, n - 1, title))
            return
        end
        -- Tab closed in the meantime: drop it and try the next one.
        table.remove(c.list, pos)
        if pos < c.pos then c.pos = c.pos - 1 end
    end
end

-- For debugging: `hs -c "return clut.dump()"`.
function M.dump()
    if not chromeRunning() then return "Chrome is not running" end
    local r = tell([[
set out to ""
repeat with w in (every window)
    repeat with t in (every tab of w)
        set out to out & ((id of t) as text) & "\t" & (title of t) & linefeed
    end repeat
end repeat
return out]])
    local titles = {}
    for line in (r or ""):gmatch("[^\n]+") do
        local id, title = line:match("^(%d+)\t(.*)$")
        if id then titles[toId(id)] = title end
    end
    local lines = {}
    for i, id in ipairs(M.mru) do
        table.insert(lines, string.format("%2d. [%d] %s", i, id,
            titles[id] or "(closed)"))
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

local function setChromeFront(front)
    for _, hk in ipairs(M.hotkeys) do
        if front then hk:enable() else hk:disable() end
    end
    if front then
        M.poll:start()
        M.refresh()
    else
        M.poll:stop()
        if M.cycling then M.commit() end
    end
end

function M.start()
    M.mru = {}
    for _, v in ipairs(hs.settings.get(SETTINGS_KEY) or {}) do
        local id = toId(v)
        if id then table.insert(M.mru, id) end
    end

    M.hotkeys = {
        hs.hotkey.new({ "alt" }, "w", M.toggle),
        hs.hotkey.new({ "alt" }, "s", function() M.cycle(1) end),
        hs.hotkey.new({ "alt", "shift" }, "s", function() M.cycle(-1) end),
    }
    M.poll = hs.timer.new(POLL_INTERVAL, M.refresh)
    M.debounced = hs.timer.delayed.new(0.15, M.refresh)

    local w = hs.application.watcher
    M.appWatcher = w.new(function(name, event, app)
        local isChrome = name == APP or (app and app:bundleID() == BUNDLE)
        if not isChrome then return end
        if event == w.activated then
            setChromeFront(true)
        elseif event == w.deactivated then
            setChromeFront(false)
        elseif event == w.terminated then
            setChromeFront(false)
            M.mru = {}
            save()
        end
    end)
    M.appWatcher:start()

    -- A tab switch changes the window title: react immediately.
    M.windowFilter = hs.window.filter.new(false):setAppFilter(APP)
    M.windowFilter:subscribe({
        hs.window.filter.windowFocused,
        hs.window.filter.windowTitleChanged,
    }, function() M.debounced:start() end)

    M.prune()
    setChromeFront(chromeFront())
end

return M
