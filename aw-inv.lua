--[[
    aw-inv.lua
    Catdad — 2026-08-14

    Inventory panel: what you carry, wear, keyring and vault, indexed by
    serial and searchable. The foundation of a port of Durel's dinv from
    MUSHclient — this phase is the item table; identify stats, set scoring
    and the consumable/portal helpers build on it later.

    Everything arrives through Aardwolf's tagged data commands, which return
    machine CSV between {brace} markers:

        invdata           {invdata}      serial,flags,name,level,type,unique,wearloc,timer
        invdata <id>      {invdata}      the same, for one container's contents
        eqdata            {eqdata}       the same, wearloc set, for worn items
        keyring data      {keyring}      the same, indented
        vault data        {vault}        the same, plus {vaultcounts}used,?,capacity

    With Core's 'tags on' in effect the rows inside {invdata} arrive wrapped
    as {invitem}payload — measured by aw-loot, which reads the same block —
    so the parser takes both shapes: a row with the wrapper stripped, or the
    bare CSV the other blocks use.

    The name field can itself contain commas, so rows are split on every
    comma and rebuilt: two fields off the front, five off the back, the
    middle is the name. No pattern does that safely on this client. Names
    carry Aardwolf's own @-colour codes and are stored stripped, with @@
    surviving as a literal @ — the same decode aw-loot ships.

    Core gags the {invdata} block and hides unknown wrappers, and a gag does
    not hide a line from other plugins' triggers — so this plugin parses the
    very rows Core is hiding, and gags the rows of the blocks it asked for
    itself (eqdata/keyring/vault content is visible otherwise).

    Capture follows the house shape: every trigger registered at init and
    gated on state, because a trigger created mid-packet never sees the rest
    of the packet it was created in, and these blocks arrive whole.

    Sequencing without coroutines (dinv blocked on MUSHclient's wait library;
    there is no Lua VM here): a queue of expected blocks. A refresh sends
    eqdata, invdata and keyring data; containers discovered in the main
    inventory are scanned one per {/invdata}, each request pushed onto the
    queue so an arriving opener is matched to what asked for it. A 10s timer
    releases a block that never closes, the same guard Core keeps.

    {invmon} lines (Core gags them; we still see them) mark the table dirty
    and schedule one debounced refresh, so the panel follows looting without
    a resend per item.
]]

plugin = {
    id          = "aw-inv",
    name        = "Aardwolf Inventory",
    version     = "1.0.0",
    author      = "Catdad",
    description = "Inventory, worn, keyring and vault in one searchable panel, indexed by serial.",
    settings    = { saveState = true },
}

-- @category widgets

local TAG  = "$Y[Inventory v" .. plugin.version .. "]$w "
local TAGR = "$R[Inventory v" .. plugin.version .. "]$w "

local MAX_ROWS   = 400      -- rendered rows; the table itself is unbounded
local BLOCK_MS   = 10000    -- release a block that never closes
local DEBOUNCE_MS = 2500    -- invmon quiet time before an auto refresh
local MIN_AUTO_MS = 8000    -- floor between auto refreshes

local TYPE_NAME = {
    [0] = "None", [1] = "Light", [2] = "Scroll", [3] = "Wand", [4] = "Staff",
    [5] = "Weapon", [6] = "Treasure", [7] = "Armor", [8] = "Potion",
    [9] = "Furniture", [10] = "Trash", [11] = "Container", [12] = "Drink",
    [13] = "Key", [14] = "Food", [15] = "Boat", [16] = "Mobcorpse",
    [17] = "Playercorpse", [18] = "Fountain", [19] = "Pill", [20] = "Portal",
    [21] = "Beacon", [22] = "Giftcard", [24] = "Raw material",
    [25] = "Campfire", [26] = "Forge", [27] = "Runestone",
}

local FLAG_CLASS = {
    K = "fK", M = "fM", G = "fG", H = "fH", I = "fI",
    C = "fC", T = "fT", E = "fE", W = "fW", B = "fB", R = "fR",
}

local cfg = {
    gag     = true,      -- hide the CSV rows of blocks this plugin requested
    auto    = true,      -- refresh after {invmon} activity
    serials = true,      -- show serial numbers on rows
    fpx     = 0,         -- suite font px from Core's "aw-font" broadcast
    fov     = 0,         -- this panel's own font px; 0 = follow the suite
}

--[[
    The item table. items[serial] = one flat record; sections rebuilt on the
    fly for render. "where" is eq | inv | key | vault | c:<container serial>.
    Fields all declared, false and empty included — an unset field is
    undefined on this client, and undefined is truthy.
]]
local db = {
    items = {},          -- serial -> item
    vaultUsed = 0,
    vaultCap  = 0,
    haveVault = false,
    haveKey   = false,
}

--[[
    Capture state. expect is the queue of blocks we asked for, oldest first;
    each entry declares kind ("eq"|"inv"|"key"|"vault"|"c"), id ("" unless a
    container scan) and got (false until its opener arrives).
]]
local st = {
    expect   = {},
    inBlock  = "",       -- "" | eq | inv | key | vault | c
    inId     = "",       -- container serial while inBlock == "c"
    mine     = false,    -- current block is one we requested
    buf      = {},       -- serials seen in the current block
    conQueue = {},       -- containers awaiting a scan this refresh
    blockTimer = nil,
    pokeTimer  = nil,    -- invmon debounce
    lastAuto   = 0,      -- value of clockMs at the last auto refresh
    clockMs    = 0,      -- counter of debounce windows, bumped per invmon burst
}

local widget  = nil
local view    = "list"   -- "list" | "settings"
local filter  = ""
local rowTrig = nil

local function trim(s)
    return (string.gsub(tostring(s or ""), "^%s*(.-)%s*$", "%1"))
end

local function esc(s)
    s = tostring(s or "")
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    return s
end

local function drop_handlers(id, event)
    local ok, fn = pcall(function() return _G["unregisterWidgetEvent"] end)
    if ok and type(fn) == "function" then pcall(fn, id, event) end
end

local function font_base()
    if cfg.fov >= 6 and cfg.fov <= 48 then return cfg.fov end
    if cfg.fpx >= 6 and cfg.fpx <= 48 then return cfg.fpx end
    return 10
end

--[[
    Split on every comma by slicing — string.find's init argument does not
    advance on this client and a stuck loop takes the client down, so the
    haystack shrinks instead. The guard is a runaway cap, not a row limit.
]]
local function csv_fields(s)
    local out  = {}
    local rest = tostring(s or "")
    local guard = 0
    while guard < 300 do
        guard = guard + 1
        local p = string.find(rest, ",", 1, true)
        if p == nil then
            table.insert(out, rest)
            return out
        end
        table.insert(out, string.sub(rest, 1, p - 1))
        rest = string.sub(rest, p + 1)
    end
    return out
end

-- Aardwolf @-codes out of a short description; @@ is a literal @ and survives
local function decode(s)
    s = tostring(s or "")
    s = string.gsub(s, "@@", "\1")
    s = string.gsub(s, "@x%d+", "")
    s = string.gsub(s, "@%a", "")
    s = string.gsub(s, "\1", "@")
    return s
end

-- tonumber("") is 0 in JavaScript, so test the string before converting
local function num_or(s, dflt)
    s = trim(s)
    if s == "" then return dflt end
    local n = tonumber(s)
    if n == nil then return dflt end
    return n
end

--[[
    One CSV row into the table. Two fields off the front, five off the back;
    commas inside the name survive because the name is whatever is left.
]]
local function parse_row(line, where)
    local f = csv_fields(trim(line))
    local n = #f
    if n < 8 then return false end

    local serial = trim(f[1])
    if serial == "" or tonumber(serial) == nil then return false end

    local name = f[3]
    local i = 4
    while i <= n - 5 do
        name = name .. "," .. f[i]
        i = i + 1
    end

    local it = {
        serial = serial,
        flags  = trim(f[2]),
        name   = trim(decode(trim(name))),
        level  = num_or(f[n - 4], 0),
        itype  = num_or(f[n - 3], 0),
        unique = num_or(f[n - 2], 0),
        wear   = num_or(f[n - 1], -1),
        timer  = num_or(f[n], -1),
        where  = where,
    }
    db.items[serial] = it
    table.insert(st.buf, serial)
    return true
end

-- forget everything previously filed under a location before refiling it
local function clear_where(where)
    local goners = {}
    for serial, it in pairs(db.items) do
        if type(it) == "table" and it.where == where then
            table.insert(goners, serial)
        end
    end
    for _, serial in ipairs(goners) do
        db.items[serial] = nil
    end
end

---
-- persistence: one string blob, tab-separated fields, newline-separated
-- items. Nested tables through loadTable are not safely indexable here;
-- a string round-trips exactly.
---

local function save_db()
    local rows = {}
    for _, it in pairs(db.items) do
        if type(it) == "table" then
            table.insert(rows, it.serial .. "\t" .. it.flags .. "\t"
                .. it.level .. "\t" .. it.itype .. "\t" .. it.unique .. "\t"
                .. it.wear .. "\t" .. it.timer .. "\t" .. it.where .. "\t"
                .. it.name)
        end
    end
    saveTable("aw_inv_items", {
        blob = table.concat(rows, "\n"),
        vu   = db.vaultUsed,
        vc   = db.vaultCap,
        hv   = db.haveVault and 1 or 0,
        hk   = db.haveKey and 1 or 0,
    })
end

local function load_db()
    local saved = loadTable("aw_inv_items")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end

    db.vaultUsed = num_or(tostring(saved.vu or ""), 0)
    db.vaultCap  = num_or(tostring(saved.vc or ""), 0)
    db.haveVault = num_or(tostring(saved.hv or ""), 0) == 1
    db.haveKey   = num_or(tostring(saved.hk or ""), 0) == 1

    local rest = saved.blob
    local guard = 0
    while rest ~= "" and guard < 5000 do
        guard = guard + 1
        local line = rest
        local p = string.find(rest, "\n", 1, true)
        if p == nil then
            rest = ""
        else
            line = string.sub(rest, 1, p - 1)
            rest = string.sub(rest, p + 1)
        end

        local f = {}
        local rest2 = line
        local g2 = 0
        while g2 < 12 do
            g2 = g2 + 1
            local q = string.find(rest2, "\t", 1, true)
            if q == nil then
                table.insert(f, rest2)
                rest2 = ""
                g2 = 12
            else
                table.insert(f, string.sub(rest2, 1, q - 1))
                rest2 = string.sub(rest2, q + 1)
            end
        end

        if #f >= 9 and trim(f[1]) ~= "" then
            db.items[trim(f[1])] = {
                serial = trim(f[1]),
                flags  = trim(f[2]),
                level  = num_or(f[3], 0),
                itype  = num_or(f[4], 0),
                unique = num_or(f[5], 0),
                wear   = num_or(f[6], -1),
                timer  = num_or(f[7], -1),
                where  = trim(f[8]),
                name   = f[9],
            }
        end
    end
end

local function save_cfg()
    saveTable("aw_inv_cfg", {
        gag = cfg.gag, auto = cfg.auto, serials = cfg.serials,
        fpx = cfg.fpx, fov = cfg.fov,
    })
end

---
-- paint
---

local CSS_HEAD = [==[
<style>
    .arc-i {
        font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 10px;   /* overridden inline on the root div */
        color: hsl(var(--foreground, 35 34% 78%));
        height: 100%; box-sizing: border-box;
        display: flex; flex-direction: column;
        background:
            radial-gradient(120% 110% at 15% -10%, rgba(147,25,24,0.13), transparent 60%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }
    .arc-i .bar {
        display: flex; align-items: center; gap: 5px;
        padding: 6px 9px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-i .ttl {
        font-size: 0.8em; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        white-space: nowrap;
    }
    .arc-i .sub {
        font-size: 0.85em;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-i .sp { flex: 1; }
    .arc-i .tb {
        font-size: 0.75em; letter-spacing: 0.13em; text-transform: uppercase;
        padding: 3px 7px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; user-select: none; white-space: nowrap;
    }
    .arc-i .tb:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-i .tb.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.12);
    }
    .arc-i .body {
        flex: 1; min-height: 0;
        overflow: auto;
        padding: 7px 9px 9px;
    }
    .arc-i form { margin: 0; }
    .arc-i input[type=text] {
        width: 100%; box-sizing: border-box;
        background: hsl(var(--card, 0 12% 8%));
        color: hsl(var(--foreground, 35 34% 78%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 2px;
        font: inherit; font-size: 0.9em;
        padding: 4px 6px; margin-bottom: 7px;
    }
    .arc-i .sec {
        font-size: 0.75em; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 8px 0 4px; padding-bottom: 3px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-i .sec:first-child { margin-top: 0; }
    .arc-i .row {
        display: flex; gap: 6px; align-items: baseline;
        padding: 1px 0; line-height: 1.4;
        white-space: nowrap;
    }
    .arc-i .row .nm { overflow: hidden; text-overflow: ellipsis; }
    .arc-i .row .ct { color: hsl(var(--muted-foreground, 35 14% 52%)); }
    .arc-i .row .lv { color: hsl(var(--muted-foreground, 35 14% 52%)); margin-left: auto; }
    .arc-i .row .sn { color: hsl(var(--muted-foreground, 35 14% 52%)); font-size: 0.85em; }
    .arc-i .fl { font-size: 0.8em; letter-spacing: 0.05em; }
    .arc-i .fK { color: #e05c5c; } .arc-i .fR { color: #e05c5c; }
    .arc-i .fM { color: #6fa8dc; } .arc-i .fB { color: #76c7c0; }
    .arc-i .fG { color: #f1e2b8; } .arc-i .fH { color: #9ad1ea; }
    .arc-i .fI { color: #8a8a8a; } .arc-i .fC { color: #a06cd5; }
    .arc-i .fT { color: #e0a95c; } .arc-i .fE { color: #7bc47b; }
    .arc-i .fW { color: #777777; }
    .arc-i .note {
        font-size: 0.85em; line-height: 1.55; margin-top: 7px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-i .empty {
        font-size: 1em; text-align: center; padding: 18px 0;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
</style>
]==]

local function match_filter(it)
    if filter == "" then return true end
    local q = string.lower(filter)
    if string.find(string.lower(it.name), q, 1, true) ~= nil then return true end
    local tn = TYPE_NAME[it.itype]
    if type(tn) == "string"
        and string.find(string.lower(tn), q, 1, true) ~= nil then return true end
    if string.find(it.serial, q, 1, true) ~= nil then return true end
    return false
end

local function flags_html(flags)
    if flags == "" then return "" end
    local out = ""
    local i = 1
    while i <= #flags and i <= 14 do
        local ch = string.sub(flags, i, i)
        local cls = FLAG_CLASS[ch]
        if type(cls) == "string" then
            out = out .. '<span class="' .. cls .. '">' .. ch .. "</span>"
        else
            out = out .. esc(ch)
        end
        i = i + 1
    end
    return '<span class="fl">(' .. out .. ')</span> '
end

--[[
    Rows for one location, identical items grouped: same name, level and
    flags collapse to a count and up to three serials. Groups render in
    first-seen order; a fresh capture files items in MUD order, so the panel
    reads like the game does.
]]
local function section_rows(where, out, budget)
    local groups = {}
    local order  = {}

    for _, it in pairs(db.items) do
        if type(it) == "table" and it.where == where and match_filter(it) then
            local key = it.name .. "\1" .. it.level .. "\1" .. it.flags
            if type(groups[key]) ~= "table" then
                groups[key] = { it = it, n = 0, serials = "" , extra = false }
                table.insert(order, key)
            end
            local g = groups[key]
            g.n = g.n + 1
            if g.n <= 3 then
                g.serials = g.serials .. (g.serials ~= "" and "," or "") .. it.serial
            else
                g.extra = true
            end
        end
    end

    local shown = 0
    for _, key in ipairs(order) do
        if budget - shown <= 0 then return shown end
        local g  = groups[key]
        local it = g.it
        local count = (g.n > 1) and ('<span class="ct">(' .. g.n .. ")</span>") or ""
        local ser = ""
        if cfg.serials then
            ser = ' <span class="sn">[' .. g.serials .. (g.extra and ",&#8230;" or "") .. "]</span>"
        end
        table.insert(out, '<div class="row">' .. count
            .. '<span class="nm">' .. flags_html(it.flags) .. esc(it.name) .. ser .. "</span>"
            .. '<span class="lv">' .. it.level .. "</span></div>")
        shown = shown + 1
    end
    return shown
end

local function count_where(prefix)
    local n = 0
    for _, it in pairs(db.items) do
        if type(it) == "table" then
            if it.where == prefix
                or (string.find(it.where, prefix, 1, true) == 1 and prefix == "c:") then
                n = n + 1
            end
        end
    end
    return n
end

local function container_list()
    local out = {}
    for _, it in pairs(db.items) do
        if type(it) == "table" and it.itype == 11 and it.where == "inv" then
            table.insert(out, it)
        end
    end
    return out
end

local function render()
    if widget == nil then return end

    local body = ""

    if view == "settings" then
        body = '<div class="sec">Capture</div>'
            .. '<div class="bar" style="padding:0;border:0">'
            .. '<div class="tb' .. (cfg.gag and " on" or "") .. '" data-mud-action="gag">gag data</div>'
            .. '<div class="tb' .. (cfg.auto and " on" or "") .. '" data-mud-action="auto">auto refresh</div>'
            .. '<div class="tb' .. (cfg.serials and " on" or "") .. '" data-mud-action="serials">serials</div>'
            .. "</div>"
            .. '<div class="note"><b>gag data</b> keeps the raw CSV of blocks this '
            .. "panel requests out of the terminal. <b>auto refresh</b> follows "
            .. "{invmon} activity — looting, wearing, dropping — with one debounced "
            .. "rescan. <b>serials</b> shows each item's object id, the number "
            .. "Aardwolf's data commands key on. Vault data needs a vault in the "
            .. "room; <code>/awinv vault</code> asks for it.</div>"
    else
        local out = {}

        -- form submits carry every named field in formData; that is how typed
        -- text reaches a plugin without JavaScript
        table.insert(out, '<form><input type="text" name="q" value="'
            .. esc(filter)
            .. '" placeholder="filter &#8212; name, type or serial; empty clears">'
            .. "</form>")

        local left = MAX_ROWS

        table.insert(out, '<div class="sec">Worn &#8212; ' .. count_where("eq") .. "</div>")
        left = left - section_rows("eq", out, left)

        table.insert(out, '<div class="sec">Inventory &#8212; ' .. count_where("inv") .. "</div>")
        left = left - section_rows("inv", out, left)

        for _, con in ipairs(container_list()) do
            local key = "c:" .. con.serial
            table.insert(out, '<div class="sec">' .. esc(con.name)
                .. " &#8212; " .. count_where(key) .. "</div>")
            left = left - section_rows(key, out, left)
        end

        if db.haveKey then
            table.insert(out, '<div class="sec">Keyring &#8212; ' .. count_where("key") .. "</div>")
            left = left - section_rows("key", out, left)
        end

        if db.haveVault then
            table.insert(out, '<div class="sec">Vault &#8212; ' .. db.vaultUsed
                .. " / " .. db.vaultCap .. "</div>")
            left = left - section_rows("vault", out, left)
        end

        if left <= 0 then
            table.insert(out, '<div class="note">Trimmed at ' .. MAX_ROWS
                .. " rows &#8212; narrow the filter.</div>")
        end

        if count_where("eq") + count_where("inv") == 0 then
            table.insert(out, '<div class="empty">Nothing indexed yet &#8212; '
                .. "<code>/awinv refresh</code>.</div>")
        end

        body = table.concat(out, "\n")
    end

    local bar = '<span class="ttl">Inventory</span>'
        .. '<span class="sub">' .. count_where("inv") .. " carried</span>"
        .. '<span class="sp"></span>'
        .. '<div class="tb" data-mud-action="refresh" title="rescan eq, inventory, containers and keyring">refresh</div>'
        .. '<div class="tb" data-mud-action="close" title="put the panel away">hide</div>'
        .. '<div class="tb' .. (view ~= "list" and " on" or "")
        .. '" data-mud-action="view" title="settings">'
        .. (view ~= "list" and "&#9664; back" or "&#9881;") .. "</div>"

    setWidgetProperty(widget, "content", CSS_HEAD
        .. '<div class="arc-i" style="font-size:' .. font_base() .. 'px">'
        .. '<div class="bar">' .. bar .. "</div>"
        .. '<div class="body">' .. body .. "</div></div>")
end

---
-- capture engine
---

local function block_release()
    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer); st.blockTimer = nil end
    st.inBlock = ""
    st.inId    = ""
    st.mine    = false
    st.buf     = {}
    if rowTrig ~= nil then pcall(disableTrigger, rowTrig) end
end

local function send_next_scan()
    if #st.conQueue == 0 then return end
    local con = table.remove(st.conQueue, 1)
    table.insert(st.expect, { kind = "c", id = con, got = false })
    send("invdata " .. con)
end

--[[
    Match an arriving opener to the oldest expectation of a compatible kind.
    invdata answers both "inv" and "c" expectations — the queue order says
    which this one is. An opener nothing asked for is the user's own typing:
    parsed all the same, never gagged.
]]
local function take_expected(tagname)
    local want1 = tagname          -- eqdata->eq etc. mapped by caller
    local idx = 0
    for i, e in ipairs(st.expect) do
        if idx == 0 and type(e) == "table" and e.got == false then
            if e.kind == want1 or (want1 == "inv" and e.kind == "c") then
                idx = i
            end
        end
    end
    if idx == 0 then return nil end
    local e = st.expect[idx]
    e.got = true
    table.remove(st.expect, idx)
    return e
end

local function on_open(c, line, w)
    local base = (type(c[0]) == "string") and 0 or 1
    local tagname = tostring(c[base] or "")
    local kind = ""
    if tagname == "eqdata" then kind = "eq" end
    if tagname == "invdata" then kind = "inv" end
    if tagname == "keyring" then kind = "key" end
    if tagname == "vault" then kind = "vault" end
    if kind == "" then return end

    local e = take_expected(kind)

    st.inBlock = kind
    st.inId    = ""
    st.mine    = (e ~= nil)
    st.buf     = {}

    if type(e) == "table" and e.kind == "c" then
        st.inBlock = "c"
        st.inId    = e.id
    end

    -- refile: this block replaces that location's contents
    if st.inBlock == "c" then
        clear_where("c:" .. st.inId)
    else
        clear_where(st.inBlock)
    end
    if st.inBlock == "key" then db.haveKey = true end
    if st.inBlock == "vault" then db.haveVault = true end

    if rowTrig ~= nil then pcall(enableTrigger, rowTrig) end

    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer) end
    st.blockTimer = addTimer(BLOCK_MS, function()
        if st.inBlock ~= "" then
            utilprint(TAGR .. "{" .. tagname .. "} never closed; released.")
            block_release()
            render()
        end
    end)

    if st.mine and cfg.gag then return false end
end

local function on_close(c, line, w)
    if st.inBlock == "" then return end

    local wasMine = st.mine
    local wasInv  = (st.inBlock == "inv")
    block_release()

    -- the main inventory names the containers; scan them one at a time
    if wasInv and wasMine then
        st.conQueue = {}
        for _, con in ipairs(container_list()) do
            table.insert(st.conQueue, con.serial)
        end
        send_next_scan()
    elseif wasMine then
        send_next_scan()
    end

    save_db()
    render()

    if wasMine and cfg.gag then return false end
end

local function on_row(c, line, w, raw)
    if st.inBlock == "" then return end

    local plain = trim(tostring(line or ""))
    if plain == "" then return end

    -- {invitem}payload is a row wearing a wrapper; any other marker is not a row
    if string.sub(plain, 1, 9) == "{invitem}" then
        plain = string.sub(plain, 10)
    elseif string.sub(plain, 1, 1) == "{" then
        return
    end

    local where = st.inBlock
    if where == "c" then where = "c:" .. st.inId end
    parse_row(plain, where)

    if st.mine and cfg.gag then return false end
end

local function on_vaultcounts(c, line, w)
    local base = (type(c[0]) == "string") and 0 or 1
    db.vaultUsed = num_or(tostring(c[base] or ""), 0)
    db.vaultCap  = num_or(tostring(c[base + 2] or ""), 0)
    db.haveVault = true
    render()
    if cfg.gag then return false end
end

-- keyring and vault answer sleep with a dream; drop the expectation
local function on_dream(c, line, w)
    local keep = {}
    for _, e in ipairs(st.expect) do
        if type(e) == "table" and e.kind ~= "key" and e.kind ~= "vault" then
            table.insert(keep, e)
        end
    end
    st.expect = keep
end

local function refresh(withVault)
    st.expect   = {}
    st.conQueue = {}
    block_release()

    table.insert(st.expect, { kind = "eq", id = "", got = false })
    send("eqdata")
    table.insert(st.expect, { kind = "inv", id = "", got = false })
    send("invdata")
    table.insert(st.expect, { kind = "key", id = "", got = false })
    send("keyring data")

    if withVault == true then
        table.insert(st.expect, { kind = "vault", id = "", got = false })
        send("vault data")
    end
end

--[[
    {invmon} says the inventory changed. One debounced refresh follows the
    burst rather than a rescan per item; a floor keeps a long fight from
    turning into a rescan every debounce. The clock is a counter of debounce
    windows, not wall time — coarse is fine for a floor.
]]
local function on_invmon(c, line, w)
    if cfg.auto ~= true then return end

    st.clockMs = st.clockMs + DEBOUNCE_MS
    if st.pokeTimer ~= nil then pcall(removeTimer, st.pokeTimer) end
    st.pokeTimer = addTimer(DEBOUNCE_MS, function()
        st.pokeTimer = nil
        if st.clockMs - st.lastAuto >= MIN_AUTO_MS then
            st.lastAuto = st.clockMs
            refresh(false)
        end
    end)
end

---
-- setup
---

function init()
    broadcastPlugin("aw-gmcp", "Char")

    widget = createWidget({
        type     = "html",
        name     = "inv",
        title    = "Inventory",
        position = { x = 180, y = 120 },
        size     = { width = 460, height = 520 },
        visible  = false,
        appearance = {
            showTitleBar        = false,
            autoHideSettingsCog = true,
            zIndex              = 9999,
        },
    })

    local saved = loadTable("aw_inv_cfg")
    if type(saved) == "table" then
        if saved.gag == false then cfg.gag = false end
        if saved.auto == false then cfg.auto = false end
        if saved.serials == false then cfg.serials = false end
        local fp = tonumber(saved.fpx)
        if fp ~= nil and fp >= 6 and fp <= 48 then cfg.fpx = math.floor(fp) end
        fp = tonumber(saved.fov)
        if fp ~= nil and fp >= 6 and fp <= 48 then cfg.fov = math.floor(fp) end
    end

    load_db()

    onPluginBroadcast(function(senderId, message, data)
        if tostring(message or "") ~= "aw-font" then return end
        local px = tonumber(data)
        px = (px ~= nil and px >= 6 and px <= 48) and math.floor(px) or 0
        if px == cfg.fpx then return end
        cfg.fpx = px
        save_cfg()
        render()
    end)

    --[[
        Registered once, enabled only inside a block. A trigger created when
        the block starts would not see the rest of the packet it started in,
        and these blocks arrive whole.
    ]]
    rowTrig = addTrigger("*", on_row, {
        type           = "wildcard",
        priority       = 40,
        keepEvaluating = true,
        enabled        = false,
    })

    addTrigger("^\\{(invdata|eqdata|keyring|vault)( [0-9]+)?\\}", on_open,
        { type = "regex", priority = 70, keepEvaluating = true })
    addTrigger("^\\{/(invdata|eqdata|keyring|vault)\\}", on_close,
        { type = "regex", priority = 70, keepEvaluating = true })
    addTrigger("^\\{vaultcounts\\}([0-9]+),([0-9]+),([0-9]+)", on_vaultcounts,
        { type = "regex", priority = 70, keepEvaluating = true })
    addTrigger("^\\{invmon\\}", on_invmon,
        { type = "regex", priority = 40, keepEvaluating = true })
    addTrigger("^You dream about (being able to keyring|checking your vault)\\.$",
        on_dream, { type = "regex", priority = 40, keepEvaluating = true })

    drop_handlers(widget, "action")
    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end
        local action = tostring(data.action or "")

        if action == "close" then
            hideWidget(widget)
            return
        elseif action == "view" then
            view = (view ~= "list") and "list" or "settings"
        elseif action == "refresh" then
            refresh(false)
        elseif action == "gag" then
            cfg.gag = not cfg.gag
            save_cfg()
        elseif action == "auto" then
            cfg.auto = not cfg.auto
            save_cfg()
        elseif action == "serials" then
            cfg.serials = not cfg.serials
            save_cfg()
        end
        render()
    end)

    drop_handlers(widget, "submit")
    registerWidgetEvent(widget, "submit", function(data)
        if type(data) ~= "table" then return end
        local fd = data.formData
        if type(fd) ~= "table" then return end
        filter = trim(tostring(fd.q or ""))
        render()
    end)

    render()

    --[[
        NOT "inv" and not "inventory" — registerCommand eats the MUD's own
        command of the same name, and both belong to the game.
    ]]
    registerCommand("awinv", function(args)
        local a = args
        if type(a) == "table" then a = table.concat(a, " ") end
        a = trim(tostring(a or ""))
        local low = string.lower(a)

        if low == "" or low == "show" then
            showWidget(widget)
            render()

        elseif low == "hide" then
            hideWidget(widget)

        elseif low == "refresh" then
            refresh(false)
            utilprint(TAG .. "rescanning eq, inventory, containers and keyring...")
            showWidget(widget)

        elseif low == "vault" then
            refresh(true)
            utilprint(TAG .. "rescanning, vault included (needs a vault in the room)...")
            showWidget(widget)

        elseif low == "gag" or low == "auto" or low == "serials" then
            cfg[low] = not cfg[low]
            save_cfg()
            render()
            utilprint(TAG .. low .. (cfg[low] and " on." or " off."))

        elseif low == "clear" then
            db.items = {}
            db.haveKey = false
            db.haveVault = false
            save_db()
            render()
            utilprint(TAG .. "table cleared.")

        elseif string.sub(low, 1, 6) == "search" then
            filter = trim(string.sub(a, 7))
            showWidget(widget)
            render()

        elseif string.sub(low, 1, 4) == "font" then
            local how = trim(string.sub(low, 5))
            local n = tonumber(how)
            if how == "auto" or how == "off" then
                cfg.fov = 0
            elseif how ~= "" and n ~= nil and n >= 6 and n <= 48 then
                cfg.fov = math.floor(n)
            else
                utilprint(TAG .. "usage: /awinv font <6-48> | auto")
                return
            end
            save_cfg()
            render()
            utilprint(TAG .. "font "
                .. (cfg.fov >= 6 and (cfg.fov .. "px for this panel.")
                    or "follows the suite (/awcore font)."))

        else
            utilprint(TAG .. "inventory, worn, keyring and vault in one panel.")
            utilprint("$w  /awinv                     show the panel")
            utilprint("$w  /awinv hide                put it away")
            utilprint("$w  /awinv refresh             rescan eq, inv, containers, keyring")
            utilprint("$w  /awinv vault               rescan with the vault too")
            utilprint("$w  /awinv search <text>       filter the panel")
            utilprint("$w  /awinv serials             show object ids on rows")
            utilprint("$w  /awinv gag                 hide the raw data blocks")
            utilprint("$w  /awinv auto                follow {invmon} with auto rescans")
            utilprint("$w  /awinv font <px>|auto      this panel's text size")
            utilprint("$w  /awinv clear               forget everything indexed")
            local nInv = count_where("inv")
            local nEq  = count_where("eq")
            utilprint(TAG .. "state: " .. nEq .. " worn, " .. nInv .. " carried, "
                .. (cfg.auto and "auto" or "manual") .. " refresh.")
        end
    end, "inventory, worn, keyring and vault in one searchable panel")
end

function cleanup()
    if rowTrig ~= nil then pcall(removeTrigger, rowTrig); rowTrig = nil end
    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer); st.blockTimer = nil end
    if st.pokeTimer ~= nil then pcall(removeTimer, st.pokeTimer); st.pokeTimer = nil end
end
