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

    On top of the item table sit the ported dinv features:

    - An identify engine. 'id <serial>' works on anything carried (aw-loot
      sends the same), and the boxed report it prints is parsed with the
      same field walk aw-loot ships — Keywords opens the box, rows start
      with | or +, the first line that is neither closes it. Records are
      keyed by the serial that was asked about, one outstanding id at a
      time, paced so a full 'id missing' doesn't flood the MUD.

    - Priorities and scoring, dinv's inv.priority/inv.score. A profile is a
      flat stat -> weight table; an item's score is the weighted sum of its
      identified mods. 'best' picks the top scorer per wear location at or
      under a level, which is dinv's analyze reduced to the question it was
      actually asked: what should I be wearing?

    - The QoL modules: consumables and portals grouped from the item table
      (every object command on Aardwolf accepts a serial), and dinv's regen
      ring — the 'sleep' command is intercepted, the ring worn, sleep
      forwarded, and whatever the ring displaced (read off the {invmon}
      Removed event that follows) is re-worn on waking.

    Backups serialise both stores through savePluginFile, dinv's
    backup/restore with the machinery MudForge already provides.
]]

plugin = {
    id          = "aw-inv",
    name        = "Aardwolf Inventory",
    version     = "2.0.5",
    author      = "Catdad",
    description = "Searchable inventory with identify database, gear scoring, best-in-slot, consumables, portals and a regen ring.",
    settings    = { saveState = true },
}

-- @category widgets

-- utilprint on this client already prefixes output with the plugin's
-- display name, so the tag is just colour, not a second nameplate
local TAG  = "$w"
local TAGR = "$R! $w"

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
    -- lifetime counters, so /awinv debug can say which stage went quiet
    nSent = 0, nOpen = 0, nClose = 0, nRow = 0, nParsed = 0,
}

local widget  = nil
local view    = "list"   -- list | best | use | settings | item:<serial>
local filter  = ""
local rowTrig = nil

-- assigned below, forward-declared because the identify engine and the
-- invmon path repaint and are defined first (see MUDFORGE-NOTES on forward
-- declarations binding the global when they sit below their callers)
local render = nil

--[[
    Identify database and engine state. stats[serial] is a flat record of
    what the id box said; q is the line of serials waiting their turn;
    pending is the serial the next box belongs to. rec is the record being
    assembled while a box is open — table while open, nil otherwise, always
    tested with type().
]]
local ids = {
    stats    = {},
    q        = {},
    pending  = "",
    rec      = nil,
    modBlock = "",
    timer    = nil,     -- pacing between ids
    guard    = nil,     -- an id that never answers
    ran      = 0,       -- ids completed this run, for the done message
    trigs    = {},      -- the three box triggers, enabled only while an id is out
}

-- identify-box labels worth keeping, box text -> record key
local ID_FIELDS = {
    ["Keywords"]    = "keywords",
    ["Type"]        = "itype",
    ["Worth"]       = "worth",
    ["Weight"]      = "weight",
    ["Level"]       = "level",
    ["Score"]       = "score",
    ["Wearable"]    = "wearable",
    ["Material"]    = "material",
    ["Flags"]       = "flags",
    ["Found at"]    = "found_at",
    ["Leads to"]    = "leads_to",
    ["Weapon Type"] = "weapon_type",
    ["Average Dam"] = "ave_dam",
    ["Inflicts"]    = "inflicts",
    ["Damage Type"] = "dam_type",
    ["Capacity"]    = "capacity",
}

-- "Label : +N" stat and resist mods, box text -> stat key
local STAT_MAP = {
    ["Strength"] = "str", ["Intelligence"] = "intel", ["Wisdom"] = "wis",
    ["Dexterity"] = "dex", ["Constitution"] = "con", ["Luck"] = "luck",
    ["Hit points"] = "hp", ["Mana"] = "mana", ["Moves"] = "moves",
    ["Hit roll"] = "hit", ["Damage roll"] = "dam",
    ["All physical"] = "all_phys", ["All magic"] = "all_magic",
    ["Acid"] = "acid", ["Air"] = "air", ["Bash"] = "bash", ["Cold"] = "cold",
    ["Disease"] = "disease", ["Earth"] = "earth", ["Electric"] = "electric",
    ["Energy"] = "energy", ["Fire"] = "fire", ["Holy"] = "holy",
    ["Light"] = "light", ["Magic"] = "magic", ["Mental"] = "mental",
    ["Negative"] = "negative", ["Pierce"] = "pierce", ["Poison"] = "poison",
    ["Shadow"] = "shadow", ["Slash"] = "slash", ["Sonic"] = "sonic",
    ["Water"] = "water",
}

--[[
    Wear locations and how many of each a body has. Keys are the words the
    box's Wearable field uses. Anything it says that isn't here still gets
    a slot of its own, capacity one — guessing wrong costs a row, not data.
]]
local SLOT_CAP = {
    light = 1, finger = 2, neck = 2, body = 1, head = 1, legs = 1, feet = 1,
    hands = 1, arms = 1, shield = 1, about = 1, waist = 1, wrist = 2,
    wield = 1, hold = 1, float = 1, ear = 2, eyes = 1, back = 1,
    medal = 1, sleeves = 1, ankle = 2,
}

--[[
    Scoring profiles, dinv's priorities. weights is "name;stat=w,stat=w;..."
    flat in storage; live it is sets[name][stat] = weight. The defaults are
    starting points, not doctrine — edit with /awinv prio.
]]
local prof = {
    active = "damage",
    sets = {
        damage   = { dam = 10, hit = 5, str = 2, dex = 1 },
        caster   = { intel = 5, wis = 4, mana = 3, luck = 1, hp = 1 },
        tank     = { con = 5, hp = 4, all_phys = 3, all_magic = 3 },
        balanced = { str = 1, intel = 1, wis = 1, dex = 1, con = 1, luck = 1,
                     hp = 2, mana = 2, hit = 2, dam = 2 },
    },
}

--[[
    QoL state. regen is the ring's serial or "". While a sleep is in
    flight, watchWear is true and the first {invmon} Removed event names
    the item the ring displaced; that is what gets re-worn on waking.
]]
local qol = {
    regen     = "",
    regenPrev = "",
    watchWear = false,
    watchTimer = nil,
}

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

--[[
    The panel's base font as a CSS length. A pinned size (/awinv font, or
    the suite's /awcore font) is exact pixels; auto scales with the panel
    itself — the iframe's viewport IS the widget, so vmin units track its
    size live as it is resized, with a clamp so a tiny or huge panel stays
    readable. Inline font-size is geometry to the sanitiser and survives.
]]
local function font_base()
    if cfg.fov >= 6 and cfg.fov <= 48 then return cfg.fov .. "px" end
    if cfg.fpx >= 6 and cfg.fpx <= 48 then return cfg.fpx .. "px" end
    -- floor of 14 by request; still grows with the panel past that
    return "clamp(14px, 2.6vmin, 22px)"
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

-- box numbers carry commas; strip before converting
local function numc(s)
    s = string.gsub(tostring(s or ""), ",", "")
    return num_or(s, 0)
end

local function stamp()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then return t end
    return 0
end

--[[
    A field off a GMCP table. pairs() can see a key that dot access cannot
    reach on this client, so walk and compare as text (MUDFORGE-NOTES 13c).
]]
local function gfield(t, name)
    if type(t) ~= "table" then return nil end
    if t[name] ~= nil then return t[name] end
    for k, v in pairs(t) do
        if tostring(k) == name then return v end
    end
    return nil
end

local function char_level()
    local n = tonumber(gfield(getGMCPData("char.status"), "level"))
    if n == nil or n < 1 then return 201 end
    return math.floor(n)
end

--[[
    Split a box row on runs of two-plus spaces — column padding — keeping
    single spaces inside values. Walked by slicing; find's init argument
    does not advance here.
]]
local function split_cols(s)
    local out  = {}
    local rest = tostring(s or "")
    local guard = 0
    while guard < 60 do
        guard = guard + 1
        local p = string.find(rest, "  ", 1, true)
        if p == nil then
            if trim(rest) ~= "" then table.insert(out, trim(rest)) end
            return out
        end
        local head = string.sub(rest, 1, p - 1)
        if trim(head) ~= "" then table.insert(out, trim(head)) end
        -- skip the whole run of spaces, one at a time, haystack shrinking
        rest = string.sub(rest, p + 1)
        local g2 = 0
        while g2 < 200 and string.sub(rest, 1, 1) == " " do
            g2 = g2 + 1
            rest = string.sub(rest, 2)
        end
    end
    return out
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
    st.nParsed = st.nParsed + 1
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
-- identify store: serial -> flat record, persisted like the item table as
-- one string — "serial \t key=value \t key=value" per line. Values never
-- contain tabs or newlines; the box is fixed-width text.
---

local function save_stats()
    local rows = {}
    for serial, r in pairs(ids.stats) do
        if type(r) == "table" then
            local parts = { tostring(serial) }
            for k, v in pairs(r) do
                local vs = string.gsub(tostring(v), "\t", " ")
                vs = string.gsub(vs, "\n", " ")
                table.insert(parts, tostring(k) .. "=" .. vs)
            end
            table.insert(rows, table.concat(parts, "\t"))
        end
    end
    saveTable("aw_inv_stats", { blob = table.concat(rows, "\n") })
end

local function load_stats()
    local saved = loadTable("aw_inv_stats")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end

    local rest = saved.blob
    local guard = 0
    while rest ~= "" and guard < 8000 do
        guard = guard + 1
        local line = rest
        local p = string.find(rest, "\n", 1, true)
        if p == nil then
            rest = ""
        else
            line = string.sub(rest, 1, p - 1)
            rest = string.sub(rest, p + 1)
        end

        local serial = ""
        local r = {}
        local rest2 = line
        local g2 = 0
        while rest2 ~= "" and g2 < 80 do
            g2 = g2 + 1
            local field = rest2
            local q = string.find(rest2, "\t", 1, true)
            if q == nil then
                rest2 = ""
            else
                field = string.sub(rest2, 1, q - 1)
                rest2 = string.sub(rest2, q + 1)
            end

            if serial == "" then
                serial = trim(field)
            else
                local eq = string.find(field, "=", 1, true)
                if eq ~= nil and eq > 1 then
                    local k = string.sub(field, 1, eq - 1)
                    local v = string.sub(field, eq + 1)
                    local n = tonumber(v)
                    -- numbers come back numbers; "" stays "", JS tonumber("")
                    -- is 0 so gate on content first
                    if trim(v) ~= "" and n ~= nil then
                        r[k] = n
                    else
                        r[k] = v
                    end
                end
            end
        end

        if serial ~= "" and tonumber(serial) ~= nil then
            ids.stats[serial] = r
        end
    end
end

--[[
    Profiles flat: "active|name:stat=w,stat=w|name:..." — one string, same
    reasoning as every other store here.
]]
local function save_prof()
    local parts = { prof.active }
    for name, ws in pairs(prof.sets) do
        if type(ws) == "table" then
            local kv = {}
            for k, v in pairs(ws) do
                table.insert(kv, tostring(k) .. "=" .. tostring(v))
            end
            table.insert(parts, tostring(name) .. ":" .. table.concat(kv, ","))
        end
    end
    saveTable("aw_inv_prof", { blob = table.concat(parts, "|") })
end

local function load_prof()
    local saved = loadTable("aw_inv_prof")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end

    local first = true
    local rest = saved.blob
    local guard = 0
    while rest ~= "" and guard < 100 do
        guard = guard + 1
        local part = rest
        local p = string.find(rest, "|", 1, true)
        if p == nil then
            rest = ""
        else
            part = string.sub(rest, 1, p - 1)
            rest = string.sub(rest, p + 1)
        end

        if first then
            first = false
            if trim(part) ~= "" then prof.active = trim(part) end
        else
            local c = string.find(part, ":", 1, true)
            if c ~= nil and c > 1 then
                local name = string.sub(part, 1, c - 1)
                local ws = {}
                local rest2 = string.sub(part, c + 1)
                local g2 = 0
                while rest2 ~= "" and g2 < 80 do
                    g2 = g2 + 1
                    local kv = rest2
                    local q = string.find(rest2, ",", 1, true)
                    if q == nil then
                        rest2 = ""
                    else
                        kv = string.sub(rest2, 1, q - 1)
                        rest2 = string.sub(rest2, q + 1)
                    end
                    local eq = string.find(kv, "=", 1, true)
                    if eq ~= nil and eq > 1 then
                        local w = tonumber(string.sub(kv, eq + 1))
                        if w ~= nil then ws[string.sub(kv, 1, eq - 1)] = w end
                    end
                end
                prof.sets[name] = ws
            end
        end
    end

    if type(prof.sets[prof.active]) ~= "table" then prof.active = "damage" end
end

local function save_qol()
    saveTable("aw_inv_qol", { regen = qol.regen, regenPrev = qol.regenPrev })
end

local function load_qol()
    local saved = loadTable("aw_inv_qol")
    if type(saved) ~= "table" then return end
    if type(saved.regen) == "string" then qol.regen = saved.regen end
    if type(saved.regenPrev) == "string" then qol.regenPrev = saved.regenPrev end
end

---
-- identify engine
--
-- One serial in flight at a time. 'id <serial>' prints the boxed report;
-- Keywords opens it, | and + rows feed it, the first line that is neither
-- closes it. The record files under the serial that was asked about, so a
-- box the user summoned by hand (empty pending) is left to scroll past.
---

local function id_mods(text)
    -- the shipping aw-loot pattern, classes and all — measured working
    for label, sign, digits in string.gmatch(text, "([A-Za-z][A-Za-z ]-)%s*:%s*([%+%-])(%d+)") do
        local col = STAT_MAP[trim(label)]
        if col ~= nil and type(ids.rec) == "table" then
            ids.rec[col] = tonumber(sign .. digits)
        end
    end
end

local function id_line(body)
    if type(ids.rec) ~= "table" then return end

    -- the name row; strip the box's right border if it survived
    local nm = string.match(body, "^%s*Name%s+:%s*(.-)%s*|?%s*$")
    if nm ~= nil then
        ids.rec.item = trim(decode(trim(nm)))
        ids.modBlock = ""
        return
    end

    local mods = string.match(body, "^%s*Stat Mods%s*:(.*)$")
    if mods == nil then mods = string.match(body, "^%s*Resist Mods%s*:(.*)$") end
    if mods ~= nil then
        id_mods(mods)
        ids.modBlock = "stat"
        return
    end
    if ids.modBlock == "stat"
        and string.match(body, "^%s+[A-Za-z][A-Za-z ]-%s*:%s*[%+%-]%d") ~= nil then
        id_mods(body)
        return
    end

    local note = string.match(body, "^%s*Notes%s+:%s*(.-)%s*|?%s*$")
    if note ~= nil and note ~= "" then
        local old = (type(ids.rec.notes) == "string") and (ids.rec.notes .. "; ") or ""
        ids.rec.notes = old .. note
        ids.modBlock = ""
        return
    end

    local sp = string.match(body, "^%s*Spells%s+:%s*(.-)%s*|?%s*$")
    if sp ~= nil and sp ~= "" then
        local old = (type(ids.rec.spells) == "string") and (ids.rec.spells .. "; ") or ""
        ids.rec.spells = old .. sp
        ids.modBlock = ""
        return
    end

    -- plain "Label : value" pairs, two to a row, split on column padding
    for _, chunk in ipairs(split_cols(body)) do
        local c = string.find(chunk, ":", 1, true)
        if c ~= nil and c > 1 then
            local label = trim(string.sub(chunk, 1, c - 1))
            local value = trim(string.sub(chunk, c + 1))
            local key = ID_FIELDS[label]
            if key ~= nil and value ~= "" then
                if key == "level" or key == "worth" or key == "weight"
                    or key == "score" or key == "ave_dam" or key == "capacity" then
                    ids.rec[key] = numc(value)
                else
                    ids.rec[key] = decode(value)
                end
                ids.modBlock = ""
            end
        end
    end
end

local function id_guard_off()
    if ids.guard ~= nil then pcall(removeTimer, ids.guard); ids.guard = nil end
end

--[[
    The box triggers include one that matches every line ("first line that
    is neither | nor +"). They exist only to close a box we asked for, so
    they are switched on for the flight of one id and off again after —
    the rest of the session they never run at all.
]]
local function id_trigs(onoff)
    for _, h in ipairs(ids.trigs) do
        if onoff == true then
            pcall(enableTrigger, h)
        else
            pcall(disableTrigger, h)
        end
    end
end

-- forward-declared: id_store schedules the next send
local id_next = nil

local function id_store()
    local r = ids.rec
    ids.rec = nil
    ids.modBlock = ""
    id_guard_off()
    id_trigs(false)

    local serial = ids.pending
    ids.pending = ""

    if type(r) == "table" and serial ~= "" then
        r.at = stamp()
        -- keep what an older record had that this box didn't mention
        local old = ids.stats[serial]
        if type(old) == "table" then
            for k, v in pairs(old) do
                if r[k] == nil then r[k] = v end
            end
        end
        ids.stats[serial] = r
        ids.ran = ids.ran + 1
        save_stats()
    end

    if ids.timer ~= nil then pcall(removeTimer, ids.timer) end
    ids.timer = addTimer(700, function()
        ids.timer = nil
        if type(id_next) == "function" then id_next() end
    end)
end

id_next = function()
    if ids.pending ~= "" then return end
    if #ids.q == 0 then
        if ids.ran > 0 then
            utilprint(TAG .. ids.ran .. " item(s) identified and stored.")
            ids.ran = 0
            if render ~= nil then render() end
        end
        return
    end

    local serial = table.remove(ids.q, 1)
    -- the item may have left the inventory since it queued
    if type(db.items[serial]) ~= "table" then
        id_next()
        return
    end

    ids.pending = serial
    id_trigs(true)
    send("id " .. serial)

    id_guard_off()
    ids.guard = addTimer(8000, function()
        ids.guard = nil
        if ids.pending == serial and type(ids.rec) ~= "table" then
            utilprint(TAGR .. "no id box for " .. serial .. " - skipped.")
            ids.pending = ""
            id_trigs(false)
            id_next()
        end
    end)
end

local function id_queue(which)
    local added = 0
    for serial, it in pairs(db.items) do
        if type(it) == "table" and (it.where == "inv" or it.where == "eq"
            or string.find(it.where, "c:", 1, true) == 1) then
            local known = type(ids.stats[serial]) == "table"
            if which == "all" or (which == "missing" and not known) then
                table.insert(ids.q, serial)
                added = added + 1
            end
        end
    end
    return added
end

local function on_id_open(c, line, w)
    -- a box nobody asked for scrolls past untouched
    if ids.pending == "" then return end
    local base = (type(c[0]) == "string") and 0 or 1
    ids.rec = { keywords = trim(tostring(c[base] or "")), full = 1 }
    ids.modBlock = ""
end

local function on_id_row(c, line, w)
    if type(ids.rec) ~= "table" then return end
    local base = (type(c[0]) == "string") and 0 or 1
    id_line(tostring(c[base] or ""))
end

local function on_id_close(c, line, w)
    if type(ids.rec) ~= "table" then return end
    if string.find(tostring(line or ""), "full appraisal", 1, true) ~= nil then
        ids.rec.full = 0
    end
    id_store()
end

---
-- scoring, dinv's priority/score, and the best-per-slot answer
---

local function score_of(serial)
    local r = ids.stats[serial]
    if type(r) ~= "table" then return nil end
    local ws = prof.sets[prof.active]
    if type(ws) ~= "table" then return nil end

    local total = 0
    for stat, weight in pairs(ws) do
        local v = tonumber(r[stat])
        if v ~= nil then total = total + v * weight end
    end
    return total
end

-- the box says "Wearable : finger"; anything unlisted gets its own slot
local function slot_of(serial)
    local r = ids.stats[serial]
    if type(r) ~= "table" then return "" end
    local wearable = string.lower(trim(tostring(r.wearable or "")))
    if wearable == "" then return "" end
    -- first word: "wield (weapon)" and friends carry trailing commentary
    local p = string.find(wearable, " ", 1, true)
    if p ~= nil then wearable = string.sub(wearable, 1, p - 1) end
    return wearable
end

--[[
    Best identified item(s) per wear location at or under a level. A slot
    with capacity two lists two. Returns rows already sorted for render:
    { slot, serial, score, worn } — worn meaning currently on your body.
]]
local function best_set(level)
    local per = {}    -- slot -> array of {serial=..., sc=...}

    for serial, r in pairs(ids.stats) do
        if type(r) == "table" and type(db.items[serial]) == "table" then
            local slot = slot_of(serial)
            local lv = tonumber(r.level)
            if lv == nil then lv = 0 end
            if slot ~= "" and lv <= level then
                local sc = score_of(serial)
                if sc ~= nil and sc > 0 then
                    if type(per[slot]) ~= "table" then per[slot] = {} end
                    table.insert(per[slot], { serial = serial, sc = sc })
                end
            end
        end
    end

    local slots = {}
    for slot, list in pairs(per) do
        table.sort(list, function(x, y) return x.sc > y.sc end)
        table.insert(slots, slot)
    end
    table.sort(slots)

    local out = {}
    for _, slot in ipairs(slots) do
        local cap = SLOT_CAP[slot]
        if cap == nil then cap = 1 end
        local list = per[slot]
        local i = 1
        while i <= cap and i <= #list do
            local e = list[i]
            local it = db.items[e.serial]
            table.insert(out, {
                slot = slot, serial = e.serial, sc = e.sc,
                worn = (type(it) == "table" and it.where == "eq"),
            })
            i = i + 1
        end
    end
    return out
end

---
-- backup / restore, through savePluginFile like aw-loot's
---

local function bak_index()
    local t = loadTable("aw_inv_baks")
    if type(t) == "table" then return t end
    return {}
end

local function do_backup(name)
    save_db()
    save_stats()
    local itemsBlob = ""
    local statsBlob = ""
    local t = loadTable("aw_inv_items")
    if type(t) == "table" and type(t.blob) == "string" then itemsBlob = t.blob end
    t = loadTable("aw_inv_stats")
    if type(t) == "table" and type(t.blob) == "string" then statsBlob = t.blob end

    local file = "aw-inv-bak-" .. name .. ".json"
    local ok = savePluginFile(file, json.encode({
        items = itemsBlob, stats = statsBlob, at = stamp(),
    }))
    -- truthiness on purpose, matching aw-loot's test of the same call:
    -- false and nil are the failure shapes; anything else wrote
    if ok == false or ok == nil then return "" end

    local idx = bak_index()
    idx[name] = file
    saveTable("aw_inv_baks", idx)
    return file
end

local function do_restore(name)
    local idx = bak_index()
    local file = idx[name]
    if type(file) ~= "string" or file == "" then return false end

    local raw = loadPluginFile(file)
    if type(raw) ~= "string" or raw == "" then return false end

    local ok, data = pcall(json.decode, raw)
    if ok ~= true or type(data) ~= "table" then return false end
    if type(data.items) ~= "string" then return false end

    saveTable("aw_inv_items", { blob = data.items,
        vu = db.vaultUsed, vc = db.vaultCap,
        hv = db.haveVault and 1 or 0, hk = db.haveKey and 1 or 0 })
    saveTable("aw_inv_stats", { blob = tostring(data.stats or "") })

    db.items = {}
    ids.stats = {}
    load_db()
    load_stats()
    return true
end

---
-- paint
---

local CSS_HEAD = [==[
<style>
    .arc-i {
        font-family: "JetBrains Mono", "JetBrainsMono Nerd Font", "JetBrainsMono NF", ui-monospace, Consolas, monospace;
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
        local sc = score_of(it.serial)
        local scChip = (sc ~= nil and sc > 0)
            and (' <span class="sn">' .. sc .. "pt</span>") or ""
        table.insert(out, '<div class="row" data-mud-action="item" data-mud-data="'
            .. it.serial .. '">' .. count
            .. '<span class="nm">' .. flags_html(it.flags) .. esc(it.name) .. ser .. "</span>"
            .. '<span class="lv">' .. scChip .. " " .. it.level .. "</span></div>")
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

--[[
    The item detail view: what invdata knew plus what the id box added,
    with the active profile's score. The identify button re-asks.
]]
local function render_item(serial)
    local out = {}
    local it = db.items[serial]
    local r  = ids.stats[serial]

    if type(it) ~= "table" then
        table.insert(out, '<div class="empty">Item ' .. esc(serial)
            .. " is no longer indexed.</div>")
        return table.concat(out, "\n")
    end

    table.insert(out, '<div class="sec">' .. flags_html(it.flags)
        .. esc(it.name) .. "</div>")

    local tn = TYPE_NAME[it.itype]
    if type(tn) ~= "string" then tn = tostring(it.itype) end
    table.insert(out, '<div class="row"><span class="nm">serial ' .. esc(serial)
        .. " &#183; " .. esc(tn) .. " &#183; level " .. it.level
        .. " &#183; " .. esc(it.where) .. "</span></div>")

    if type(r) ~= "table" then
        table.insert(out, '<div class="note">Not identified yet.</div>')
    else
        local sc = score_of(serial)
        if sc ~= nil then
            table.insert(out, '<div class="row"><span class="nm">score <b>' .. sc
                .. "</b> under profile <b>" .. esc(prof.active) .. "</b></span></div>")
        end

        for _, k in ipairs({ "keywords", "wearable", "material", "worth",
                             "weight", "score", "weapon_type", "ave_dam",
                             "dam_type", "inflicts", "capacity", "leads_to",
                             "found_at", "flags" }) do
            local v = r[k]
            if v ~= nil and tostring(v) ~= "" then
                table.insert(out, '<div class="row"><span class="ct">' .. esc(k)
                    .. '</span><span class="nm">' .. esc(tostring(v)) .. "</span></div>")
            end
        end

        local mods = {}
        for label, statKey in pairs(STAT_MAP) do
            local v = tonumber(r[statKey])
            if v ~= nil and v ~= 0 then
                table.insert(mods, esc(label) .. " " .. (v > 0 and "+" or "") .. v)
            end
        end
        table.sort(mods)
        if #mods > 0 then
            table.insert(out, '<div class="sec">Mods</div><div class="note">'
                .. table.concat(mods, ", ") .. "</div>")
        end

        if type(r.spells) == "string" and r.spells ~= "" then
            table.insert(out, '<div class="sec">Spells</div><div class="note">'
                .. esc(r.spells) .. "</div>")
        end
        if type(r.notes) == "string" and r.notes ~= "" then
            table.insert(out, '<div class="sec">Notes</div><div class="note">'
                .. esc(r.notes) .. "</div>")
        end
    end

    table.insert(out, '<div class="bar" style="padding:6px 0 0;border:0">'
        .. '<div class="tb" data-mud-action="ident" data-mud-data="' .. esc(serial)
        .. '">identify</div>'
        .. '<div class="tb" data-mud-action="tab" data-mud-data="list">back</div></div>')

    return table.concat(out, "\n")
end

local function render_best()
    local out = {}
    local level = char_level()
    local rows = best_set(level)

    table.insert(out, '<div class="sec">Best identified item per slot &#8212; level '
        .. level .. ", profile " .. esc(prof.active) .. "</div>")

    if #rows == 0 then
        table.insert(out, '<div class="empty">Nothing scored yet &#8212; identify '
            .. "your gear: <code>/awinv id missing</code>.</div>")
    end

    for _, e in ipairs(rows) do
        local it = db.items[e.serial]
        local nm = (type(it) == "table") and it.name or e.serial
        table.insert(out, '<div class="row" data-mud-action="item" data-mud-data="'
            .. e.serial .. '">'
            .. '<span class="ct">' .. esc(e.slot) .. "</span>"
            .. '<span class="nm">' .. esc(nm)
            .. (e.worn and ' <span class="sn">(worn)</span>' or "") .. "</span>"
            .. '<span class="lv">' .. e.sc .. "pt</span></div>")
    end

    table.insert(out, '<div class="note">Scores are the active profile\'s weighted '
        .. "sums &#8212; <code>/awinv prio</code> to inspect or change weights.</div>")
    return table.concat(out, "\n")
end

--[[
    Consumables and portals. Aardwolf's object commands accept serials, so
    the buttons here go straight at the item: quaff/eat/recite by type,
    hold-and-enter for portals.
]]
local function render_use()
    local out = {}

    local groupsOf = function(types, title)
        local found = {}
        for _, it in pairs(db.items) do
            if type(it) == "table" and types[it.itype] == true
                and (it.where == "inv" or string.find(it.where, "c:", 1, true) == 1)
                and match_filter(it) then
                table.insert(found, it)
            end
        end
        table.sort(found, function(x, y) return x.name < y.name end)

        table.insert(out, '<div class="sec">' .. title .. " &#8212; " .. #found .. "</div>")
        local i = 1
        while i <= #found and i <= 120 do
            local it = found[i]
            table.insert(out, '<div class="row" data-mud-action="item" data-mud-data="'
                .. it.serial .. '">'
                .. '<span class="ct">' .. esc(string.lower(TYPE_NAME[it.itype] or "")) .. "</span>"
                .. '<span class="nm">' .. esc(it.name) .. "</span>"
                .. '<span class="lv">' .. it.level .. "</span></div>")
            i = i + 1
        end
    end

    groupsOf({ [8] = true, [19] = true, [2] = true, [14] = true },
        "Consumables (potion, pill, scroll, food)")
    groupsOf({ [20] = true, [15] = true }, "Portals and boats")

    table.insert(out, '<div class="note"><code>/awinv use &lt;serial&gt;</code> '
        .. "quaffs, eats or recites by type; <code>/awinv go &lt;serial&gt;</code> "
        .. "holds a portal and enters it. Regen ring: <code>/awinv regen "
        .. "&lt;serial&gt;</code> &#8212; worn on sleep, the displaced item "
        .. "re-worn on waking"
        .. (qol.regen ~= "" and (" (current: " .. esc(qol.regen) .. ")") or "")
        .. ".</div>")
    return table.concat(out, "\n")
end

render = function()
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
    elseif string.find(view, "item:", 1, true) == 1 then
        body = render_item(string.sub(view, 6))
    elseif view == "best" then
        body = render_best()
    elseif view == "use" then
        body = render_use()
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

    local tab = function(name, label)
        return '<div class="tb' .. (view == name and " on" or "")
            .. '" data-mud-action="tab" data-mud-data="' .. name .. '">'
            .. label .. "</div>"
    end

    local bar = '<span class="ttl">Inventory</span>'
        .. '<span class="sub">' .. count_where("inv") .. " carried</span>"
        .. '<span class="sp"></span>'
        .. tab("list", "items") .. tab("best", "best") .. tab("use", "use")
        .. '<div class="tb" data-mud-action="refresh" title="rescan eq, inventory, containers and keyring">refresh</div>'
        .. '<div class="tb" data-mud-action="close" title="put the panel away">hide</div>'
        .. '<div class="tb' .. (view == "settings" and " on" or "")
        .. '" data-mud-action="view" title="settings">&#9881;</div>'

    setWidgetProperty(widget, "content", CSS_HEAD
        .. '<div class="arc-i" style="font-size:' .. font_base() .. '">'
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

--[[
    One opener per tag, kind bound by closure rather than read from a
    capture. The first build used one trigger with a capturing alternation
    and a trailing optional group — and it never fired once against the
    live client, while every shipping plugin's triggers are plain patterns
    or (?:non-capturing) groups. Mirror what is measured to work.
]]
local function open_kind(kind, tagname)
    st.nOpen = st.nOpen + 1

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
    st.nClose = st.nClose + 1
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
    st.nRow = st.nRow + 1

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
    st.nSent = st.nSent + 3

    if withVault == true then
        table.insert(st.expect, { kind = "vault", id = "", got = false })
        send("vault data")
        st.nSent = st.nSent + 1
    end
end

--[[
    {invmon} says the inventory changed. One debounced refresh follows the
    burst rather than a rescan per item; a floor keeps a long fight from
    turning into a rescan every debounce. The clock is a counter of debounce
    windows, not wall time — coarse is fine for a floor.
]]
local function on_invmon(c, line, w)
    --[[
        {invmon}action,serial,container,wearloc. While a regen sleep is in
        flight, action 1 (Removed) names the item the ring displaced — dinv
        tracked the slot; the event is simpler and arrives anyway.
    ]]
    if qol.watchWear == true then
        local plain = tostring(line or "")
        local payload = ""
        local p = string.find(plain, "}", 1, true)
        if p ~= nil then payload = string.sub(plain, p + 1) end
        local f = csv_fields(trim(payload))
        if #f >= 2 and trim(f[1]) == "1" and trim(f[2]) ~= "" then
            qol.regenPrev = trim(f[2])
            qol.watchWear = false
            save_qol()
        end
    end

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

--[[
    Waking re-wears whatever the regen ring displaced. The ring stays where
    it is — 'wear' on the displaced item swaps them back, which is one send
    instead of remove-plus-wear.
]]
local function on_wake(c, line, w)
    if qol.regen == "" then return end
    if qol.regenPrev == "" then return end
    send("wear " .. qol.regenPrev)
    utilprint(TAG .. "re-wearing " .. qol.regenPrev .. " (regen ring off).")
    qol.regenPrev = ""
    qol.watchWear = false
    save_qol()
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
    load_stats()
    load_prof()
    load_qol()

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
    --[[
        Always enabled, gated on st.inBlock inside the handler — spellups'
        row reader runs the same way. Rows inside {invdata} are lines Core
        gags, and the enable/disable dance added nothing but another way
        to be wrong about when the trigger could see them.
    ]]
    rowTrig = addTrigger("*", on_row, {
        type           = "wildcard",
        keepEvaluating = true,
    })

    --[[
        keepEvaluating = true and NO explicit priority, copied from
        aw-spellup's spellheaders readers — the one shape measured to see
        lines Core is gagging. Two failed builds bracketed this: capturing
        alternation never matched at all, and a priority-70 trigger without
        keepEvaluating never saw a line the priority-90 gag had discarded.
    ]]
    addTrigger("^\\{eqdata\\}", function(c, l, w) return open_kind("eq", "eqdata") end,
        { type = "regex", keepEvaluating = true })
    addTrigger("^\\{invdata\\}", function(c, l, w) return open_kind("inv", "invdata") end,
        { type = "regex", keepEvaluating = true })
    addTrigger("^\\{keyring\\}", function(c, l, w) return open_kind("key", "keyring") end,
        { type = "regex", keepEvaluating = true })
    addTrigger("^\\{vault\\}", function(c, l, w) return open_kind("vault", "vault") end,
        { type = "regex", keepEvaluating = true })
    addTrigger("^\\{/(?:invdata|eqdata|keyring|vault)\\}", on_close,
        { type = "regex", keepEvaluating = true })
    addTrigger("^\\{vaultcounts\\}([0-9]+),([0-9]+),([0-9]+)", on_vaultcounts,
        { type = "regex", keepEvaluating = true })
    addTrigger("^\\{invmon\\}", on_invmon,
        { type = "regex", keepEvaluating = true })
    addTrigger("^You dream about (?:being able to keyring|checking your vault)\\.$",
        on_dream, { type = "regex", keepEvaluating = true })

    --[[
        The identify box, aw-loot's patterns: Keywords opens it, | and +
        rows feed it, the first line that is neither closes it. Registered
        disabled and switched on only while one of OUR ids is in flight —
        the close pattern matches every ordinary line, and a handler that
        runs on all of them all session long is exposure with no payoff.
    ]]
    ids.trigs = {}
    table.insert(ids.trigs, addTrigger("^\\| Keywords\\s+:\\s*(.+?)\\s*\\|$", on_id_open,
        { type = "regex", keepEvaluating = true, enabled = false }))
    table.insert(ids.trigs, addTrigger("^[|+](.*)$", on_id_row,
        { type = "regex", keepEvaluating = true, enabled = false }))
    table.insert(ids.trigs, addTrigger("^[^|+].*$", on_id_close,
        { type = "regex", keepEvaluating = true, enabled = false }))

    addTrigger("^You wake and stand up\\.$", on_wake,
        { type = "regex", keepEvaluating = true })

    drop_handlers(widget, "action")
    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end
        local action = tostring(data.action or "")

        if action == "close" then
            hideWidget(widget)
            return
        elseif action == "view" then
            view = (view ~= "settings") and "settings" or "list"
        elseif action == "tab" then
            view = tostring(data.data or "list")
            if view ~= "best" and view ~= "use" then view = "list" end
        elseif action == "item" then
            local serial = trim(tostring(data.data or ""))
            if serial ~= "" then view = "item:" .. serial end
        elseif action == "ident" then
            local serial = trim(tostring(data.data or ""))
            if serial ~= "" then
                table.insert(ids.q, serial)
                id_next()
            end
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
        dinv's regen ring. 'sleep' is intercepted — registerCommand eats the
        word, which is normally the trap and here is the tool (aw-loot's
        'inv' interception is the precedent): wear the ring, forward the
        sleep. The {invmon} Removed event that follows names the displaced
        item, and waking re-wears it. With no ring set, sleep passes through
        untouched.
    ]]
    registerCommand("sleep", function()
        if qol.regen ~= "" and type(db.items[qol.regen]) == "table" then
            qol.watchWear = true
            if qol.watchTimer ~= nil then pcall(removeTimer, qol.watchTimer) end
            qol.watchTimer = addTimer(4000, function()
                qol.watchTimer = nil
                qol.watchWear = false
            end)
            send("wear " .. qol.regen)
        end
        send("sleep")
    end, "sleep, wearing the regen ring first if one is set (/awinv regen)")

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
            pcall(setWidgetAppearance, widget, { zIndex = 9999 })
            render()
            utilprint(TAG .. "panel up (" .. count_where("eq") .. " worn, "
                .. count_where("inv") .. " carried). Not visible? /awinv reset.")

        elseif low == "reset" then
            --[[
                Saved geometry wins over createWidget defaults, and a widget
                can be restored off-screen or under another panel — visible
                by every measure and impossible to see. Put it somewhere
                known. The movers are pcall'd: names beyond resizeWidget
                vary by build, and a mover this client lacks should cost
                nothing.
            ]]
            pcall(resizeWidget, widget, 460, 520)
            pcall(moveWidget, widget, 120, 120)
            pcall(setWidgetProperty, widget, "position", { x = 120, y = 120 })
            pcall(setWidgetAppearance, widget, { zIndex = 9999 })
            showWidget(widget)
            render()
            utilprint(TAG .. "panel fronted at 120,120 sized 460x520.")

        elseif low == "hide" then
            hideWidget(widget)

        elseif low == "debug" then
            --[[
                Which stage went quiet. sent counts commands out; open/close
                are {tag} markers seen; row is lines seen inside a block;
                parsed is rows that became items. sent>0 with open=0 means
                the blocks never arrived (or the openers never matched);
                rows without parsed means the CSV shape surprised us.
            ]]
            local nItems = 0
            for _, _x in pairs(db.items) do nItems = nItems + 1 end
            local nStats = 0
            for _, _x in pairs(ids.stats) do nStats = nStats + 1 end
            utilprint(TAG .. "sent " .. st.nSent .. " | opens " .. st.nOpen
                .. " | closes " .. st.nClose .. " | rows " .. st.nRow
                .. " | parsed " .. st.nParsed)
            utilprint(TAG .. "items " .. nItems .. " | id records " .. nStats
                .. " | inBlock '" .. st.inBlock .. "' | expect " .. #st.expect
                .. " | conQueue " .. #st.conQueue)
            utilprint(TAG .. "gag " .. tostring(cfg.gag) .. " | auto "
                .. tostring(cfg.auto) .. " | id pending '" .. ids.pending
                .. "' | id queue " .. #ids.q)

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

        elseif low == "best" then
            view = "best"
            showWidget(widget)
            render()

        elseif low == "use" then
            view = "use"
            showWidget(widget)
            render()

        elseif low == "id" or string.sub(low, 1, 3) == "id " then
            local what = trim(string.sub(low, 3))
            if what == "stop" then
                ids.q = {}
                ids.pending = ""
                ids.rec = nil
                id_guard_off()
                id_trigs(false)
                utilprint(TAG .. "identify queue emptied.")
            elseif what == "all" or what == "missing" then
                local added = id_queue(what)
                utilprint(TAG .. added .. " item(s) queued for identify...")
                id_next()
            elseif what ~= "" and tonumber(what) ~= nil then
                table.insert(ids.q, what)
                id_next()
            else
                utilprint(TAG .. "usage: /awinv id <serial> | missing | all | stop")
            end

        elseif string.sub(low, 1, 5) == "score" then
            local serial = trim(string.sub(low, 6))
            local sc = score_of(serial)
            if sc == nil then
                utilprint(TAGR .. "no identify record for '" .. serial
                    .. "' - /awinv id " .. serial .. " first.")
            else
                utilprint(TAG .. serial .. " scores " .. sc
                    .. " under profile " .. prof.active .. ".")
            end

        elseif string.sub(low, 1, 4) == "prio" then
            local rest = trim(string.sub(a, 5))
            local restLow = string.lower(rest)

            if restLow == "" or restLow == "list" then
                utilprint(TAG .. "profiles (active: " .. prof.active .. "):")
                local names = {}
                for name, _ in pairs(prof.sets) do table.insert(names, name) end
                table.sort(names)
                for _, name in ipairs(names) do
                    local ws = prof.sets[name]
                    local kv = {}
                    for k, v in pairs(ws) do table.insert(kv, k .. "=" .. v) end
                    table.sort(kv)
                    utilprint("$w  " .. name .. ": " .. table.concat(kv, ", "))
                end
                utilprint("$w  /awinv prio use <name> | set <name> <stat> <weight> | del <name> [stat]")

            elseif string.sub(restLow, 1, 4) == "use " then
                local name = trim(string.sub(restLow, 5))
                if type(prof.sets[name]) == "table" then
                    prof.active = name
                    save_prof()
                    render()
                    utilprint(TAG .. "scoring with profile " .. name .. ".")
                else
                    utilprint(TAGR .. "no profile named '" .. name .. "'.")
                end

            elseif string.sub(restLow, 1, 4) == "set " then
                -- prio set <name> <stat> <weight>; a new name makes a profile
                local p1 = string.find(restLow, " ", 1, true)
                local tail = trim(string.sub(restLow, p1 + 1))
                local p2 = string.find(tail, " ", 1, true)
                local rest2 = (p2 ~= nil) and trim(string.sub(tail, p2 + 1)) or ""
                local p3 = string.find(rest2, " ", 1, true)
                if p2 == nil or p3 == nil then
                    utilprint(TAG .. "usage: /awinv prio set <name> <stat> <weight>")
                else
                    local name = string.sub(tail, 1, p2 - 1)
                    local stat = string.sub(rest2, 1, p3 - 1)
                    local weight = tonumber(trim(string.sub(rest2, p3 + 1)))
                    local known = false
                    for _, v in pairs(STAT_MAP) do
                        if v == stat then known = true end
                    end
                    if weight == nil or not known then
                        utilprint(TAGR .. "stats are the id-box keys: str, intel, wis, "
                            .. "dex, con, luck, hp, mana, moves, hit, dam, all_phys, "
                            .. "all_magic and the resists.")
                    else
                        if type(prof.sets[name]) ~= "table" then prof.sets[name] = {} end
                        if weight == 0 then
                            prof.sets[name][stat] = nil
                        else
                            prof.sets[name][stat] = weight
                        end
                        save_prof()
                        render()
                        utilprint(TAG .. name .. "." .. stat .. " = " .. weight .. ".")
                    end
                end

            elseif string.sub(restLow, 1, 4) == "del " then
                local name = trim(string.sub(restLow, 5))
                if type(prof.sets[name]) == "table" and name ~= prof.active then
                    prof.sets[name] = nil
                    save_prof()
                    utilprint(TAG .. "profile " .. name .. " deleted.")
                else
                    utilprint(TAGR .. "can't delete '" .. name
                        .. "' (missing, or the active profile).")
                end
            else
                utilprint(TAG .. "usage: /awinv prio [list] | use <name> | set <name> <stat> <w> | del <name>")
            end

        elseif string.sub(low, 1, 4) == "use " then
            local serial = trim(string.sub(low, 4))
            local it = db.items[serial]
            if type(it) ~= "table" then
                utilprint(TAGR .. "serial " .. serial .. " isn't in the index.")
            else
                local verb = "use"
                if it.itype == 8 then verb = "quaff" end
                if it.itype == 19 or it.itype == 14 then verb = "eat" end
                if it.itype == 2 then verb = "recite" end
                send(verb .. " " .. serial)
                utilprint(TAG .. verb .. " " .. serial .. " (" .. it.name .. ")")
            end

        elseif string.sub(low, 1, 3) == "go " then
            local serial = trim(string.sub(low, 3))
            local it = db.items[serial]
            if type(it) ~= "table" then
                utilprint(TAGR .. "serial " .. serial .. " isn't in the index.")
            else
                send("hold " .. serial)
                send("enter")
                utilprint(TAG .. "entering " .. it.name .. "...")
            end

        elseif string.sub(low, 1, 5) == "regen" then
            local what = trim(string.sub(low, 6))
            if what == "off" then
                qol.regen = ""
                qol.regenPrev = ""
                qol.watchWear = false
                save_qol()
                utilprint(TAG .. "regen ring off.")
            elseif what ~= "" and tonumber(what) ~= nil then
                qol.regen = what
                save_qol()
                utilprint(TAG .. "regen ring set to " .. what
                    .. " - worn when you type 'sleep', swapped back on waking.")
            else
                utilprint(TAG .. "regen ring: "
                    .. (qol.regen ~= "" and qol.regen or "not set")
                    .. ". /awinv regen <serial> | off")
            end

        elseif string.sub(low, 1, 6) == "backup" then
            local name = trim(string.sub(low, 7))
            if name == "" then name = "manual" end
            name = string.gsub(name, "[^a-z0-9_-]", "")
            local file = do_backup(name)
            if file ~= "" then
                utilprint(TAG .. "backed up to " .. file .. ".")
            else
                utilprint(TAGR .. "backup failed - the file wouldn't write.")
            end

        elseif string.sub(low, 1, 7) == "restore" then
            local name = trim(string.sub(low, 8))
            if name == "" then name = "manual" end
            name = string.gsub(name, "[^a-z0-9_-]", "")
            if do_restore(name) then
                render()
                utilprint(TAG .. "restored from backup '" .. name .. "'.")
            else
                utilprint(TAGR .. "no readable backup named '" .. name .. "'.")
            end

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
                    or "auto - scales with the panel (/awcore font can still pin the suite size)."))

        else
            utilprint(TAG .. "inventory, worn, keyring and vault in one panel.")
            utilprint("$w  /awinv                     show the panel")
            utilprint("$w  /awinv hide                put it away")
            utilprint("$w  /awinv refresh             rescan eq, inv, containers, keyring")
            utilprint("$w  /awinv vault               rescan with the vault too")
            utilprint("$w  /awinv search <text>       filter the panel")
            utilprint("$w  /awinv id <serial|missing|all|stop>   identify into the database")
            utilprint("$w  /awinv best                best identified item per slot")
            utilprint("$w  /awinv use [serial]        consumables/portals view, or use one")
            utilprint("$w  /awinv go <serial>         hold a portal and enter it")
            utilprint("$w  /awinv score <serial>      score one item")
            utilprint("$w  /awinv prio ...            scoring profiles (list/use/set/del)")
            utilprint("$w  /awinv regen <serial|off>  ring worn on sleep, swapped back on wake")
            utilprint("$w  /awinv backup|restore [name]   the item + identify stores")
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
    if ids.timer ~= nil then pcall(removeTimer, ids.timer); ids.timer = nil end
    if ids.guard ~= nil then pcall(removeTimer, ids.guard); ids.guard = nil end
    if qol.watchTimer ~= nil then pcall(removeTimer, qol.watchTimer); qol.watchTimer = nil end
end
