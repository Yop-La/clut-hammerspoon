-- CLUT maison : bascule entre les derniers onglets Chrome utilisés,
-- toutes fenêtres et tous profils confondus (sans extension Chrome).
--
--   ⌥W   : bascule entre les 2 derniers onglets
--   ⌥S   : remonte l'historique (garder ⌥ enfoncé, appuyer plusieurs fois
--          sur S ; relâcher ⌥ valide l'onglet choisi)
--   ⌥⇧S  : même chose dans l'autre sens
--
-- Les raccourcis ne sont actifs que lorsque Chrome est au premier plan.

local M = {}

local BUNDLE = "com.google.Chrome"
local APP = "Google Chrome"
local MAX_HISTORY = 100
local POLL_INTERVAL = 0.5   -- filet de sécurité quand Chrome est au premier plan
local SHOW_HUD = true       -- affiche l'onglet visé pendant ⌥S
local SETTINGS_KEY = "clut.mru"

M.mru = {}        -- ids d'onglets, [1] = onglet courant
M.cycling = nil   -- { list, pos } pendant un cycle ⌥S

-- ---------------------------------------------------------------------------
-- Accès à Chrome (AppleScript)
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

-- Ne jamais appeler si Chrome n'est pas lancé : « tell » le démarrerait.
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

-- Ensemble des ids d'onglets ouverts, ou nil si la requête échoue.
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

-- Donne le focus clavier à la fenêtre Chrome qui vient d'être mise devant.
-- Plusieurs fenêtres peuvent avoir le même cadre (maximisées) : on préfère
-- celle dont le titre correspond, sinon la plus en avant.
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

-- Active l'onglet et ramène sa fenêtre devant. Renvoie son titre, ou nil si
-- l'onglet n'existe plus.
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
-- Historique
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

-- Retire de l'historique les onglets fermés.
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
        -- Relâcher ⌥ valide le choix (pas besoin d'event tap pour ça).
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
        -- Onglet fermé entre-temps : on le retire et on réessaie.
        table.remove(c.list, pos)
        if pos < c.pos then c.pos = c.pos - 1 end
    end
end

-- Pour le débogage : `hs -c "clut.dump()"`.
function M.dump()
    if not chromeRunning() then return "Chrome n'est pas lancé" end
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
            titles[id] or "(fermé)"))
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Démarrage
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

    -- Changement d'onglet = changement de titre de fenêtre : réaction immédiate.
    M.windowFilter = hs.window.filter.new(false):setAppFilter(APP)
    M.windowFilter:subscribe({
        hs.window.filter.windowFocused,
        hs.window.filter.windowTitleChanged,
    }, function() M.debounced:start() end)

    M.prune()
    setChromeFront(chromeFront())
end

return M
