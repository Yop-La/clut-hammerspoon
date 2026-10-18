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
M.debug = false   -- set to true to trace shortcuts in the Hammerspoon console

local function log(fmt, ...)
    if M.debug then print("[clut] " .. string.format(fmt, ...)) end
end

-- ---------------------------------------------------------------------------
-- Chrome access (AppleScript, or JXA by pid when several instances run)
-- ---------------------------------------------------------------------------

local function toId(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

-- The Chrome instance the user works in. Other instances (headless ones
-- started by scripts and browser-driving agents with --headless /
-- --user-data-dir) share the bundle id and have no windows, so the one with
-- windows wins.
local function chromeApp(apps)
    apps = apps or hs.application.applicationsForBundleID(BUNDLE)
    for _, app in ipairs(apps) do
        if #app:allWindows() > 0 then return app end
    end
    return apps[1]
end

local function chromeRunning()
    return hs.application.get(BUNDLE) ~= nil
end

local function chromeFront()
    local app = hs.application.frontmostApplication()
    return app ~= nil and app:bundleID() == BUNDLE
end

-- Focused Chrome window according to Accessibility, or nil. Chrome sometimes
-- reports no focused window at all even when frontmost.
local function focusedChromeWindow()
    local win = hs.window.focusedWindow()
    if win and win:application() and win:application():bundleID() == BUNDLE then
        return win
    end
    local app = chromeApp()
    return app and (app:focusedWindow() or app:mainWindow()) or nil
end

-- Never call when Chrome is not running: "tell" would launch it.
local function tell(body)
    local ok, res = hs.osascript.applescript(
        'tell application "' .. APP .. '"\n' .. body .. '\nend tell')
    if not ok then return nil end
    return res
end

-- Helpers available to every JXA body. Windows come in front-to-back order.
local JXA_PRELUDE = [[
ObjC.import("ScriptingBridge");
var app = $.SBApplication.applicationWithProcessIdentifier(%d);
function get(o, k) { return ObjC.unwrap(o.valueForKey(k)); }
function windows() {
    var a = app.valueForKey("windows"), r = [];
    for (var i = 0; i < a.count; i++) r.push(a.objectAtIndex(i));
    return r;
}
function byId(wid) { return app.valueForKey("windows").objectWithID(wid); }
function origin(w) { return w.valueForKey("bounds").rectValue.origin; }
function tabsOf(w, k) { return ObjC.deepUnwrap(w.valueForKey("tabs").valueForKey(k)); }
function activeTabId(w) { return String(get(w.valueForKey("activeTab"), "id")); }
]]

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Run a query against the user's Chrome. "tell application" cannot choose
-- between instances and may talk to a headless one, so as soon as several
-- are running the JXA variant addresses the right one by pid, in a separate
-- osascript process (~0.2 s; ScriptingBridge inside Hammerspoon hangs).
local function chrome(applescript, jxa)
    local apps = hs.application.applicationsForBundleID(BUNDLE)
    if #apps <= 1 then return tell(applescript) end
    local app = chromeApp(apps)
    if not app then return nil end
    local js = string.format(JXA_PRELUDE, app:pid())
        .. "(function () {\n" .. jxa .. "\n})();"
    local out, ok = hs.execute("/usr/bin/osascript -l JavaScript -e " .. shellQuote(js))
    if not ok then return nil end
    return (out:gsub("\n$", ""))
end

-- Id of the tab the user is actually looking at. AppleScript's "front window"
-- is not reliable: a stray window (an off-screen popup, a leftover one-tab
-- window) can sit at index 1 forever and make us track the wrong tab. So the
-- window focused according to macOS wins, matched by frame; "front window" is
-- only the fallback when Accessibility gives us nothing.
local function activeTabId()
    local win = focusedChromeWindow()
    if win then
        local f = win:frame()
        local x0, x1, y0, y1 = f.x - 5, f.x + 5, f.y - 5, f.y + 5
        local r = chrome(string.format([[
repeat with w in (every window)
    set b to bounds of w
    if ((item 1 of b) > %d) and ((item 1 of b) < %d) and ¬
       ((item 2 of b) > %d) and ((item 2 of b) < %d) then
        return (id of active tab of w) as text
    end if
end repeat
return ""]], x0, x1, y0, y1), string.format([[
var ws = windows();
for (var i = 0; i < ws.length; i++) {
    var o = origin(ws[i]);
    if (o.x > %d && o.x < %d && o.y > %d && o.y < %d) return activeTabId(ws[i]);
}
return "";]], x0, x1, y0, y1))
        local id = toId(r)
        if id then return id end
    end
    return toId(chrome([[
if (count of windows) is 0 then return ""
return (id of active tab of front window) as text]], [[
var ws = windows();
return ws.length ? activeTabId(ws[0]) : "";]]))
end

-- Set of open tab ids, or nil if the query fails.
local function openTabSet()
    local r = chrome("return id of every tab of every window", [[
return windows().map(function (w) { return tabsOf(w, "id").join(","); }).join(",");]])
    local set = {}
    if type(r) == "string" then
        for id in r:gmatch("%d+") do set[toId(id)] = true end
        return set
    end
    if type(r) ~= "table" then return nil end
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
-- Only Chrome's own windows are queried: hs.window.orderedWindows() walks
-- every running app and can stall for seconds if one of them is slow.
-- Several windows can share the same frame (maximized), so a matching title
-- wins over a matching frame.
local function focusWindow(title, x, y)
    local app = chromeApp()
    if not app then return end
    local exact, sameFrame
    for _, w in ipairs(app:allWindows()) do
        local f = w:frame()
        if math.abs(f.x - x) < 4 and math.abs(f.y - y) < 4 then
            if w:title() == title then
                exact = exact or w
            else
                sameFrame = sameFrame or w
            end
        end
    end
    local target = exact or sameFrame
    local focused = hs.window.focusedWindow()
    if target and (not focused or focused:id() ~= target:id()) then
        target:focus()
    end
end

-- Activate the tab and bring its window forward. Returns the tab title, or nil
-- if the tab no longer exists. Chrome returns tab ids as text, hence the
-- string comparison.
local function activateTab(id)
    local r = chrome(string.format([[
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
return ""]], id), string.format([[
var ws = windows();
for (var n = 0; n < ws.length; n++) {
    var i = tabsOf(ws[n], "id").map(String).indexOf("%d");
    if (i < 0) continue;
    // Address the window by id: index specifiers shift once it is raised.
    var w = byId(get(ws[n], "id"));
    if (get(w, "minimized")) w.setValueForKey(false, "minimized");
    w.setValueForKey(i + 1, "activeTabIndex");
    w.setValueForKey(1, "index");
    app.activate;
    var o = origin(w);
    return get(w.valueForKey("activeTab"), "title") + "\t"
        + Math.round(o.x) + "\t" + Math.round(o.y);
}
return "";]], id))
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

-- Cheap AX check first: only ask Chrome (AppleScript, and Chrome can be slow
-- to answer when busy) when the focused window or its title actually changed.
-- Without an AX window we just ask Chrome (~30 ms) rather than miss the tab.
local lastSeen = {}

function M.refresh(force)
    if M.cycling or not chromeRunning() then return end
    local win = focusedChromeWindow()
    local key = win and { win = win:id(), title = win:title() }
    if not force and key and lastSeen.win == key.win
            and lastSeen.title == key.title then
        return
    end
    local id = activeTabId()
    record(id)
    -- Only remember what we saw once the tab was actually read, so a failed
    -- query is retried on the next poll.
    if id and key then lastSeen = key end
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
    log("toggle pressed")
    if not chromeRunning() then return end
    if M.cycling then M.commit() end
    M.refresh(true)
    M.prune()
    while #M.mru >= 2 do
        local id = M.mru[2]
        local title = activateTab(id)
        log("toggle -> %d (%s)", id, title or "not found")
        if title then
            record(id)
            return
        end
        table.remove(M.mru, 2)
    end
    log("toggle: nothing to switch to (history: %d)", #M.mru)
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
    log("cycle pressed (dir=%d)", dir)
    if not chromeRunning() then return end
    if not M.cycling then
        M.refresh(true)
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
        log("cycle -> %d/%d %s", pos - 1, n - 1, title or "not found")
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
    local r = chrome([[
set out to ""
repeat with w in (every window)
    repeat with t in (every tab of w)
        set out to out & ((id of t) as text) & "\t" & (title of t) & linefeed
    end repeat
end repeat
return out]], [[
var out = "";
windows().forEach(function (w) {
    var ids = tabsOf(w, "id"), titles = tabsOf(w, "title");
    for (var i = 0; i < ids.length; i++) out += ids[i] + "\t" + titles[i] + "\n";
});
return out;]])
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
        M.refresh(true)
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
    M.poll = hs.timer.new(POLL_INTERVAL, function() M.refresh() end)
    M.debounced = hs.timer.delayed.new(0.15, function() M.refresh() end)

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
