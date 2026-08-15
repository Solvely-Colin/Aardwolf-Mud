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
    there is no Lua VM here): a scan queue, one data command in flight at a
    time. Measured live, the {tag} wrappers are NOT in this client's stream
    — the rows arrive bare — so a scan is not keyed on markers: every
    row-shaped line while a scan is open files under that scan's location,
    and the scan ends at the prompt (EQ Search's test), at a {/closer}
    where one exists, or at a timeout. Containers found by the main
    inventory scan queue their own scans behind it.

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
    version     = "2.5.0",
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
    Capture state. scanQ is the line of data commands still to run this
    refresh, one in flight at a time; inBlock is the location the open scan
    files under ("eq", "inv", "key", "vault", "c:<serial>") or "" idle.

    Scans are NOT keyed on {tag} wrappers. Measured live: the eqdata and
    invdata rows arrive with no {braces} markers anywhere in the stream —
    even {invdata}, which Core's gag would otherwise swallow whole, scrolled
    past raw. So the rows themselves are the signal (8+ CSV fields behind a
    long numeric serial) and the prompt is the terminator, the same way EQ
    Search ends its capture. Wrapper triggers stay registered as counters
    and early terminators for setups where they do exist.
]]
local st = {
    scanQ    = {},
    inBlock  = "",
    inId     = "",       -- kept for state compatibility; unused by scans
    mine     = false,    -- current scan is one we requested
    buf      = {},       -- serials seen in the current scan
    conQueue = {},       -- kept for debug display; containers ride scanQ
    blockTimer = nil,
    pokeTimer  = nil,    -- invmon debounce
    lastAuto   = 0,      -- value of clockMs at the last auto refresh
    clockMs    = 0,      -- counter of debounce windows, bumped per invmon burst
    -- lifetime counters, so /awinv debug can say which stage went quiet
    nSent = 0, nOpen = 0, nClose = 0, nRow = 0, nParsed = 0,
    rej = "",            -- why the last row was rejected, for /awinv debug
    nEmpty = 0,          -- scans that closed having parsed nothing
    buildAfter = false,  -- /awinv build: identify everything once scans finish
    scanRows = 0,        -- rows this scan has produced; gates the prompt-close
    scanSeq = 0,         -- scan token, so a grace timer can't close a later scan
}

local widget  = nil
local view    = "list"   -- list | best | use | settings | item:<serial>
local filter  = ""
local rowTrig = nil

-- assigned below, forward-declared because the identify engine and the
-- invmon path repaint and are defined first (see MUDFORGE-NOTES on forward
-- declarations binding the global when they sit below their callers)
local render = nil

-- the command handler, assigned in init(); panel buttons dispatch through
-- it so there is exactly one implementation of every action
local do_cmd = nil

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
    restore  = "",      -- undo command after this id: wear it back / re-bag it
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
    ["Affect Mods"] = "affects",
    ["Owned By"]    = "owned_by",
    ["Clan Item"]   = "clan",
    ["Specials"]    = "specials",
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
-- how many of each a body has, from dinv's inv.wearables. Medals are FOUR
-- slots and ears, necks, wrists and fingers are two apiece; a table that
-- said one of each quietly hid half your gear from the best list.
local SLOT_CAP = {
    light = 1, head = 1, eyes = 1, ear = 2, neck = 2, back = 1,
    medal = 4, torso = 1, body = 1, waist = 1, arms = 1, wrist = 2,
    hands = 1, finger = 2, legs = 1, feet = 1, shield = 1,
    wield = 2, hold = 1, float = 1, above = 1, portal = 1,
    sleeping = 1, ready = 1,
}

--[[
    Scoring profiles, dinv's priorities. weights is "name;stat=w,stat=w;..."
    flat in storage; live it is sets[name][stat] = weight. The defaults are
    starting points, not doctrine — edit with /awinv prio.
]]
--[[
    The class profiles are dinv's own defaults, which are in turn ports of
    Aardwolf's 'compare set' class weightings divided by ten (str 10 →
    1.0). They differ only in the six stats; hit/dam/avedam are common.

    'melee' and 'defense' follow dinv's hand-tuned demonstrations, where
    the point is that EFFECTS carry large flat weights — sanctuary at 50
    beats any amount of +str — and that a weight may be negative when you
    want less of something.
]]
local prof = {
    active = "psi",
    sets = {
        psi      = { str = 1.0, intel = 1.5, wis = 1.5, dex = 1.0, con = 1.0, luck = 1.2,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },
        mage     = { str = 1.0, intel = 1.5, wis = 1.0, dex = 1.0, con = 1.0, luck = 1.0,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },
        cleric   = { str = 1.0, intel = 1.0, wis = 1.5, dex = 1.0, con = 1.0, luck = 1.0,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },
        warrior  = { str = 1.5, intel = 1.0, wis = 1.0, dex = 1.5, con = 1.0, luck = 1.0,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },
        thief    = { str = 1.2, intel = 1.0, wis = 1.0, dex = 1.5, con = 1.0, luck = 1.0,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },
        ranger   = { str = 1.0, intel = 1.0, wis = 1.5, dex = 1.0, con = 1.5, luck = 1.0,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },
        paladin  = { str = 1.0, intel = 1.5, wis = 1.0, dex = 1.0, con = 1.5, luck = 1.0,
                     hit = 0.5, dam = 0.5, ave_dam = 0.4 },

        melee    = { str = 1, intel = 0.6, wis = 0.6, dex = 0.8, con = 0.2, luck = 1,
                     dam = 0.9, hit = 0.4, ave_dam = 0.9, hp = 0.02, mana = 0.01,
                     sanctuary = 50, haste = 20, invis = 10, flying = 5,
                     regeneration = 5, all_magic = 0.03, all_phys = 0.03 },
        defense  = { con = 1, hp = 0.05, sanctuary = 10, regeneration = 5,
                     all_phys = 0.10, all_magic = 0.05 },
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
    Position-base probe, measured live on this runtime: string.find
    returned 0-BASED positions — one short of Lua's contract. The
    symptom was every row rejecting with an empty type field while the
    row text itself printed back intact, which acquitted trim and sub
    and left exactly one suspect. (It would also produce MUDFORGE-NOTES
    11's "init never advances" hang: a walk that adds a one-short q
    lands on the comma it just found, forever.) pfind asks once where
    "y" sits in "xy" and corrects every position-consuming find.
]]
--[[
    Measured live, the real find defect at last: string.find returns its
    Lua pair (start, end) COLLECTED INTO ONE ARRAY when assigned to a
    single local — MUDFORGE-NOTES 13b's destructuring trap, in the stdlib.
    The probe printed "2,20": the array [2,2], then "+ 0" concatenated.
    Every arithmetic on such a value is NaN and every slice built from it
    is empty, which is the whole parser saga in one line. No shipping
    plugin ever hit it because none consumes find's position — they use
    it as a boolean. rawfind_first digs out the start element whatever
    the key shape, and the base probe runs on the extracted number.
]]
local function rawfind_first(s, needle)
    local q = string.find(s, needle, 1, true)
    if q == nil then return nil end
    if type(q) == "number" then return q end
    local v = q[0]
    if v == nil then v = q["0"] end
    if v == nil then v = q[1] end
    if v == nil then v = q["1"] end
    return tonumber(v)
end

local FIND_ADJ = 0
if rawfind_first("xy", "y") == 1 then FIND_ADJ = 1 end

local function pfind(s, needle)
    local q = rawfind_first(s, needle)
    if q == nil then return nil end
    return q + FIND_ADJ
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
        local p = pfind(rest, ",")
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
        local p = pfind(rest, "  ")
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
--[[
    Row parse by pure string walking — scalars only. The first version
    split into a table and read it back positionally, and every one of 186
    live rows bounced while the counters proved the lines themselves were
    arriving. Rather than divine which table semantic this runtime breaks,
    there are none left: two fields off the front by find/sub, the last
    five comma positions carried in five scalars, the name is what remains
    between. Slicing walk per MUDFORGE-NOTES 11; rej remembers why the
    last rejection happened for /awinv debug.
]]
local function parse_row(line, where)
    local s = trim(line)

    local p1 = pfind(s, ",")
    if p1 == nil or p1 < 7 then
        st.rej = "no-serial: " .. string.sub(s, 1, 60)
        return false
    end
    local serial = string.sub(s, 1, p1 - 1)
    if tonumber(serial) == nil then
        st.rej = "serial-nan: " .. string.sub(s, 1, 60)
        return false
    end

    local rest = string.sub(s, p1 + 1)
    local p2 = pfind(rest, ",")
    if p2 == nil then
        st.rej = "no-flags: " .. string.sub(s, 1, 60)
        return false
    end
    local flags = string.sub(rest, 1, p2 - 1)
    rest = string.sub(rest, p2 + 1)      -- name,level,type,unique,wear,timer

    -- the last five comma positions, oldest first, in five scalars
    local c1, c2, c3, c4, c5 = 0, 0, 0, 0, 0
    local off = 0
    local guard = 0
    while guard < 300 do
        guard = guard + 1
        local q = pfind(string.sub(rest, off + 1), ",")
        if q == nil then break end
        off = off + q
        c1 = c2
        c2 = c3
        c3 = c4
        c4 = c5
        c5 = off
    end
    if c1 == 0 then
        st.rej = "few-commas: " .. string.sub(s, 1, 60)
        return false
    end

    local ity = num_or(string.sub(rest, c2 + 1, c3 - 1), -99)
    if ity == -99 then
        st.rej = "type-nan: " .. string.sub(s, 1, 60)
        return false
    end

    local it = {
        serial = serial,
        flags  = trim(flags),
        name   = trim(decode(trim(string.sub(rest, 1, c1 - 1)))),
        level  = num_or(string.sub(rest, c1 + 1, c2 - 1), 0),
        itype  = ity,
        unique = num_or(string.sub(rest, c3 + 1, c4 - 1), 0),
        wear   = num_or(string.sub(rest, c4 + 1, c5 - 1), -1),
        timer  = num_or(string.sub(rest, c5 + 1), -1),
        where  = where,
    }
    db.items[serial] = it
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
        local p = pfind(rest, "\n")
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
            local q = pfind(rest2, "\t")
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
        local p = pfind(rest, "\n")
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
            local q = pfind(rest2, "\t")
            if q == nil then
                rest2 = ""
            else
                field = string.sub(rest2, 1, q - 1)
                rest2 = string.sub(rest2, q + 1)
            end

            if serial == "" then
                serial = trim(field)
            else
                local eq = pfind(field, "=")
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
        local p = pfind(rest, "|")
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
            local c = pfind(part, ":")
            if c ~= nil and c > 1 then
                local name = string.sub(part, 1, c - 1)
                local ws = {}
                local rest2 = string.sub(part, c + 1)
                local g2 = 0
                while rest2 ~= "" and g2 < 80 do
                    g2 = g2 + 1
                    local kv = rest2
                    local q = pfind(rest2, ",")
                    if q == nil then
                        rest2 = ""
                    else
                        kv = string.sub(rest2, 1, q - 1)
                        rest2 = string.sub(rest2, q + 1)
                    end
                    local eq = pfind(kv, "=")
                    if eq ~= nil and eq > 1 then
                        local w = tonumber(string.sub(kv, eq + 1))
                        if w ~= nil then ws[string.sub(kv, 1, eq - 1)] = w end
                    end
                end
                prof.sets[name] = ws
            end
        end
    end

    --[[
        The saved active profile may name one this version no longer ships
        — 2.4.0 replaced the invented damage/caster/tank set with dinv's
        class weights. An active profile that resolves to nothing makes
        score_of return nil for every item, which empties the best tab and
        every score in the list with no error to explain it. Fall back to
        a profile that exists, preferring psi, then whatever is there.
    ]]
    if type(prof.sets[prof.active]) ~= "table" then
        if type(prof.sets.psi) == "table" then
            prof.active = "psi"
        else
            for name, ws in pairs(prof.sets) do
                if type(ws) == "table" then prof.active = name end
            end
        end
    end
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
-- query language, dinv's inv.query
--
-- "key value" pairs AND'd together, "||" between OR groups, min/max
-- prefixes on numbers, "~" to negate, a bare word matching the name, and
-- the special words all/worn/carried. This is what makes get, put,
-- keyword and forget worth having: one grammar, every command.
--
--     dagger                       name contains "dagger"
--     type weapon minlevel 100     both must hold
--     wearable finger || type ring one or the other
--     ~flags K minlevel 50         not kept, level 50+
---

-- one field of the merged item + identify record, as text or number
local function q_field(serial, key)
    local it = db.items[serial]
    if type(it) ~= "table" then return nil end
    local r = ids.stats[serial]
    if type(r) ~= "table" then r = {} end

    if key == "name" or key == "n" then return it.name end
    if key == "level" or key == "lvl" then return it.level end
    if key == "serial" or key == "id" or key == "objid" then return it.serial end
    if key == "flags" or key == "flag" then return it.flags end
    if key == "timer" then return it.timer end
    if key == "unique" then return it.unique end
    if key == "loc" or key == "location" or key == "where" then return it.where end
    if key == "type" then
        local tn = TYPE_NAME[it.itype]
        if type(tn) == "string" then return tn end
        return tostring(it.itype)
    end
    if key == "score" then
        local sc = score_of(serial)
        if sc == nil then return 0 end
        return sc
    end
    if key == "slot" or key == "wearloc" then return slot_of(serial) end
    if key == "kw" or key == "tag" then return tostring(r.tags or "") end

    -- identify fields and stat mods share the record, so one lookup covers
    -- wearable/material/worth/weight/damtype/... and str/int/hit/dam/...
    local v = r[key]
    if v ~= nil then return v end

    -- a few spellings the box uses that a player would not type
    if key == "damtype" then return r.dam_type end
    if key == "weapontype" then return r.weapon_type end
    if key == "avedam" then return r.ave_dam end
    if key == "leadsto" then return r.leads_to end
    if key == "foundat" then return r.found_at end
    if key == "allphys" then return r.all_phys end
    if key == "allmagic" then return r.all_magic end
    return nil
end

-- does one "key value" term hold for this item?
local function q_term(serial, key, val)
    local neg = false
    if string.sub(key, 1, 1) == "~" then
        neg = true
        key = string.sub(key, 2)
    end

    local mode = ""
    if string.sub(key, 1, 3) == "min" and #key > 3 then
        mode = "min"
        key = string.sub(key, 4)
    elseif string.sub(key, 1, 3) == "max" and #key > 3 then
        mode = "max"
        key = string.sub(key, 4)
    end

    local got = q_field(serial, key)
    local hit = false

    if got ~= nil then
        local gn = tonumber(got)
        local vn = tonumber(val)
        if mode == "min" then
            hit = (gn ~= nil and vn ~= nil and gn >= vn)
        elseif mode == "max" then
            hit = (gn ~= nil and vn ~= nil and gn <= vn)
        elseif gn ~= nil and vn ~= nil then
            hit = (gn == vn)
        else
            hit = pfind(string.lower(tostring(got)), string.lower(val)) ~= nil
        end
    end

    if neg then return not hit end
    return hit
end

--[[
    Does this item match the query? Walked by slicing rather than split
    into tables: the same runtime that collects find's returns into an
    array is not one to hand a parser more structure than it needs.
]]
local function q_match(serial, query)
    local q = trim(string.lower(query))
    local it = db.items[serial]
    if type(it) ~= "table" then return false end

    if q == "" or q == "carried" then
        return it.where ~= "eq"
    end
    if q == "all" then return true end
    if q == "worn" then return it.where == "eq" end

    -- OR groups first: any group matching is a match
    local rest = q
    local guard = 0
    while guard < 40 do
        guard = guard + 1

        local group = rest
        local bar = pfind(rest, "||")
        if bar == nil then
            rest = ""
        else
            group = string.sub(rest, 1, bar - 1)
            rest = string.sub(rest, bar + 2)
        end

        -- every term in the group must hold
        local ok = true
        local words = {}
        for word in string.gmatch(group, "%S+") do
            table.insert(words, word)
        end

        local i = 1
        while i <= #words do
            local key = words[i]
            local isKey = (q_field(serial, key) ~= nil)
                or string.sub(key, 1, 1) == "~"
                or string.sub(key, 1, 3) == "min"
                or string.sub(key, 1, 3) == "max"

            if isKey and i < #words then
                if not q_term(serial, key, words[i + 1]) then ok = false end
                i = i + 2
            else
                -- a bare word matches the name
                if pfind(string.lower(it.name), key) == nil then ok = false end
                i = i + 1
            end
        end

        if ok and #words > 0 then return true end
        if rest == "" then return false end
    end
    return false
end

-- every indexed serial matching a query, worn items last so a list reads
-- the way the game shows it
local function q_find(query)
    local out = {}
    for serial, it in pairs(db.items) do
        if type(it) == "table" and q_match(serial, query) then
            table.insert(out, serial)
        end
    end
    table.sort(out, function(x, y)
        local a, b = db.items[x], db.items[y]
        if a.where ~= b.where then return a.where < b.where end
        return a.name < b.name
    end)
    return out
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

    --[[
        Plain "Label : value" pairs, up to two per row.

        The box PADS its labels — "Wearable    : finger" — so splitting on
        column padding puts the label in one chunk and ": finger" in the
        next. Requiring the colon to sit inside a chunk therefore threw
        away every padded field, which is every field that matters: 94
        items identified and not one reported a wearable slot.

        So a chunk beginning with a colon is the value belonging to the
        chunk before it, and a label with no colon yet is held until one
        arrives. Both layouts fall out of the same walk.
    ]]
    local pending = ""

    local keep = function(label, value)
        value = trim(value)
        -- the box's right border rides along on the last value of a row
        while string.sub(value, -1) == "|" do
            value = trim(string.sub(value, 1, #value - 1))
        end
        local key = ID_FIELDS[trim(label)]
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

    for _, chunk in ipairs(split_cols(body)) do
        local c = pfind(chunk, ":")
        if c == 1 then
            if pending ~= "" then
                keep(pending, string.sub(chunk, 2))
                pending = ""
            end
        elseif c ~= nil and c > 1 then
            keep(string.sub(chunk, 1, c - 1), string.sub(chunk, c + 1))
            pending = ""
        else
            pending = trim(chunk)
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

    -- wear it back / re-bag it before anything else goes out
    if ids.restore ~= "" then
        send(ids.restore)
        ids.restore = ""
    end

    if type(r) == "table" and serial ~= "" then
        r.at = stamp()

        --[[
            Affect Mods is a word list — sanctuary, regeneration, flying,
            detect invis — and dinv turns each word into a flag of its own
            so a query can ask for one by name. That is how it finds a
            regen ring without being told which item it is.
        ]]
        if type(r.affects) == "string" and r.affects ~= "" then
            local words = string.gsub(string.lower(r.affects), ",", " ")
            for wd in string.gmatch(words, "%a+") do
                r["aff_" .. wd] = 1
            end
        end
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

    --[[
        'id' only reaches the carried inventory — measured live: a worn
        item answers "You do not have that item." dinv's build removed,
        identified and re-wore each piece, which is why it wanted a quiet
        room; same here. Container contents come out and go back. The
        restore command fires after the box lands or the guard gives up,
        so a cursed piece that refuses removal costs one skipped id and a
        harmless wear attempt, not a naked character.
    ]]
    local it2 = db.items[serial]
    ids.restore = ""
    if type(it2) == "table" then
        if it2.where == "eq" then
            ids.restore = "wear " .. serial
            send("remove " .. serial)
        elseif it2.where == "key" then
            -- the keyring has its own verbs; dinv uses exactly these
            ids.restore = "keyring put " .. serial
            send("keyring get " .. serial)
        elseif pfind(it2.where, "c:") == 1 then
            local con = string.sub(it2.where, 3)
            ids.restore = "put " .. serial .. " " .. con
            send("get " .. serial .. " " .. con)
        end
    end

    ids.pending = serial
    id_trigs(true)
    send("id " .. serial)

    id_guard_off()
    ids.guard = addTimer(8000, function()
        ids.guard = nil
        if ids.pending == serial and type(ids.rec) ~= "table" then
            utilprint(TAGR .. "no id box for " .. serial .. " - skipped.")
            if ids.restore ~= "" then send(ids.restore); ids.restore = "" end
            ids.pending = ""
            id_trigs(false)
            id_next()
        end
    end)
end

--[[
    Queue items for identify. Vault contents are deliberately excluded —
    dinv marks vault identification unsupported outright, and an id that
    can never answer just burns the guard timer per item.

    Consumables are identified ONCE PER NAME, not per object: dinv keeps a
    "frequent" cache keyed on name for potions, pills, food, wands, staves
    and scrolls, because a hundred bought potions are the same item a
    hundred times and identifying each is a hundred pointless round trips.
]]
local FUNGIBLE = { [8] = true, [19] = true, [14] = true,
                   [3] = true, [4] = true, [2] = true }

local function id_queue(which)
    local added = 0
    local seenName = {}

    -- names already identified, so a fresh potion of a known kind is skipped
    for s2, r2 in pairs(ids.stats) do
        if type(r2) == "table" then
            local i2 = db.items[s2]
            if type(i2) == "table" and FUNGIBLE[i2.itype] == true then
                seenName[string.lower(i2.name)] = true
            end
        end
    end

    for serial, it in pairs(db.items) do
        if type(it) == "table" and (it.where == "inv" or it.where == "eq"
            or it.where == "key" or pfind(it.where, "c:") == 1) then

            local known = type(ids.stats[serial]) == "table"
            local nm = string.lower(it.name)

            if FUNGIBLE[it.itype] == true and which ~= "all" and seenName[nm] then
                known = true          -- one of these is every one of these
            end

            if which == "all" or (which == "missing" and not known) then
                table.insert(ids.q, serial)
                if FUNGIBLE[it.itype] == true then seenName[nm] = true end
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
    if pfind(tostring(line or ""), "full appraisal") ~= nil then
        ids.rec.full = 0
    end
    id_store()
end

---
-- scoring, dinv's priority/score, and the best-per-slot answer
---

--[[
    dinv's scoring kernel, as measured from inv.score.extended:

      score = SUM over weighted keys of (weight x stat value)

    with two additions beyond plain stat mods.

    EFFECTS are flat: an item either has sanctuary or it does not, so its
    weight is added once, not multiplied. They come out of Affect Mods,
    which is why parsing that field mattered — an item granting sanctuary
    at weight 50 outscores a pile of +str, which is exactly dinv's intent.

    RESIST ROLLUPS: a priority that weights all_phys credits each of the
    three physical resists at a third of it, and all_magic each of the
    seventeen magical ones at a seventeenth. Naming a resist explicitly
    wins over the rollup — specificity beats the general case.
]]
local PHYS_RES = { "bash", "pierce", "slash" }
local MAG_RES = { "acid", "air", "cold", "disease", "earth", "electric",
    "energy", "fire", "holy", "light", "magic", "mental", "negative",
    "poison", "shadow", "sonic", "water" }

local function score_of(serial)
    local r = ids.stats[serial]
    if type(r) ~= "table" then return nil end
    local ws = prof.sets[prof.active]
    if type(ws) ~= "table" then return nil end

    local total = 0
    for stat, weight in pairs(ws) do
        local v = tonumber(r[stat])
        if v ~= nil then
            total = total + v * weight
        elseif r["aff_" .. stat] == 1 then
            total = total + weight
        end
    end

    local wp = tonumber(ws.all_phys)
    if wp ~= nil and wp > 0 then
        for _, k in ipairs(PHYS_RES) do
            local v = tonumber(r[k])
            if v ~= nil and ws[k] == nil then total = total + wp * v / 3 end
        end
    end
    local wm = tonumber(ws.all_magic)
    if wm ~= nil and wm > 0 then
        for _, k in ipairs(MAG_RES) do
            local v = tonumber(r[k])
            if v ~= nil and ws[k] == nil then total = total + wm * v / 17 end
        end
    end

    -- two decimals, once, at the end — dinv rounds the same way
    return tonumber(string.format("%.2f", total))
end

-- the box says "Wearable : finger"; anything unlisted gets its own slot
local function slot_of(serial)
    local r = ids.stats[serial]
    if type(r) ~= "table" then return "" end
    local wearable = string.lower(trim(tostring(r.wearable or "")))
    if wearable == "" then return "" end
    -- first word: "wield (weapon)" and friends carry trailing commentary
    local p = pfind(wearable, " ")
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
                --[[
                    Zero-scoring items belong here too. dinv's set builder
                    takes any eligible item and keeps the highest score,
                    zero included — excluding them left a character's
                    rings, boots, neck and WEAPON off the list entirely
                    whenever the active profile happened not to weight
                    what those pieces carry. "Nothing better exists" is an
                    answer; a missing slot is not.
                ]]
                local sc = score_of(serial)
                if sc ~= nil then
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
    .arc-i .btns {
        display: flex; flex-wrap: wrap; gap: 4px;
        margin-bottom: 6px;
    }
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
    if pfind(string.lower(it.name), q) ~= nil then return true end
    local tn = TYPE_NAME[it.itype]
    if type(tn) == "string"
        and pfind(string.lower(tn), q) ~= nil then return true end
    if pfind(it.serial, q) ~= nil then return true end
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
                or (pfind(it.where, prefix) == 1 and prefix == "c:") then
                n = n + 1
            end
        end
    end
    return n
end

--[[
    Every container we know of, wherever it sits: carried, worn (a pack on
    the back is type 11 in the eq list) or nested inside another bag. A
    list that only looked at "inv" missed worn packs entirely and never
    recursed, so their contents stayed invisible.
]]
--[[
    Is this a container? The invdata CSV's type column says 11, but dinv
    never trusted that column — it read the identify box's Type field and
    compared the word "Container". Take either: the CSV number when that
    is all we have, the identified word once we have it. A bag missed
    here is a bag whose contents are never scanned.
]]
local function is_container(serial)
    local it = db.items[serial]
    if type(it) ~= "table" then return false end
    if it.itype == 11 then return true end
    local r = ids.stats[serial]
    if type(r) == "table" and type(r.itype) == "string"
        and string.lower(trim(r.itype)) == "container" then
        return true
    end
    return false
end

local function container_list()
    local out = {}
    for serial, it in pairs(db.items) do
        if type(it) == "table" and is_container(serial)
            and (it.where == "inv" or it.where == "eq"
                 or pfind(it.where, "c:") == 1) then
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

    --[[
        Actions for THIS item. What is offered depends on where it sits:
        worn things come off, carried things go on or into a bag, bagged
        things come out. Every button is the command it would be typed as,
        so the panel and the keyboard cannot disagree.
    ]]
    local btn = function(label, cmd, tip)
        return '<div class="tb" data-mud-action="cmd" data-mud-data="'
            .. esc(cmd) .. '" title="' .. esc(tip) .. '">' .. label .. "</div>"
    end

    local acts = btn("identify", "id " .. serial, "read its stats into the database")

    if it.where == "eq" then
        acts = acts .. btn("remove", "do remove " .. serial, "take it off")
    elseif it.where == "inv" then
        if it.itype == 8 or it.itype == 19 or it.itype == 2 or it.itype == 14 then
            acts = acts .. btn("use", "use " .. serial, "quaff, eat or recite it")
        elseif it.itype == 20 or it.itype == 15 then
            acts = acts .. btn("enter", "go " .. serial, "hold it and enter")
        else
            acts = acts .. btn("wear", "do wear " .. serial, "put it on")
        end
        acts = acts .. btn("drop", "do drop " .. serial, "drop it here")
    elseif pfind(it.where, "c:") == 1 then
        acts = acts .. btn("take out", "do get " .. serial .. " "
            .. string.sub(it.where, 3), "get it from its container")
    end

    if it.itype == 11 then
        acts = acts .. btn("scan bag", "scan " .. serial, "index what is inside it")
    end

    table.insert(out, '<div class="sec">Do</div><div class="btns">' .. acts
        .. btn("&#9664; back", "show", "back to the list") .. "</div>")

    return table.concat(out, "\n")
end

local function render_best()
    local out = {}
    local level = char_level()
    local rows = best_set(level)

    table.insert(out, '<div class="sec">Best identified item per slot &#8212; level '
        .. level .. ", profile " .. esc(prof.active) .. "</div>")

    if #rows == 0 then
        --[[
            Say WHICH stage is empty. "nothing scored" reads as a bug when
            the truth is usually one of three ordinary things: nothing
            indexed, nothing identified, or identified gear whose stats
            this profile happens not to weight.
        ]]
        local nId = 0
        for _, r in pairs(ids.stats) do
            if type(r) == "table" then nId = nId + 1 end
        end
        local nSlot = 0
        for s2, r2 in pairs(ids.stats) do
            if type(r2) == "table" and slot_of(s2) ~= "" then nSlot = nSlot + 1 end
        end

        local why = ""
        if nId == 0 then
            why = "nothing identified yet &#8212; <code>/awinv build</code>."
        elseif nSlot == 0 then
            why = nId .. " item(s) identified, but none of them report a "
                .. "wearable slot, so there is nothing to rank per location."
        else
            why = nSlot .. " wearable item(s) identified, but none score above "
                .. "zero under <b>" .. esc(prof.active) .. "</b>. Try another "
                .. "profile from the menu, or <code>/awinv prio</code> to see "
                .. "what it weights."
        end
        table.insert(out, '<div class="empty">' .. why .. "</div>")
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

    --[[
        Suggest the profile that matches the character. The class comes
        from GMCP as a subclass name most of the time (Elementalist, not
        Mage), so map the ones Aardwolf ships back to their primary.
    ]]
    local SUBCLASS = {
        elementalist = "mage", necromancer = "mage", wizard = "mage",
        priest = "cleric", druid = "cleric", monk = "cleric",
        soldier = "warrior", blacksmith = "warrior", gladiator = "warrior",
        assassin = "thief", bandit = "thief", navigator = "thief",
        huntsman = "ranger", scavenger = "ranger", herbalist = "ranger",
        avenger = "paladin", crusader = "paladin", templar = "paladin",
        mentalist = "psi", psionicist = "psi", spiritualist = "psi",
    }
    local cls = string.lower(trim(tostring(
        gfield(getGMCPData("char.base"), "subclass")
        or gfield(getGMCPData("char.base"), "class") or "")))
    local want = SUBCLASS[cls]
    if want == nil and prof.sets[cls] ~= nil then want = cls end

    local tip = ""
    if want ~= nil and want ~= prof.active then
        tip = " You are a " .. esc(cls) .. ", so <b>" .. want
            .. "</b> likely suits you better &#8212; "
            .. '<span class="tb" data-mud-action="cmd" data-mud-data="prio use '
            .. want .. '">switch to ' .. want .. "</span>"
    end

    table.insert(out, '<div class="note">Scores are the active profile\'s weighted '
        .. "sums &#8212; <code>/awinv prio</code> to inspect or change weights."
        .. tip .. "</div>")
    return table.concat(out, "\n")
end

--[[
    Consumables and portals. Aardwolf's object commands accept serials, so
    the buttons here go straight at the item: quaff/eat/recite by type,
    hold-and-enter for portals.
]]
--[[
    The menu: every action as a button, grouped, each carrying the command
    text it runs. MENU is a flat list of {group, label, cmd, tip} rather
    than nested tables — a nested table through this bridge is a liability
    (NOTES 6) and a flat one renders in one pass.
]]
local MENU = {
    { g = "Scan",     l = "build",        c = "build",        t = "full rescan, then identify everything unknown" },
    { g = "Scan",     l = "refresh",      c = "refresh",      t = "rescan eq, inventory, containers and keyring" },
    { g = "Scan",     l = "+ vault",      c = "vault",        t = "rescan including the vault (needs a vault here)" },
    { g = "Scan",     l = "bags",         c = "bags",         t = "which containers are known, and what is in them" },
    { g = "Scan",     l = "id missing",   c = "id missing",   t = "identify everything with no stats yet" },
    { g = "Scan",     l = "id all",       c = "id all",       t = "re-identify everything, even known items" },
    { g = "Scan",     l = "id stop",      c = "id stop",      t = "halt the identify pass" },

    { g = "View",     l = "items",        c = "show",         t = "the item list" },
    { g = "View",     l = "best",         c = "best",         t = "best identified item per wear location" },
    { g = "View",     l = "use",          c = "use",          t = "consumables and portals" },
    { g = "View",     l = "clear filter", c = "search",       t = "drop the current filter" },

    { g = "Gear",     l = "profiles",     c = "prio",              t = "list scoring profiles and their weights" },
    { g = "Gear",     l = "psi",          c = "prio use psi",       t = "Aardwolf's psionicist weighting" },
    { g = "Gear",     l = "mage",         c = "prio use mage",      t = "Aardwolf's mage weighting" },
    { g = "Gear",     l = "cleric",       c = "prio use cleric",    t = "Aardwolf's cleric weighting" },
    { g = "Gear",     l = "warrior",      c = "prio use warrior",   t = "Aardwolf's warrior weighting" },
    { g = "Gear",     l = "thief",        c = "prio use thief",     t = "Aardwolf's thief weighting" },
    { g = "Gear",     l = "ranger",       c = "prio use ranger",    t = "Aardwolf's ranger weighting" },
    { g = "Gear",     l = "paladin",      c = "prio use paladin",   t = "Aardwolf's paladin weighting" },
    { g = "Gear",     l = "melee",        c = "prio use melee",     t = "damage plus heavy weight on sanctuary/haste" },
    { g = "Gear",     l = "defense",      c = "prio use defense",   t = "constitution, hp and resistances" },

    { g = "Find",     l = "worn",         c = "find worn",         t = "everything you are wearing" },
    { g = "Find",     l = "carried",      c = "find carried",      t = "everything not worn" },
    { g = "Find",     l = "containers",   c = "find type container", t = "your bags" },
    { g = "Find",     l = "potions",      c = "find type potion",  t = "every potion indexed" },
    { g = "Find",     l = "keys",         c = "find type key",     t = "every key indexed" },
    { g = "Find",     l = "portals",      c = "find type portal",  t = "every portal indexed" },

    { g = "Kit",      l = "regen auto",   c = "regen auto",   t = "find a regeneration ring and use it on sleep" },
    { g = "Kit",      l = "regen off",    c = "regen off",    t = "stop swapping a ring in on sleep" },

    { g = "Data",     l = "backup",       c = "backup",       t = "save the item and identify stores" },
    { g = "Data",     l = "restore",      c = "restore",      t = "load the last backup" },
    { g = "Data",     l = "serials",      c = "serials",      t = "show or hide object ids on rows" },
    { g = "Data",     l = "gag data",     c = "gag",          t = "hide the raw scan rows from the terminal" },
    { g = "Data",     l = "auto",         c = "auto",         t = "rescan automatically as your inventory changes" },
    { g = "Data",     l = "diagnostics",  c = "debug",        t = "counters and a parser self-test" },
}

local function render_menu()
    local out = {}
    local group = ""

    for _, e in ipairs(MENU) do
        if e.g ~= group then
            if group ~= "" then out[#out + 1] = "</div>" end
            group = e.g
            out[#out + 1] = '<div class="sec">' .. esc(group) .. "</div>"
            out[#out + 1] = '<div class="btns">'
        end
        out[#out + 1] = '<div class="tb" data-mud-action="cmd" data-mud-data="'
            .. esc(e.c) .. '" title="' .. esc(e.t) .. '">' .. esc(e.l) .. "</div>"
    end
    if group ~= "" then out[#out + 1] = "</div>" end

    out[#out + 1] = '<div class="note">Every button runs the command of the '
        .. "same name &#8212; <code>/awinv " .. "help</code> lists them all, and "
        .. "anything here can be typed instead.</div>"

    return table.concat(out, "\n")
end

local function render_use()
    local out = {}

    local groupsOf = function(types, title)
        local found = {}
        for _, it in pairs(db.items) do
            if type(it) == "table" and types[it.itype] == true
                and (it.where == "inv" or pfind(it.where, "c:") == 1)
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
    elseif pfind(view, "item:") == 1 then
        body = render_item(string.sub(view, 6))
    elseif view == "best" then
        body = render_best()
    elseif view == "menu" then
        body = render_menu()
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
        .. tab("menu", "menu")
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

-- the Aardwolf prompt, by plain text — hp, mn and mv together are
-- structural and no data row carries all three (EQ Search's test)
local function is_prompt(line)
    return pfind(line, "hp ") ~= nil
       and pfind(line, "mn ") ~= nil
       and pfind(line, "mv ") ~= nil
end

-- forward-declared: scan_end schedules the next scan
local next_scan = nil

--[[
    A scan ends at the prompt, at a {/closer} where wrappers exist, or at
    the timeout. Ending the main inventory scan queues one scan per
    container it named.
]]
local function scan_end()
    if st.inBlock == "" then return end
    local wasInv = (st.inBlock == "inv")
    local wasCon = (pfind(st.inBlock, "c:") == 1)
    block_release()

    --[[
        Queue a scan for every container we now know about and haven't
        already queued or scanned. Runs after the inventory scan AND after
        each container scan, so a bag inside a bag is picked up when its
        parent's contents land. db.items is the dedupe: a container whose
        contents are already filed is not re-queued.
    ]]
    if wasInv or wasCon then
        local queued = {}
        for _, q in ipairs(st.scanQ) do queued[q.where] = true end

        for _, con in ipairs(container_list()) do
            local key = "c:" .. con.serial
            local known = false
            for _, it in pairs(db.items) do
                if type(it) == "table" and it.where == key then known = true end
            end
            if queued[key] ~= true and not known then
                table.insert(st.scanQ, { cmd = "invdata " .. con.serial, where = key })
            end
        end
    end

    save_db()
    render()

    --[[
        dinv's 'build': once the last scan has drained, walk everything the
        scans found through the identify queue. The refresh knew the items;
        the ids know their stats.
    ]]
    if #st.scanQ == 0 then
        local nCon = #container_list()
        local nAll = 0
        for _, _x in pairs(db.items) do nAll = nAll + 1 end
        utilprint(TAG .. "scan complete: " .. nAll .. " item(s), "
            .. count_where("eq") .. " worn, " .. count_where("inv")
            .. " carried, " .. nCon .. " container(s).")

        --[[
            Carrying nothing while wearing plenty is almost never true —
            it is Core's tag gag. Core classifies {invdata} as a BLOCK and
            swallows every line between the markers; {eqdata} and
            {keyring} are not on that list, which is exactly why those two
            capture and this one comes back empty. Name the cure rather
            than reporting an empty bag.
        ]]
        if count_where("inv") == 0 and count_where("eq") > 0 then
            utilprint(TAGR .. "carried 0 while worn " .. count_where("eq")
                .. " - if you ARE carrying things, Core is gagging {invdata} "
                .. "as a block, which hides it from this plugin too. Fix:")
            utilprint("$Y  /awcore tags marker invdata$w")
            utilprint("$K  then '/awinv build' again.$w")
        end

        if st.buildAfter == true then
            st.buildAfter = false
            local added = id_queue("missing")
            utilprint(TAG .. "identifying " .. added .. " item(s) - gear is "
                .. "removed and re-worn as it goes. 'id stop' halts it.")
            id_next()
        end
    end

    addTimer(250, function()
        if type(next_scan) == "function" then next_scan() end
    end)
end

next_scan = function()
    if st.inBlock ~= "" then return end
    if #st.scanQ == 0 then return end

    local s = table.remove(st.scanQ, 1)
    clear_where(s.where)
    st.inBlock  = s.where
    st.mine     = true
    st.buf      = {}
    st.scanRows = 0
    st.scanSeq  = st.scanSeq + 1
    local mySeq = st.scanSeq
    if s.where == "key" then db.haveKey = true end
    if s.where == "vault" then db.haveVault = true end

    st.nSent = st.nSent + 1
    send(s.cmd)

    --[[
        The prompt only closes a scan that has produced rows — this MUD's
        prompts arrive in pairs, and a stray one landing between the send
        and the data was ending scans empty (which is how the inventory
        read 0 carried and no bag ever chained a scan). A genuinely empty
        result closes on this grace timer instead; the long timer stays
        as the catch-all.
    ]]
    addTimer(2500, function()
        if st.scanSeq == mySeq and st.inBlock ~= "" and st.scanRows == 0 then
            scan_end()
        end
    end)

    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer) end
    st.blockTimer = addTimer(BLOCK_MS, function()
        if st.inBlock ~= "" then scan_end() end
    end)
end

-- wrappers, where a setup has them: openers are counted, a closer ends the
-- open scan a shade earlier than the prompt would
local function on_open_marker(c, line, w)
    st.nOpen = st.nOpen + 1
end

local function on_close(c, line, w)
    st.nClose = st.nClose + 1
    scan_end()
end

local function on_row(c, line, w, raw)
    if st.inBlock == "" then return end

    local plain = trim(tostring(line or ""))
    if plain == "" then return end

    if is_prompt(plain) then
        if st.scanRows > 0 then scan_end() end
        return
    end

    if string.sub(plain, 1, 9) == "{invitem}" then
        plain = string.sub(plain, 10)
    elseif string.sub(plain, 1, 2) == "{/" then
        scan_end()
        return
    elseif string.sub(plain, 1, 1) == "{" then
        return
    end

    st.nRow = st.nRow + 1
    local okp = parse_row(plain, st.inBlock)
    if okp == true then st.scanRows = st.scanRows + 1 end

    -- scans run inside live output and chatter interleaves; only a line
    -- that really was a data row is ours to hide
    if okp == true and st.mine and cfg.gag then return false end
end

local function on_vaultcounts(c, line, w)
    local base = (type(c[0]) == "string") and 0 or 1
    db.vaultUsed = num_or(tostring(c[base] or ""), 0)
    db.vaultCap  = num_or(tostring(c[base + 2] or ""), 0)
    db.haveVault = true
    render()
    if cfg.gag then return false end
end

-- keyring and vault answer sleep with a dream; skip to the next scan
local function on_dream(c, line, w)
    if st.inBlock == "key" or st.inBlock == "vault" then
        scan_end()
    end
end

local function refresh(withVault)
    block_release()
    st.scanQ = {
        { cmd = "eqdata",       where = "eq"  },
        { cmd = "invdata",      where = "inv" },
        { cmd = "keyring data", where = "key" },
    }
    if withVault == true then
        table.insert(st.scanQ, { cmd = "vault data", where = "vault" })
    end
    next_scan()
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
    -- the id pass removes and re-wears gear, which fires invmon endlessly;
    -- auto-refreshing off our own churn would interleave scans into open
    -- id boxes
    if ids.pending ~= "" or #ids.q > 0 then return end
    if qol.watchWear == true then
        local plain = tostring(line or "")
        local payload = ""
        local p = pfind(plain, "}")
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
    addTrigger("^\\{eqdata\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    addTrigger("^\\{invdata\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    addTrigger("^\\{keyring\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    addTrigger("^\\{vault\\}", on_open_marker, { type = "regex", keepEvaluating = true })
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
            if view ~= "best" and view ~= "use" and view ~= "menu" then
                view = "list"
            end
        elseif action == "item" then
            local serial = trim(tostring(data.data or ""))
            if serial ~= "" then view = "item:" .. serial end
        elseif action == "cmd" then
            --[[
                Every menu and item button routes here: the button carries
                the command text it would have been typed as, and runs the
                one implementation. A button that drifts from its command
                is impossible when they are the same call.
            ]]
            local text = trim(tostring(data.data or ""))
            if text ~= "" and type(do_cmd) == "function" then do_cmd(text) end
            return

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

        The body is assigned to do_cmd (declared at file scope) so the panel's
        buttons run the SAME path as typed commands rather than a parallel
        implementation that drifts. Assignment, not declaration — a second
        file-scope local would cost a slot and risk 9b.
    ]]
    do_cmd = function(args)
        local a = args
        if type(a) == "table" then a = table.concat(a, " ") end
        a = trim(tostring(a or ""))
        local low = string.lower(a)

        if low == "" or low == "show" then
            -- also the panel's "back" button, so it must leave a detail view
            view = "list"
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
            -- version first: chasing a bug that was already fixed on disk
            -- costs rounds you cannot get back (MUDFORGE-NOTES, verbatim)
            utilprint(TAG .. "aw-inv v" .. plugin.version
                .. " | find base adj " .. FIND_ADJ)
            local nItems = 0
            for _, _x in pairs(db.items) do nItems = nItems + 1 end
            local nStats = 0
            for _, _x in pairs(ids.stats) do nStats = nStats + 1 end
            utilprint(TAG .. "sent " .. st.nSent .. " | opens " .. st.nOpen
                .. " | closes " .. st.nClose .. " | rows " .. st.nRow
                .. " | parsed " .. st.nParsed)
            utilprint(TAG .. "items " .. nItems .. " | id records " .. nStats
                .. " | inBlock '" .. st.inBlock .. "' | scanQ " .. #st.scanQ)
            utilprint(TAG .. "gag " .. tostring(cfg.gag) .. " | auto "
                .. tostring(cfg.auto) .. " | id pending '" .. ids.pending
                .. "' | id queue " .. #ids.q)
            if st.rej ~= "" then
                utilprint(TAG .. "last rejected row: " .. st.rej)
            end

            --[[
                Self-test: parse a canned row (fake serial) right here and
                print what every stage produced. If this parses while live
                rows don't, the fault is state or timing; if it fails, the
                probes name the primitive. One paste, full verdict.
            ]]
            utilprint(TAG .. "probe: find13=" .. tostring(pfind("a,b", ","))
                .. " tonum='" .. tostring(tonumber("13")) .. "'"
                .. " trim='" .. trim("  13  ") .. "'"
                .. " numor=" .. tostring(num_or("13", -99))
                .. " sub=" .. string.sub("abcdef", 3, 4))
            st.rej = ""
            local okST = parse_row("999999001,M,a stone key,10,13,0,-1,562227", "selftest")
            local rec = db.items["999999001"]
            if okST == true and type(rec) == "table" then
                utilprint(TAG .. "selftest PARSED: name='" .. tostring(rec.name)
                    .. "' level=" .. tostring(rec.level)
                    .. " type=" .. tostring(rec.itype)
                    .. " wear=" .. tostring(rec.wear)
                    .. " timer=" .. tostring(rec.timer))
            else
                utilprint(TAGR .. "selftest FAILED: " .. st.rej)
            end
            db.items["999999001"] = nil

        elseif low == "refresh" then
            refresh(false)
            utilprint(TAG .. "rescanning eq, inventory, containers and keyring...")
            showWidget(widget)

        elseif string.sub(low, 1, 5) == "find " or low == "find" then
            -- the query language against the index, printed, not filtered
            local q = trim(string.sub(a, 5))
            local hits = q_find(q)
            utilprint(TAG .. #hits .. " match(es) for '" .. q .. "':")
            local i = 1
            while i <= #hits and i <= 40 do
                local it = db.items[hits[i]]
                local sc = score_of(hits[i])
                utilprint("$w  " .. hits[i] .. "  $C" .. it.name
                    .. "$w  L" .. it.level .. " " .. it.where
                    .. (sc ~= nil and sc > 0 and ("  " .. sc .. "pt") or ""))
                i = i + 1
            end
            if #hits > 40 then utilprint("$K  ...and " .. (#hits - 40) .. " more.$w") end

        elseif string.sub(low, 1, 4) == "get " then
            -- pull every match into main inventory, wherever it sits
            local hits = q_find(trim(string.sub(a, 4)))
            local n = 0
            for _, serial in ipairs(hits) do
                local it = db.items[serial]
                if it.where == "eq" then
                    send("remove " .. serial); n = n + 1
                elseif pfind(it.where, "c:") == 1 then
                    send("get " .. serial .. " " .. string.sub(it.where, 3)); n = n + 1
                end
            end
            utilprint(TAG .. n .. " item(s) moved to inventory.")
            if n > 0 then addTimer(900, function() refresh(false) end) end

        elseif string.sub(low, 1, 4) == "put " then
            --[[
                put <container serial> <query> — the container first, as
                dinv has it, so the query keeps the rest of the line.
            ]]
            local rest = trim(string.sub(a, 4))
            local sp = pfind(rest, " ")
            local con = (sp ~= nil) and string.sub(rest, 1, sp - 1) or rest
            local q = (sp ~= nil) and trim(string.sub(rest, sp + 1)) or ""
            if type(db.items[con]) ~= "table" or q == "" then
                utilprint(TAGR .. "usage: /awinv put <container serial> <query>")
            else
                local n = 0
                for _, serial in ipairs(q_find(q)) do
                    if serial ~= con and db.items[serial].where ~= "c:" .. con then
                        if db.items[serial].where == "eq" then send("remove " .. serial) end
                        send("put " .. serial .. " " .. con)
                        n = n + 1
                    end
                end
                utilprint(TAG .. n .. " item(s) into " .. db.items[con].name .. ".")
                if n > 0 then addTimer(900, function() refresh(false) end) end
            end

        elseif string.sub(low, 1, 8) == "keyword " then
            --[[
                Player-invented keywords, stored beside the identify record
                so they survive the item leaving and coming back. Queryable
                as 'kw <word>'.
            ]]
            local rest = trim(string.sub(a, 8))
            local op = ""
            if string.sub(string.lower(rest), 1, 4) == "add " then
                op = "add"; rest = trim(string.sub(rest, 4))
            elseif string.sub(string.lower(rest), 1, 3) == "rm " then
                op = "rm"; rest = trim(string.sub(rest, 3))
            end
            local sp = pfind(rest, " ")
            local word = (sp ~= nil) and string.lower(string.sub(rest, 1, sp - 1)) or ""
            local q = (sp ~= nil) and trim(string.sub(rest, sp + 1)) or ""

            if op == "" or word == "" or q == "" then
                utilprint(TAGR .. "usage: /awinv keyword add|rm <word> <query>")
            else
                local n = 0
                for _, serial in ipairs(q_find(q)) do
                    if type(ids.stats[serial]) ~= "table" then ids.stats[serial] = {} end
                    local cur = tostring(ids.stats[serial].tags or "")
                    local has = pfind(" " .. cur .. " ", " " .. word .. " ") ~= nil
                    if op == "add" and not has then
                        ids.stats[serial].tags = trim(cur .. " " .. word)
                        n = n + 1
                    elseif op == "rm" and has then
                        local outw = {}
                        for wd in string.gmatch(cur, "%S+") do
                            if wd ~= word then table.insert(outw, wd) end
                        end
                        ids.stats[serial].tags = table.concat(outw, " ")
                        n = n + 1
                    end
                end
                save_stats()
                render()
                utilprint(TAG .. "'" .. word .. "' " .. op .. " on " .. n .. " item(s). "
                    .. "Query them with: kw " .. word)
            end

        elseif string.sub(low, 1, 7) == "forget " then
            -- drop what we know so the next id re-reads it
            local hits = q_find(trim(string.sub(a, 7)))
            for _, serial in ipairs(hits) do ids.stats[serial] = nil end
            save_stats()
            render()
            utilprint(TAG .. "forgot the stats of " .. #hits
                .. " item(s); 'id missing' re-reads them.")

        elseif string.sub(low, 1, 3) == "do " then
            --[[
                Send a MUD command verbatim and rescan after it. The panel's
                wear/remove/drop/get buttons come through here: the item
                table is only true until something moves, so the action and
                the refresh belong together.
            ]]
            local mud = trim(string.sub(a, 3))
            if mud ~= "" then
                send(mud)
                addTimer(600, function() refresh(false) end)
            end

        elseif low == "bags" then
            --[[
                What the scan believes about containers, and why none were
                found if none were. A bag lives in inventory or is worn; a
                scan can only see what invdata/eqdata listed.
            ]]
            local cons = container_list()
            utilprint(TAG .. #cons .. " container(s) known.")
            for _, it in ipairs(cons) do
                utilprint("$w  " .. it.serial .. "  $C" .. it.name
                    .. "$w  (" .. it.where .. ")  "
                    .. count_where("c:" .. it.serial) .. " item(s) inside")
            end
            if #cons == 0 then
                utilprint("$K  Nothing of type Container was listed by 'invdata' "
                    .. "or 'eqdata'. Bags are found from your main inventory or "
                    .. "worn gear - if yours live somewhere else, run "
                    .. "'/awinv scan <serial>' on one to index it directly.$w")
                utilprint("$K  Carried right now: " .. count_where("inv")
                    .. " item(s). If that is 0 but you are carrying bags, "
                    .. "paste what 'i' shows and I'll fix the detection.$w")
            end

        elseif string.sub(low, 1, 5) == "scan " then
            -- index one container by serial, without a whole refresh
            local serial = trim(string.sub(low, 5))
            if type(db.items[serial]) ~= "table" then
                utilprint(TAGR .. "serial " .. serial .. " isn't in the index.")
            else
                table.insert(st.scanQ, {
                    cmd = "invdata " .. serial, where = "c:" .. serial,
                })
                next_scan()
                utilprint(TAG .. "scanning container " .. serial .. "...")
            end

        elseif low == "build" then
            -- dinv's 'build confirm': full scan, then id everything unknown
            st.buildAfter = true
            refresh(false)
            utilprint(TAG .. "building: full rescan, then identifying every "
                .. "unknown item. Stay put; 'id stop' halts the id pass.")
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
                local p1 = pfind(restLow, " ")
                local tail = trim(string.sub(restLow, p1 + 1))
                local p2 = pfind(tail, " ")
                local rest2 = (p2 ~= nil) and trim(string.sub(tail, p2 + 1)) or ""
                local p3 = pfind(rest2, " ")
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
            --[[
                dinv's portal mode: remember what the hold slot had, take
                the portal out, hold, enter — then put things back a beat
                LATER rather than in the same burst. dinv splits it for a
                real reason: portal landings get camped, and swapping back
                must not block you running out of the room.
            ]]
            local q = trim(string.sub(a, 3))
            local serial = q
            if tonumber(q) == nil then
                local hits = q_find(q .. " type portal")
                if #hits == 0 then hits = q_find(q) end
                serial = (hits[1] ~= nil) and hits[1] or ""
            end

            local it = db.items[serial]
            if type(it) ~= "table" then
                utilprint(TAGR .. "no portal matching '" .. q .. "' in the index.")
            else
                local held = ""
                for s2, i2 in pairs(db.items) do
                    if type(i2) == "table" and i2.where == "eq" and i2.itype ~= 11
                        and slot_of(s2) == "hold" then
                        held = s2
                    end
                end
                local home = ""
                if pfind(it.where, "c:") == 1 then home = string.sub(it.where, 3) end

                if held ~= "" then send("remove " .. held) end
                if home ~= "" then send("get " .. serial .. " " .. home) end
                send("hold " .. serial)
                send("enter")
                utilprint(TAG .. "entering " .. it.name .. "...")

                addTimer(1200, function()
                    if home ~= "" then send("put " .. serial .. " " .. home) end
                    if held ~= "" then send("wear " .. held) end
                    addTimer(600, function() refresh(false) end)
                end)
            end

        elseif string.sub(low, 1, 5) == "pass " then
            --[[
                dinv's pass: an area wants a non-key item in your hands for
                a moment. Take it out, hold it there, put it back. Meant to
                be fired from a mapper custom exit.
            ]]
            local rest = trim(string.sub(a, 5))
            local sp = pfind(rest, " ")
            local who = (sp ~= nil) and string.sub(rest, 1, sp - 1) or rest
            local secs = (sp ~= nil) and tonumber(trim(string.sub(rest, sp + 1))) or 10
            if secs == nil or secs < 1 then secs = 10 end

            local serial = who
            if tonumber(who) == nil then
                local hits = q_find(who)
                serial = (hits[1] ~= nil) and hits[1] or ""
            end
            local it = db.items[serial]
            if type(it) ~= "table" then
                utilprint(TAGR .. "no item matching '" .. who .. "' in the index.")
            else
                local home = ""
                if pfind(it.where, "c:") == 1 then home = string.sub(it.where, 3) end
                if home ~= "" then send("get " .. serial .. " " .. home) end
                utilprint(TAG .. it.name .. " in hand for " .. secs .. "s.")
                addTimer(secs * 1000, function()
                    if home ~= "" then
                        send("put " .. serial .. " " .. home)
                    end
                end)
            end

        elseif string.sub(low, 1, 5) == "regen" then
            local what = trim(string.sub(low, 6))
            if what == "auto" or (what == "" and qol.regen == "") then
                --[[
                    dinv never asked which ring: it searched the identify
                    data for an item whose Affect Mods carry regeneration
                    and that you are high enough to wear. Now that we parse
                    Affect Mods, so can we.
                ]]
                local lvl = char_level()
                local pick, pickLvl = "", -1
                for serial, r in pairs(ids.stats) do
                    if type(r) == "table" and r.aff_regeneration == 1 then
                        local it = db.items[serial]
                        local rl = tonumber(r.level)
                        if rl == nil then rl = 0 end
                        if type(it) == "table" and rl <= lvl and rl > pickLvl then
                            pick, pickLvl = serial, rl
                        end
                    end
                end
                if pick == "" then
                    utilprint(TAGR .. "no identified item with a regeneration "
                        .. "affect found - run '/awinv build' first, or set one "
                        .. "by hand: /awinv regen <serial>")
                else
                    qol.regen = pick
                    save_qol()
                    utilprint(TAG .. "regen ring: " .. db.items[pick].name
                        .. " (" .. pick .. ", level " .. pickLvl
                        .. ") - worn when you sleep.")
                end
            elseif what == "off" then
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
            utilprint("$w  /awinv build               dinv's build: rescan, then id everything")
            utilprint("$w  /awinv vault               rescan with the vault too")
            utilprint("$w  /awinv search <text>       filter the panel")
            utilprint("$w  /awinv find <query>        query language: 'type weapon minlevel 100'")
            utilprint("$w  /awinv get <query>         bring matches to your inventory")
            utilprint("$w  /awinv put <bag> <query>   stow matches in a container")
            utilprint("$w  /awinv keyword add|rm <word> <query>   your own tags, query with 'kw <word>'")
            utilprint("$w  /awinv forget <query>      drop stored stats so they re-identify")
            utilprint("$w  /awinv pass <item> <secs>  hold an area pass briefly")
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
    end

    registerCommand("awinv", do_cmd,
        "inventory, worn, keyring and vault in one searchable panel")
end

function cleanup()
    if rowTrig ~= nil then pcall(removeTrigger, rowTrig); rowTrig = nil end
    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer); st.blockTimer = nil end
    if st.pokeTimer ~= nil then pcall(removeTimer, st.pokeTimer); st.pokeTimer = nil end
    if ids.timer ~= nil then pcall(removeTimer, ids.timer); ids.timer = nil end
    if ids.guard ~= nil then pcall(removeTimer, ids.guard); ids.guard = nil end
    if qol.watchTimer ~= nil then pcall(removeTimer, qol.watchTimer); qol.watchTimer = nil end
end
