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
    version     = "3.4.0",
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
    -- space-separated serials to leave alone: not scanned, not ranked,
    -- not moved. Declared, because an unset field here is undefined and
    -- undefined is truthy on this runtime.
    ignored = "",
    -- the Weapons wish waives weapon-skill gating; we can't read the wish
    -- list, so '/awinv weapon wish' toggles it by hand
    weapwish = false,
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
    buf      = {},       -- set of serials this scan reported, for reconciling
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

-- every trigger id this plugin registers, so cleanup can release them.
-- A stranded catch-all with omitFromOutput swallows the whole session.
local trigs = {}

local function trig(pattern, fn, opts)
    local id = addTrigger(pattern, fn, opts)
    table.insert(trigs, id)
    return id
end

--[[
    A delayed call that survives a disconnect. addTimer refuses while the
    session is down — it returns "" and never fires — so anything that must
    run at the login prompt or across a reconnect goes through setTimeout,
    which does not care. Falls back to addTimer if this build lacks it.
]]
local function later(ms, fn)
    local ok, id = pcall(function() return setTimeout(fn, ms) end)
    if ok and id ~= nil and id ~= "" then return id end
    return addTimer(ms, fn)
end

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
--[[
    Stat ceilings, dinv's inv.statBonus — and the reason its set builder is
    more than "pick the biggest number".

    Aardwolf caps each stat at roughly your level, and your spellups
    already supply part of that. Equipment can only usefully carry the
    REMAINDER: ceiling = clamp(level - 10*tier, 25, 200) - spellBonus.
    Weighting +int on an item whose int you already max is wasted budget,
    which is exactly what our scoring did until now.

    'stats' reports the Spells Bonus row; we keep a per-level average of
    it the way dinv does (50/50 with the previous reading, so it converges
    as you play). Until a reading exists, SEED interpolates dinv's own
    top-end estimate down to zero, which is coarse but honest and stops
    being used the moment you run 'stats' once.
]]
local sb = {
    spell = {},          -- level -> "str,int,wis,dex,con,luck" as text
    have  = false,
    asked = false,
}

local SEED_TOP = { str = 70, intel = 86, wis = 70, dex = 105, con = 90, luck = 65 }
local STAT6 = { "str", "intel", "wis", "dex", "con", "luck" }

-- saved outfits: name -> comma-separated serials that were worn
local snaps = {}

-- container serial -> a query; anything matching gets filed there by
-- '/awinv organize'. dinv's inv.organize, minus the sweep-everything
-- default, because filing worn gear by accident is a bad afternoon.
local rules = {}

--[[
    Consumable categories: a name you invent ("heal", "fly") mapped to the
    shop keyword you buy by. dinv also stored the shop room and bought via
    the mapper; we keep the naming and the level-aware pick, and leave the
    running-to-shops to you.
]]
local cons = {}

--[[
    Shop-backed consumable categories, dinv's real consume module. dinv has
    no built-in shop database: every entry is captured by standing AT the
    shopkeeper and running 'consume shop <cat> <keyword>' — the room comes
    from GMCP, the item's level and full name from 'appraise <keyword>'.
    Entries per category stay sorted ascending by level.

    buy travels there and restocks the best one you can use; small/big
    drink the lowest/highest usable owned instance (dinv's names).
]]
local cshop = {
    tab     = {},        -- category -> array of { lv, kw, room, full }
    cat     = "",        -- capture in flight: category
    kw      = "",        -- capture in flight: keyword
    buyCat  = "",        -- purchase in flight ("" = idle)
    buyKw   = "",
    buyN    = 0,
    buyRoom = 0,
    poll    = nil,       -- arrival poll timer
    waited  = 0,         -- ms spent polling
}

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
    -- tonumber at each step: `v == nil` is false for undefined, so the
    -- string-key fallbacks below never ran. This is the most load-bearing
    -- helper in the file; if it returns nil, every parser stops.
    local v = tonumber(q[0])
    if v == nil then v = tonumber(q["0"]) end
    if v == nil then v = tonumber(q[1]) end
    if v == nil then v = tonumber(q["1"]) end
    return v
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
    --[[
        `t[name] ~= nil` looks like the obvious guard and is the bug: a key
        dot access cannot reach reads as `undefined`, and `undefined == nil`
        is FALSE here, so it returned undefined and the pairs walk below —
        the entire point of this helper — was dead code. Test the TYPE.
    ]]
    local direct = t[name]
    if type(direct) == "string" or type(direct) == "number"
        or type(direct) == "boolean" or type(direct) == "table" then
        return direct
    end
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
    st.buf[serial] = true
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

--[[
    Write the item table out. The guarded save_db below is what callers use;
    this one is for the two paths that empty it deliberately.
]]
local function save_db_force()
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

--[[
    Refuse to replace a populated store with an empty one. Every legitimate
    way to empty the table saves through save_db_force, so an empty save
    arriving here is a symptom — a scan that answered nothing, a disconnect
    mid-refresh — and overwriting on it is how a session's work disappears.
]]
local function save_db()
    local n = 0
    for _, it in pairs(db.items) do
        if type(it) == "table" then n = n + 1 end
    end
    if n == 0 then
        local had = loadTable("aw_inv_items")
        if type(had) == "table" and type(had.blob) == "string" and had.blob ~= "" then
            utilprint(TAGR .. "not saving an empty inventory over the stored "
                .. "one. '/awinv refresh' to rebuild, '/awinv clear' to really "
                .. "discard it.")
            return
        end
    end
    save_db_force()
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
        fpx = cfg.fpx, fov = cfg.fov, ignored = cfg.ignored,
        weapwish = cfg.weapwish,
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

local function save_rules()
    local out = {}
    for con, q in pairs(rules) do
        if type(q) == "string" and q ~= "" then
            table.insert(out, tostring(con) .. "=" .. q)
        end
    end
    saveTable("aw_inv_rules", { blob = table.concat(out, ";") })
end

local function load_rules()
    local saved = loadTable("aw_inv_rules")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end
    for pair in string.gmatch(saved.blob, "[^;]+") do
        local eq = pfind(pair, "=")
        if eq ~= nil and eq > 1 then
            rules[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1)
        end
    end
end

local function save_cons()
    local out = {}
    for name, kw in pairs(cons) do
        if type(kw) == "string" and kw ~= "" then
            table.insert(out, tostring(name) .. "=" .. kw)
        end
    end
    saveTable("aw_inv_cons", { blob = table.concat(out, ";") })
end

local function load_cons()
    local saved = loadTable("aw_inv_cons")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end
    for pair in string.gmatch(saved.blob, "[^;]+") do
        local eq = pfind(pair, "=")
        if eq ~= nil and eq > 1 then
            cons[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1)
        end
    end
end

-- shop categories ride one escaped blob: cat|level|keyword|room|fullname
-- rows joined by ";". Save writes "-" for a deliberately emptied table so
-- the seed rows do not resurrect on the next load.
local function save_cshop()
    local out = {}
    for cat, list in pairs(cshop.tab) do
        if type(list) == "table" then
            for _, e in ipairs(list) do
                local kw2 = string.gsub(tostring(e.kw or ""), "[|;]", " ")
                local fu2 = string.gsub(tostring(e.full or ""), "[|;]", " ")
                table.insert(out, cat .. "|" .. tostring(e.lv) .. "|" .. kw2
                    .. "|" .. tostring(e.room) .. "|" .. fu2)
            end
        end
    end
    local blob = table.concat(out, ";")
    if blob == "" then blob = "-" end
    saveTable("aw_inv_cshop", { blob = blob })
end

local function cshop_add(cat, lv, kw, room, full)
    if type(cshop.tab[cat]) ~= "table" then cshop.tab[cat] = {} end
    local list = cshop.tab[cat]
    for _, e in ipairs(list) do
        if e.lv == lv and e.kw == kw then
            e.room, e.full = room, full
            return
        end
    end
    table.insert(list, { lv = lv, kw = kw, room = room, full = full })
    table.sort(list, function(x, y) return x.lv < y.lv end)
end

local function load_cshop()
    local saved = loadTable("aw_inv_cshop")
    local blob = ""
    if type(saved) == "table" and type(saved.blob) == "string" then
        blob = saved.blob
    end
    if blob == "" then
        -- never saved: seed with dinv's Aylor potion shop basics
        -- (room 32476, 'runto potion' — dinv's own reset() table)
        cshop_add("heal", 1, "light relief", 32476, "(!(Light Relief)!)")
        cshop_add("heal", 20, "serious relief", 32476, "(!(Serious Relief)!)")
        cshop_add("mana", 1, "lotus rush", 32476, "(!(Lotus Rush)!)")
        cshop_add("fly", 1, "griff", 32476, "(!(Griffon's Blood)!)")
        cshop_add("sight", 1, "wolf", 32476, "")
        return
    end
    if blob == "-" then return end
    for row in string.gmatch(blob, "[^;]+") do
        local f = {}
        for part in string.gmatch(row, "[^|]+") do table.insert(f, part) end
        -- full may be empty, which drops the 5th field from gmatch
        local lv = tonumber(f[2])
        local room = tonumber(f[4])
        if type(f[1]) == "string" and lv ~= nil and type(f[3]) == "string" then
            cshop_add(trim(f[1]), lv, trim(f[3]),
                (room ~= nil) and room or 0,
                (type(f[5]) == "string") and trim(f[5]) or "")
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
    if key == "kw" or key == "tag" then
        local tg = r.tags
        if type(tg) ~= "string" then return "" end
        return tg
    end

    -- identify fields and stat mods share the record, so one lookup covers
    -- wearable/material/worth/weight/damtype/... and str/int/hit/dam/...
    local v = r[key]
    if type(v) == "string" or type(v) == "number" then return v end

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
        if type(col) == "string" and type(ids.rec) == "table" then
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
        while #value > 0 and string.sub(value, #value, #value) == "|" do
            value = trim(string.sub(value, 1, #value - 1))
        end
        local key = ID_FIELDS[trim(label)]
        if type(key) == "string" and value ~= "" then
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

-- forward-declared: id_store schedules the next send; the shop-capture
-- handler lives with the consume machinery far below
local id_next = nil
local cshop_capture = nil

local function id_store()
    local r = ids.rec
    ids.rec = nil
    ids.modBlock = ""
    id_guard_off()
    id_trigs(false)

    local serial = ids.pending
    ids.pending = ""

    --[[
        An appraise at a shopkeeper prints the same box an id does, so the
        capture rides this machinery under a sentinel serial. It must not
        reach the stats store — the item isn't ours.
    ]]
    if serial == "@shop" then
        if type(cshop_capture) == "function" then cshop_capture(r) end
        return
    end

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
    ids.timer = later(700, function()
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
    ids.guard = later(8000, function()
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

            if FUNGIBLE[it.itype] == true and which ~= "all"
                and seenName[nm] == true then
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

---
-- stat ceilings
---

local function char_tier()
    local n = tonumber(gfield(getGMCPData("char.base"), "tier"))
    if n == nil or n < 0 then return 0 end
    return math.floor(n)
end

local function char_align()
    local n = tonumber(gfield(getGMCPData("char.status"), "align"))
    if n == nil then n = tonumber(gfield(getGMCPData("char.base"), "align")) end
    if n == nil then return 0 end
    return n
end

-- the spell bonus for a stat at a level: measured if we have it, else the
-- seed interpolated from zero at level 1 to dinv's estimate at 211
local function spell_bonus(level, stat)
    local rec = sb.spell[level]
    if type(rec) == "string" and rec ~= "" then
        local i = 1
        for part in string.gmatch(rec, "[^,]+") do
            if STAT6[i] == stat then
                local v = tonumber(part)
                if v ~= nil then return v end
            end
            i = i + 1
        end
    end
    local top = SEED_TOP[stat]
    if top == nil then return 0 end
    local lv = level
    if lv > 211 then lv = 211 end
    if lv < 1 then lv = 1 end
    return math.floor(top * lv / 211)
end

-- how much of a stat equipment can still usefully carry at this level
local function stat_ceiling(level, stat)
    local base = level - 10 * char_tier()
    if base < 25 then base = 25 end
    if base > 200 then base = 200 end
    local room = base - spell_bonus(level, stat)
    if room < 0 then room = 0 end
    return room
end

local function save_sb()
    local rows = {}
    for lv, txt in pairs(sb.spell) do
        table.insert(rows, tostring(lv) .. "=" .. tostring(txt))
    end
    saveTable("aw_inv_sb", { blob = table.concat(rows, ";") })
end

local function load_sb()
    local saved = loadTable("aw_inv_sb")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end
    for pair in string.gmatch(saved.blob, "[^;]+") do
        local eq = pfind(pair, "=")
        if eq ~= nil and eq > 1 then
            local lv = tonumber(string.sub(pair, 1, eq - 1))
            if lv ~= nil then
                sb.spell[math.floor(lv)] = string.sub(pair, eq + 1)
                sb.have = true
            end
        end
    end
end

--[[
    The Spells Bonus row of 'stats':
        Spells Bonus  :   12   40   38   10   20   15
    columns str int wis dex con luck. Averaged 50/50 with whatever we had
    for this level, dinv's own convergence.
]]
local function on_spells_bonus(c, line, w)
    local nums = {}
    for n in string.gmatch(tostring(line or ""), "%d+") do
        table.insert(nums, tonumber(n))
    end
    if #nums < 6 then return end

    local lv = char_level()
    local prev = sb.spell[lv]
    local out = {}
    local i = 1
    while i <= 6 do
        local v = nums[i]
        if type(prev) == "string" then
            local j, old = 1, nil
            for part in string.gmatch(prev, "[^,]+") do
                if j == i then old = tonumber(part) end
                j = j + 1
            end
            if old ~= nil then v = (v + old) / 2 end
        end
        table.insert(out, string.format("%.1f", v))
        i = i + 1
    end

    sb.spell[lv] = table.concat(out, ",")
    sb.have = true
    save_sb()

    if sb.asked == true then
        sb.asked = false
        utilprint(TAG .. "stat ceilings learned for level " .. lv
            .. " - gear is now scored against the room your spellups leave.")
        if render ~= nil then render() end
    end
end


--[[
    The weights in force at a level.

    dinv's priorities are level-BANDED, and the deep dive calls that the
    killer feature: sanctuary is worth 50 at level 1 because you cannot
    cast it yet, and 5 by level 201 when every spellup has it; dual wield
    is worth 20 until you learn the skill and 0 after. A flat table cannot
    say that.

    A band is stored as a plain weight table under the key "<name>@<min>",
    so the flat form is just a profile with one band starting at 1 and
    nothing else changes on disk.
]]
local function weights_at(name, level)
    local best, bestMin = nil, -1
    local prefix = name .. "@"
    for k, ws in pairs(prof.sets) do
        if type(ws) == "table" then
            if k == name and bestMin < 0 then
                best, bestMin = ws, 0
            elseif pfind(k, prefix) == 1 then
                local lo = tonumber(string.sub(k, #prefix + 1))
                if lo ~= nil and lo <= level and lo > bestMin then
                    best, bestMin = ws, lo
                end
            end
        end
    end
    return best
end

local function score_at(serial, level)
    local r = ids.stats[serial]
    if type(r) ~= "table" then return nil end
    local ws = weights_at(prof.active, level)
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

    --[[
        max<stat> pays a flat bonus for reaching the level's ceiling —
        dinv's way of valuing a piece that finally caps a stat over one
        that merely adds to it.
    ]]
    for _, stat in ipairs(STAT6) do
        local bonus = tonumber(ws["max" .. stat])
        if bonus ~= nil and bonus > 0 then
            local have = tonumber(r[stat])
            if have ~= nil and have >= stat_ceiling(level, stat) then
                total = total + bonus
            end
        end
    end

    local wp = tonumber(ws.all_phys)
    if wp ~= nil and wp > 0 then
        for _, k in ipairs(PHYS_RES) do
            local v = tonumber(r[k])
            if v ~= nil and tonumber(ws[k]) == nil then
                total = total + wp * v / 3
            end
        end
    end
    local wm = tonumber(ws.all_magic)
    if wm ~= nil and wm > 0 then
        for _, k in ipairs(MAG_RES) do
            local v = tonumber(r[k])
            if v ~= nil and tonumber(ws[k]) == nil then
                total = total + wm * v / 17
            end
        end
    end

    return tonumber(string.format("%.2f", total))
end

-- is this slot switched off for the active profile? (~slot = 1)
local function slot_banned(slot, level)
    local ws = weights_at(prof.active, level)
    if type(ws) ~= "table" then return false end
    local v = tonumber(ws["~" .. slot])
    return v ~= nil and v ~= 0
end

-- the score at your current level; every caller that has no particular
-- level in mind means "now"
local function score_of(serial)
    return score_at(serial, char_level())
end

-- the box says "Wearable : finger"; anything unlisted gets its own slot
local function slot_of(serial)
    local r = ids.stats[serial]
    if type(r) ~= "table" then return "" end
    -- `r.wearable or ""` never fires on undefined, and undefined reaches a
    -- string field as the TEXT "undefined" — so unwearable things claimed a
    -- slot of that name and crowded the rankings.
    local raw = r.wearable
    if type(raw) ~= "string" then return "" end
    local wearable = string.lower(trim(raw))
    if wearable == "" or wearable == "undefined" then return "" end
    -- first word: "wield (weapon)" and friends carry trailing commentary
    local p = pfind(wearable, " ")
    if p ~= nil then wearable = string.sub(wearable, 1, p - 1) end
    return wearable
end

---
-- eligibility: what this character can actually wear
---

--[[
    dinv's dbot.ability table, verbatim: the level at which each class
    gains each weapon skill. An absent class can never use that type.
    char.base.classes over GMCP is a digit string, one digit per class
    the character has remorted through, and any of them counts.
]]
local ABILITY_CLASS = {
    ["0"] = "mag", ["1"] = "cle", ["2"] = "thi", ["3"] = "war",
    ["4"] = "ran", ["5"] = "pal", ["6"] = "psi",
}
local ABILITY = {
    dualwield = { mag = 201, cle = 201, thi = 29, war = 32, ran = 25, pal = 35, psi = 201 },
    axe       = { war = 2, ran = 1 },
    bow       = { ran = 1 },
    dagger    = { mag = 1, thi = 1, war = 4, ran = 5, psi = 10 },
    flail     = { cle = 5, war = 7, pal = 1, psi = 11 },
    hammer    = { war = 1 },
    mace      = { cle = 1, thi = 10, war = 5, pal = 6, psi = 5 },
    polearm   = { war = 7, ran = 13, pal = 10 },
    spear     = { mag = 1, war = 10, ran = 11, pal = 11 },
    sword     = { war = 1, ran = 2, pal = 2 },
    whip      = { mag = 5, cle = 10, thi = 3, war = 9, ran = 18, pal = 1, psi = 1 },
    exotic    = { mag = 1, cle = 1, thi = 1, war = 1, ran = 1, pal = 1, psi = 1 },
}

--[[
    Does any of the character's classes have this skill at this level?
    Unknown skill names and silent GMCP both fail OPEN — a wrong "yes"
    costs one refused wield; a wrong "no" silently hides gear.
]]
local function ability_at(name, level)
    local tab = ABILITY[name]
    if type(tab) ~= "table" then return true end
    local classes = tostring(gfield(getGMCPData("char.base"), "classes") or "")
    if classes == "" or classes == "null" or classes == "undefined" then
        return true
    end
    for d in string.gmatch(classes, "[0-6]") do
        local cn = ABILITY_CLASS[d]
        if type(cn) == "string" then
            local lv = tab[cn]
            if type(lv) == "number" and level >= lv then return true end
        end
    end
    return false
end

--[[
    dinv rejects gear the character cannot use before ranking it, so the
    list never recommends something you would be refused. Alignment
    restrictions and heroonly are carried in the identify Flags field.
]]
local function usable(serial, level)
    local it = db.items[serial]
    if type(it) ~= "table" then return false end
    local r = ids.stats[serial]
    if type(r) ~= "table" then return false end

    local lv = tonumber(r.level)
    if lv == nil then lv = it.level end
    if lv == nil then lv = 0 end
    if lv > level then return false end

    local flags = string.lower(tostring(r.flags or "") .. " " .. tostring(it.flags or ""))

    if pfind(flags, "heroonly") ~= nil then
        if level - 10 * char_tier() < 200 then return false end
    end

    local al = char_align()
    if pfind(flags, "anti-good") ~= nil and al >= 875 then return false end
    if pfind(flags, "anti-evil") ~= nil and al <= -875 then return false end
    if pfind(flags, "anti-neutral") ~= nil and al > -875 and al < 875 then
        return false
    end

    if cfg.ignored ~= "" then
        if pfind(" " .. cfg.ignored .. " ", " " .. serial .. " ") ~= nil then
            return false
        end
        -- an item inside an ignored bag is ignored too
        if pfind(it.where, "c:") == 1 then
            local con = string.sub(it.where, 3)
            if pfind(" " .. cfg.ignored .. " ", " " .. con .. " ") ~= nil then
                return false
            end
        end
    end

    --[[
        A weapon whose type no class of yours can wield is not gear, it
        is luggage — dinv gates on the ability table before ranking. The
        Weapons wish waives every weapon skill; we can't see the wish
        list, so '/awinv weapon wish' records that you have it. A weapon
        with no Weapon Type field is never gated (dinv's rule too).
    ]]
    if cfg.weapwish ~= true and slot_of(serial) == "wield" then
        local wt = r.weapon_type
        if type(wt) == "string" and wt ~= "" then
            if not ability_at(string.lower(trim(wt)), level) then
                return false
            end
        end
    end
    return true
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
            if slot ~= "" and usable(serial, level) then
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
        --[[
            Ties are broken by serial so the same ring lands in the same
            finger every rebuild. dinv normalises the multi-slot groups for
            exactly this reason: without it a rebuild reshuffles equal
            items between lfinger and rfinger and 'set wear' generates
            pointless swaps.
        ]]
        table.sort(list, function(x, y)
            if x.sc ~= y.sc then return x.sc > y.sc end
            return x.serial < y.serial
        end)
        table.insert(slots, slot)
    end
    table.sort(slots)

    --[[
        The wield slot is not "top two". An offhand needs dual wield —
        the class table at this level, or Aardwolf Gloves of Dexterity
        sitting in the set's own hands pick — and must weigh at most
        half the primary (soldier subclass excepted). It scores with
        offhand_dam in place of ave_dam. And the pair only takes both
        hands if it beats primary + shield + hold, dinv's own decision
        in inv.set.createWithHandicap.
    ]]
    local dualPick = nil
    local wields = per.wield
    if type(wields) == "table" and wields[2] ~= nil then
        local ws2 = weights_at(prof.active, level)
        local banned = false
        if type(ws2) == "table" then
            local b = tonumber(ws2["~second"])
            banned = (b ~= nil and b ~= 0)
        end

        local dual = false
        if not banned then
            dual = ability_at("dualwield", level)
            if not dual and type(per.hands) == "table" and per.hands[1] ~= nil then
                local hit = db.items[per.hands[1].serial]
                if type(hit) == "table" and pfind(string.lower(tostring(hit.name or "")),
                        "aardwolf gloves of dexterity") ~= nil then
                    dual = true
                end
            end
        end

        if dual then
            local wAve = 0
            local wOff = 0
            if type(ws2) == "table" then
                local n1 = tonumber(ws2.ave_dam)
                if n1 ~= nil then wAve = n1 end
                local n2 = tonumber(ws2.offhand_dam)
                if n2 ~= nil then wOff = n2 end
            end
            local function off_score(entry)
                local r2 = ids.stats[entry.serial]
                local ad = 0
                if type(r2) == "table" then ad = num_or(r2.ave_dam, 0) end
                return entry.sc - ad * wAve + ad * wOff
            end
            local function weight_of(entry)
                local r2 = ids.stats[entry.serial]
                if type(r2) ~= "table" then return nil end
                local n = tonumber(r2.weight)
                return n
            end
            local sub = string.lower(tostring(gfield(getGMCPData("char.base"),
                "subclass") or ""))

            local bestPair = nil
            local bestSum = 0
            for _, p in ipairs(wields) do
                for _, o in ipairs(wields) do
                    if p.serial ~= o.serial then
                        local okw = (sub == "soldier")
                        if not okw then
                            local pw = weight_of(p)
                            local ow = weight_of(o)
                            okw = (pw ~= nil and ow ~= nil and pw >= ow * 2)
                        end
                        if okw then
                            local osc = off_score(o)
                            if p.sc + osc > bestSum then
                                bestSum = p.sc + osc
                                bestPair = { p = p, o = o, osc = osc }
                            end
                        end
                    end
                end
            end

            if bestPair ~= nil then
                local alt = wields[1].sc
                if type(per.shield) == "table" and per.shield[1] ~= nil then
                    alt = alt + per.shield[1].sc
                end
                if type(per.hold) == "table" and per.hold[1] ~= nil then
                    alt = alt + per.hold[1].sc
                end
                if bestSum > alt then dualPick = bestPair end
            end
        end
    end

    local out = {}
    for _, slot in ipairs(slots) do
        if dualPick ~= nil and (slot == "shield" or slot == "hold") then
            -- both hands are full; nothing to emit for these slots
        elseif dualPick ~= nil and slot == "wield" then
            local it1 = db.items[dualPick.p.serial]
            table.insert(out, {
                slot = slot, serial = dualPick.p.serial, sc = dualPick.p.sc,
                worn = (type(it1) == "table" and it1.where == "eq"),
                off = false,
            })
            local it2 = db.items[dualPick.o.serial]
            table.insert(out, {
                slot = slot, serial = dualPick.o.serial,
                sc = tonumber(string.format("%.2f", dualPick.osc)),
                worn = (type(it2) == "table" and it2.where == "eq"),
                off = true,
            })
        else
            -- an unlisted slot reads undefined, `cap == nil` is false, and
            -- `1 <= undefined` is false, so the slot silently disappeared
            local cap = tonumber(SLOT_CAP[slot])
            if cap == nil or cap < 1 then cap = 1 end
            -- without a legal pair one weapon is the legal maximum
            if slot == "wield" then cap = 1 end
            local list = per[slot]
            local i = 1
            while i <= cap and i <= #list do
                local e = list[i]
                local it = db.items[e.serial]
                table.insert(out, {
                    slot = slot, serial = e.serial, sc = e.sc,
                    worn = (type(it) == "table" and it.where == "eq"),
                    off = false,
                })
                i = i + 1
            end
        end
    end
    return out
end

---
-- analysis: what you would wear at every level
--
-- dinv computes the optimal set at each of 201 levels and caches it, then
-- answers three questions from that cache: where does this item get used
-- (usage), what would I lose without it (compare), and what changes as I
-- level (analyze display). The expensive part is the sweep, so it runs
-- once and everything else reads the result.
--
-- Ours sweeps in slices behind a timer rather than blocking: this client
-- has no coroutines, and a 201-level loop in one go would freeze the UI.
---

local ana = {
    prof  = "",          -- which profile the cache belongs to
    step  = 10,          -- levels between samples
    at    = 0,           -- sweep cursor
    max   = 0,
    rows  = {},          -- "level|slot" -> serial
    busy  = false,
}

local function ana_key(level, slot)
    return tostring(level) .. "|" .. slot
end

local function ana_clear()
    ana.rows = {}
    ana.prof = ""
    ana.at = 0
    ana.busy = false
end

local function ana_step()
    if ana.busy ~= true then return end

    -- one slice per tick keeps the client responsive on a big wardrobe
    local done = 0
    while done < 6 and ana.at <= ana.max do
        for _, e in ipairs(best_set(ana.at)) do
            ana.rows[ana_key(ana.at, e.slot)] = e.serial
        end
        ana.at = ana.at + ana.step
        done = done + 1
    end

    if ana.at > ana.max then
        ana.busy = false
        utilprint(TAG .. "analysis complete for " .. ana.prof .. " - every "
            .. ana.step .. " levels to " .. ana.max
            .. ". Try '/awinv usage <query>' or '/awinv plan <slot>'.")
        if render ~= nil then render() end
        return
    end

    if ana.at % 50 < ana.step then
        utilprint("$K  ...level " .. ana.at .. "$w")
    end
    later(60, ana_step)
end

local function ana_start(step)
    if ana.busy == true then
        utilprint(TAGR .. "an analysis is already running.")
        return
    end
    ana_clear()
    ana.prof = prof.active
    ana.step = (step ~= nil and step >= 1) and math.floor(step) or 10
    ana.max = 201 + 10 * char_tier()
    ana.at = 1
    ana.busy = true
    utilprint(TAG .. "analysing " .. prof.active .. " every " .. ana.step
        .. " levels to " .. ana.max .. " - this runs in the background.")
    ana_step()
end

-- the levels at which an item is the pick for one of its slots
local function ana_usage(serial)
    local out = {}
    local lv = 1
    while lv <= ana.max do
        for slot, _cap in pairs(SLOT_CAP) do
            if ana.rows[ana_key(lv, slot)] == serial then
                table.insert(out, lv)
                break
            end
        end
        lv = lv + ana.step
    end
    return out
end

-- compress 10,20,30,60 into "10-30 60"
local function ana_ranges(levels)
    if #levels == 0 then return "" end
    local out, runStart, prev = {}, levels[1], levels[1]
    local i = 2
    while i <= #levels + 1 do
        local v = levels[i]
        if v ~= nil and v == prev + ana.step then
            prev = v
        else
            if runStart == prev then
                table.insert(out, tostring(runStart))
            else
                table.insert(out, runStart .. "-" .. prev)
            end
            runStart, prev = v, v
        end
        i = i + 1
    end
    return table.concat(out, " ")
end

---
-- wearing a set, and snapshots
---

--[[
    Put a computed set on.

    Order is not cosmetic. dinv sorts by wear location so HANDS go on
    before the weapon slots, because Aardwolf's Gloves of Dexterity grant
    dual wield — put the weapons on first and the offhand is refused.
    Anything being replaced comes off first, so a shield and an offhand
    weapon are never both on the body mid-swap.

    Everything is sent as plain wear/remove and then a rescan settles the
    truth; there is no critical section here as dinv had, so a command the
    MUD refuses simply shows in your terminal and the rescan corrects the
    table.
]]
local function wear_rows(rows)
    local nOff, nOn = 0, 0

    -- take off whatever occupies a slot the set wants for something else
    for _, e in ipairs(rows) do
        local it = db.items[e.serial]
        if type(it) == "table" and it.where ~= "eq" then
            for s2, i2 in pairs(db.items) do
                if type(i2) == "table" and i2.where == "eq"
                    and slot_of(s2) == e.slot and s2 ~= e.serial then
                    send("remove " .. s2)
                    nOff = nOff + 1
                end
            end
        end
    end

    -- hands first, then everything else; a stable order beats a clever one
    local order = {}
    for _, e in ipairs(rows) do table.insert(order, e) end
    table.sort(order, function(x, y)
        local rank = function(s)
            if s == "hands" then return 0 end
            if s == "wield" or s == "shield" or s == "hold" then return 2 end
            return 1
        end
        if rank(x.slot) ~= rank(y.slot) then return rank(x.slot) < rank(y.slot) end
        return x.slot < y.slot
    end)

    for _, e in ipairs(order) do
        local it = db.items[e.serial]
        if type(it) == "table" and it.where ~= "eq" then
            if pfind(it.where, "c:") == 1 then
                send("get " .. e.serial .. " " .. string.sub(it.where, 3))
            elseif it.where == "key" then
                send("keyring get " .. e.serial)
            end
            -- dinv sends 'wear <id> second' for the offhand; plain wear
            -- would stack it as a swap of the primary instead
            if e.off == true then
                send("wear " .. e.serial .. " second")
            else
                send("wear " .. e.serial)
            end
            nOn = nOn + 1
        end
    end

    return nOff, nOn
end

---
-- snapshots: a literal record of what you are wearing, by serial
---

local function save_snaps()
    local rows = {}
    for name, txt in pairs(snaps) do
        if type(txt) == "string" then
            table.insert(rows, tostring(name) .. "=" .. txt)
        end
    end
    saveTable("aw_inv_snaps", { blob = table.concat(rows, ";") })
end

local function load_snaps()
    local saved = loadTable("aw_inv_snaps")
    if type(saved) ~= "table" then return end
    if type(saved.blob) ~= "string" or saved.blob == "" then return end
    for pair in string.gmatch(saved.blob, "[^;]+") do
        local eq = pfind(pair, "=")
        if eq ~= nil and eq > 1 then
            snaps[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1)
        end
    end
end

local function snap_take(name)
    local out = {}
    for serial, it in pairs(db.items) do
        if type(it) == "table" and it.where == "eq" then
            table.insert(out, serial)
        end
    end
    table.sort(out)
    snaps[name] = table.concat(out, ",")
    save_snaps()
    return #out
end

local function snap_rows(name)
    local txt = snaps[name]
    local out = {}
    if type(txt) ~= "string" then return out end
    for serial in string.gmatch(txt, "[^,]+") do
        if type(db.items[serial]) == "table" then
            table.insert(out, { slot = slot_of(serial), serial = serial })
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
    .arc-i .gd {
        border-left: 2px solid hsl(var(--border, 0 22% 17%));
        padding: 4px 0 6px 8px; margin-bottom: 6px; line-height: 1.5;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-i .gd.done { border-left-color: #3CB371; }
    .arc-i .gd.done b { color: #3CB371; }
    .arc-i .gd.now {
        border-left-color: hsl(var(--primary, 0 72% 42%));
        color: hsl(var(--foreground, 35 34% 78%));
        background: rgba(147,25,24,0.08);
    }
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
        local nSlot, nOk = 0, 0
        for s2, r2 in pairs(ids.stats) do
            if type(r2) == "table" and slot_of(s2) ~= "" then
                nSlot = nSlot + 1
                if usable(s2, level) then nOk = nOk + 1 end
            end
        end

        local why = ""
        if nId == 0 then
            why = "nothing identified yet &#8212; <code>/awinv build</code>."
        elseif nSlot == 0 then
            why = nId .. " item(s) identified, but none of them report a "
                .. "wearable slot, so there is nothing to rank per location."
        elseif nOk == 0 then
            why = nSlot .. " wearable item(s) identified, but none are usable "
                .. "at level " .. level .. " &#8212; too high a level, hero-only, "
                .. "alignment-restricted, or in an ignored bag."
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
    if type(want) ~= "string" and type(prof.sets[cls]) == "table" then
        want = cls
    end

    local tip = ""
    if type(want) == "string" and want ~= "" and want ~= prof.active
        and type(prof.sets[want]) == "table" then
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

    { g = "Gear",     l = "wear best",    c = "wear",              t = "put on the best set this profile can build" },
    { g = "Gear",     l = "save outfit",   c = "snap",              t = "saved outfits: save, wear, delete" },
    { g = "Gear",     l = "read stats",    c = "stats",             t = "learn your stat ceilings from spell bonuses" },
    { g = "Gear",     l = "analyse",       c = "analyze",           t = "work out what you would wear at every level" },
    { g = "Gear",     l = "profiles",      c = "prio",              t = "list scoring profiles and their weights" },
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

    { g = "Bags",     l = "filing rules", c = "organize",     t = "which bag takes what" },
    { g = "Bags",     l = "file it all",  c = "organize run", t = "put carried items in their bags" },
    { g = "Bags",     l = "ignored",      c = "ignore",       t = "bags left alone" },

    { g = "Kit",      l = "weapons",      c = "weapon",       t = "your weapons ranked, with damage types" },
    { g = "Kit",      l = "consumables",  c = "consume",      t = "named potion categories" },

    { g = "Data",     l = "backup",       c = "backup",       t = "save the item and identify stores" },
    { g = "Data",     l = "restore",      c = "restore",      t = "load the last backup" },
    { g = "Data",     l = "serials",      c = "serials",      t = "show or hide object ids on rows" },
    { g = "Data",     l = "gag data",     c = "gag",          t = "hide the raw scan rows from the terminal" },
    { g = "Data",     l = "auto",         c = "auto",         t = "rescan automatically as your inventory changes" },
    { g = "Data",     l = "diagnostics",  c = "debug",        t = "counters and a parser self-test" },
}

--[[
    The guide: what to do, in order, with the current step highlighted.

    dinv's own documentation leads with a Day-1 workflow because the
    plugin is useless until the table exists and nearly magic afterwards.
    The panel can do better than documentation by knowing which step you
    are actually on.
]]
local function render_guide()
    local nItems, nId = 0, 0
    for _, _x in pairs(db.items) do nItems = nItems + 1 end
    for _, r in pairs(ids.stats) do
        if type(r) == "table" then nId = nId + 1 end
    end

    local step = 1
    if nItems > 0 then step = 2 end
    if nId > 0 then step = 3 end
    if sb.have == true then step = 4 end
    if ana.prof ~= "" then step = 5 end

    local row = function(n, title, body, cmd, label)
        local cls = "gd"
        if n < step then cls = "gd done" end
        if n == step then cls = "gd now" end
        local btn = ""
        if cmd ~= "" then
            btn = ' <span class="tb" data-mud-action="cmd" data-mud-data="'
                .. esc(cmd) .. '">' .. label .. "</span>"
        end
        return '<div class="' .. cls .. '"><b>' .. n .. ". " .. title
            .. "</b><br>" .. body .. btn .. "</div>"
    end

    local out = {}
    table.insert(out, '<div class="sec">Getting set up</div>')

    table.insert(out, row(1, "Index what you own",
        "Reads your worn gear, inventory, bags and keyring. Stand somewhere "
        .. "quiet &#8212; it moves items about.", "build", "run build"))

    table.insert(out, row(2, "Identify it",
        "Reads each item's stats into the database. Gear is removed and "
        .. "re-worn as it goes. Runs automatically after a build; this "
        .. "catches anything new. <b>" .. nId .. "</b> known so far.",
        "id missing", "identify new items"))

    table.insert(out, row(3, "Learn your stat ceilings",
        "Reads your spell bonuses so gear is judged on the room your "
        .. "spellups actually leave. Worth redoing when you level or "
        .. "change spellups.", "stats", "read stats"))

    table.insert(out, row(4, "Pick how you want to be scored",
        "A profile says what a point of each stat is worth to you. "
        .. "Currently <b>" .. esc(prof.active) .. "</b>.", "prio", "see profiles"))

    table.insert(out, row(5, "Plan ahead",
        "Works out what you would wear at every level, so you can see where "
        .. "your gear runs thin. Takes a moment and then answers instantly.",
        "analyze", "analyse"))

    table.insert(out, '<div class="sec">Then, day to day</div>')
    table.insert(out, '<div class="note">'
        .. "<b>best</b> ranks your gear now &#183; <b>wear</b> puts the best set on "
        .. "&#183; <b>snap save &lt;name&gt;</b> remembers an outfit &#183; "
        .. "<b>find &lt;query&gt;</b> searches everything you own.<br><br>"
        .. "Queries read like sentences: <code>type weapon minlevel 100</code>, "
        .. "<code>worn</code>, <code>kw favourite</code>, "
        .. "<code>type potion || type pill</code>.</div>")

    return table.concat(out, "\n")
end

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
    elseif view == "guide" then
        body = render_guide()
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
        .. tab("menu", "menu") .. tab("guide", "guide")
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
    local where  = st.inBlock
    local seen   = st.buf
    local rows   = st.scanRows
    block_release()

    --[[
        Reconcile: anything previously filed here that this scan did NOT
        report has moved or gone. Skipped when the scan produced nothing,
        because "no answer" and "nothing there" are not the same thing and
        only one of them should empty your inventory.
    ]]
    if rows > 0 then
        local goners = {}
        for serial, it in pairs(db.items) do
            if type(it) == "table" and it.where == where and seen[serial] ~= true then
                table.insert(goners, serial)
            end
        end
        for _, serial in ipairs(goners) do db.items[serial] = nil end
    end

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

    later(250, function()
        if type(next_scan) == "function" then next_scan() end
    end)
end

next_scan = function()
    if st.inBlock ~= "" then return end
    if #st.scanQ == 0 then return end

    --[[
        NOT cleared here. Clearing a location before the reply arrives means
        a scan that answers with nothing deletes it — and scan_end saves, so
        the loss is permanent. That is exactly what a login does: an invmon
        burst fires a refresh while the character is still settling, the
        scans answer empty, and the table is wiped and persisted over.
        Stale entries are pruned at scan_end instead, and only when the scan
        actually produced rows.
    ]]
    local s = table.remove(st.scanQ, 1)
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
    later(2500, function()
        if st.scanSeq == mySeq and st.inBlock ~= "" and st.scanRows == 0 then
            scan_end()
        end
    end)

    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer) end
    st.blockTimer = later(BLOCK_MS, function()
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

    --[[
        Sits BELOW the regen capture on purpose. The id pass removes and
        re-wears gear constantly, so auto-refreshing off our own churn would
        interleave scans into open identify boxes — but a sleep during a
        pass must still record what the ring displaced.
    ]]
    if ids.pending ~= "" or #ids.q > 0 then return end

    st.clockMs = st.clockMs + DEBOUNCE_MS
    if st.pokeTimer ~= nil then pcall(removeTimer, st.pokeTimer) end
    st.pokeTimer = later(DEBOUNCE_MS, function()
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
-- consumable shopping, dinv's consume buy/small/big
---

local function room_now()
    local n = tonumber(gfield(getGMCPData("room.info"), "num"))
    if n == nil or n < 1 then return 0 end
    return n
end

--[[
    The appraise box landed (or didn't). Called by id_store under the
    "@shop" sentinel; r is the parsed record or nil.
]]
cshop_capture = function(r)
    local cat, kw = cshop.cat, cshop.kw
    cshop.cat = ""
    cshop.kw = ""
    if cat == "" or kw == "" then return end

    if type(r) ~= "table" or tonumber(r.level) == nil then
        utilprint(TAGR .. "no appraise answer for '" .. kw .. "' - stand at "
            .. "the shopkeeper and use a keyword the shop sells.")
        return
    end

    local room = room_now()
    local full = (type(r.item) == "string") and r.item or ""
    cshop_add(cat, tonumber(r.level), kw, room, full)
    save_cshop()

    utilprint(TAG .. cat .. " now restocks with L" .. tostring(r.level)
        .. " '" .. kw .. "'" .. ((full ~= "") and (" (" .. full .. ")") or "")
        .. ((room > 0) and (" from room " .. room) or " (room unknown - GMCP was quiet)")
        .. ".")
    utilprint("$K  '/awinv consume buy " .. cat .. "' travels there and buys it.$w")
end

local function cshop_buy_stop()
    if cshop.poll ~= nil then pcall(removeTimer, cshop.poll); cshop.poll = nil end
    cshop.buyCat = ""
    cshop.buyKw = ""
    cshop.buyN = 0
    cshop.buyRoom = 0
    cshop.waited = 0
end

local function cshop_buy_arrive()
    local n, kw = cshop.buyN, cshop.buyKw
    -- Aardwolf's multi-buy: 'buy 5 griff'. dinv sends the keyword bare.
    if n > 1 then
        send("buy " .. n .. " " .. kw)
    else
        send("buy " .. kw)
    end
    utilprint(TAG .. "buying " .. n .. " x '" .. kw .. "'.")
    cshop_buy_stop()
    later(1800, function() refresh(false) end)
end

-- forward-declared so the timer callback can re-arm itself
local cshop_poll_step = nil

cshop_poll_step = function()
    cshop.poll = nil
    if cshop.buyRoom < 1 then return end
    if room_now() == cshop.buyRoom then
        cshop_buy_arrive()
        return
    end
    cshop.waited = cshop.waited + 700
    if cshop.waited >= 25000 then
        utilprint(TAGR .. "never arrived at room " .. cshop.buyRoom
            .. " - walk there yourself and rerun the buy, or re-record "
            .. "the shop with '/awinv consume shop'.")
        cshop_buy_stop()
        return
    end
    cshop.poll = later(700, cshop_poll_step)
end

local function cshop_buy(cat, n)
    if cshop.buyCat ~= "" then
        utilprint(TAGR .. "a purchase is already in flight.")
        return
    end
    local list = cshop.tab[cat]
    if type(list) ~= "table" or list[1] == nil then
        utilprint(TAGR .. "no shop entries for '" .. cat .. "'. Stand at the "
            .. "shopkeeper and run '/awinv consume shop " .. cat .. " <keyword>'.")
        return
    end

    -- dinv's rule: the highest-level entry you can actually use
    local lv = char_level()
    local best = nil
    for _, e in ipairs(list) do
        if e.lv <= lv then best = e end
    end
    if best == nil then
        utilprint(TAGR .. "nothing in '" .. cat .. "' is usable at level " .. lv .. ".")
        return
    end
    if tonumber(best.room) == nil or best.room < 1 then
        utilprint(TAGR .. "the L" .. best.lv .. " '" .. best.kw .. "' entry has "
            .. "no shop room recorded - re-record it at the shopkeeper.")
        return
    end

    cshop.buyCat = cat
    cshop.buyKw = best.kw
    cshop.buyN = n
    cshop.buyRoom = best.room
    cshop.waited = 0

    if room_now() == best.room then
        cshop_buy_arrive()
        return
    end

    --[[
        walkTo is the client's own walker — it knows custom-exit command
        stacking and wait() pauses, which a hand-compressed run does not.
        It needs the map widget mounted; arrival is confirmed by polling
        GMCP rather than trusting the walker's answer either way.
    ]]
    if type(walkTo) == "function" then
        pcall(walkTo, best.room)
        utilprint(TAG .. "walking to room " .. best.room .. " for L" .. best.lv
            .. " '" .. best.kw .. "'...")
    else
        utilprint(TAGR .. "this build has no walkTo - walk to room " .. best.room
            .. " and the buy fires when you arrive.")
    end
    cshop.poll = later(700, cshop_poll_step)
end

--[[
    Drink N of a category. dinv's sizes: 'small' burns the lowest-level
    usable instance you own (the dregs), 'big' the highest (the one worth
    drinking in a fight). Candidates come from the shop entries' full
    names when the category has them, plus the legacy keyword query.
]]
local function cshop_drink(cat, size, n)
    local lv = char_level()
    local seen = {}
    local cand = {}

    local function consider(serial)
        if seen[serial] == true then return end
        seen[serial] = true
        local it = db.items[serial]
        if type(it) ~= "table" then return end
        if it.where ~= "inv" and pfind(it.where, "c:") ~= 1 then return end
        local ilv = tonumber(it.level)
        if ilv == nil then ilv = 0 end
        if ilv > lv then return end
        table.insert(cand, { serial = serial, lv = ilv })
    end

    local kw = cons[cat]
    if type(kw) == "string" and kw ~= "" then
        for _, serial in ipairs(q_find(kw)) do consider(serial) end
    end
    local list = cshop.tab[cat]
    if type(list) == "table" then
        for _, e in ipairs(list) do
            if type(e.full) == "string" and e.full ~= "" then
                local want = string.lower(e.full)
                for serial, it in pairs(db.items) do
                    if type(it) == "table"
                        and string.lower(tostring(it.name or "")) == want then
                        consider(serial)
                    end
                end
            end
            if e.kw ~= "" then
                for _, serial in ipairs(q_find(e.kw)) do consider(serial) end
            end
        end
    end

    if type(kw) ~= "string" and type(list) ~= "table" then
        utilprint(TAGR .. "no category '" .. cat
            .. "'. '/awinv consume list' shows them.")
        return
    end
    if #cand == 0 then
        utilprint(TAGR .. "you own nothing in '" .. cat .. "' usable at level "
            .. lv .. ". '/awinv consume buy " .. cat .. "' restocks.")
        return
    end

    if size == "small" then
        table.sort(cand, function(x, y)
            if x.lv ~= y.lv then return x.lv < y.lv end
            return x.serial < y.serial
        end)
    else
        table.sort(cand, function(x, y)
            if x.lv ~= y.lv then return x.lv > y.lv end
            return x.serial < y.serial
        end)
    end

    -- dinv caps a burst at 10 so a typo can't drain a stack
    if n > 10 then
        utilprint(TAG .. "capping at 10 per burst (dinv's own limit).")
        n = 10
    end
    if n > #cand then n = #cand end

    local i = 1
    local function sip()
        if i > n then return end
        local e = cand[i]
        i = i + 1
        local it = db.items[e.serial]
        if type(it) == "table" then
            local verb = "quaff"
            if it.itype == 19 or it.itype == 14 then verb = "eat" end
            if it.itype == 2 then verb = "recite" end
            if pfind(it.where, "c:") == 1 then
                send("get " .. e.serial .. " " .. string.sub(it.where, 3))
            end
            send(verb .. " " .. e.serial)
            utilprint(TAG .. verb .. " L" .. e.lv .. " " .. it.name
                .. " (" .. (i - 1) .. "/" .. n .. ")")
        end
        if i <= n then later(600, sip) end
    end
    sip()
    later(2500, function() refresh(false) end)
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
        if type(saved.ignored) == "string" then cfg.ignored = saved.ignored end
        if saved.weapwish == true then cfg.weapwish = true end
        local fp = tonumber(saved.fpx)
        if fp ~= nil and fp >= 6 and fp <= 48 then cfg.fpx = math.floor(fp) end
        fp = tonumber(saved.fov)
        if fp ~= nil and fp >= 6 and fp <= 48 then cfg.fov = math.floor(fp) end
    end

    load_db()
    load_stats()
    load_prof()
    load_qol()
    load_sb()
    load_snaps()
    load_rules()
    load_cons()
    load_cshop()

    --[[
        Say what came back. Persistence failing silently is how a session's
        work disappears unnoticed; a line at startup makes it obvious the
        moment it stops working.
    ]]
    local nLoad, nIdLoad = 0, 0
    for _, it in pairs(db.items) do
        if type(it) == "table" then nLoad = nLoad + 1 end
    end
    for _, r in pairs(ids.stats) do
        if type(r) == "table" then nIdLoad = nIdLoad + 1 end
    end
    if nLoad > 0 then
        utilprint(TAG .. "restored " .. nLoad .. " item(s), " .. nIdLoad
            .. " identified.")
    end

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
    trig("^\\{eqdata\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    trig("^\\{invdata\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    trig("^\\{keyring\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    trig("^\\{vault\\}", on_open_marker, { type = "regex", keepEvaluating = true })
    trig("^\\{/(?:invdata|eqdata|keyring|vault)\\}", on_close,
        { type = "regex", keepEvaluating = true })
    trig("^\\{vaultcounts\\}([0-9]+),([0-9]+),([0-9]+)", on_vaultcounts,
        { type = "regex", keepEvaluating = true })
    trig("^\\{invmon\\}", on_invmon,
        { type = "regex", keepEvaluating = true })
    trig("^You dream about (?:being able to keyring|checking your vault)\\.$",
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

    trig("^You wake and stand up\\.$", on_wake,
        { type = "regex", keepEvaluating = true })

    --[[
        The 'stats' command's spell-bonus row, which sets the ceilings all
        scoring is judged against. Without this registered, /awinv stats
        sent the command and threw the answer away.
    ]]
    trig("^Spells Bonus", on_spells_bonus,
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
            if view ~= "best" and view ~= "use" and view ~= "menu"
                and view ~= "guide" then
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
    registerCommand("sleep", function(args)
        -- the client eats the whole first word, so 'sleep bed' arrives here
        -- with 'bed' in args and must be forwarded or the couch is lost
        local rest = args
        if type(rest) == "table" then rest = table.concat(rest, " ") end
        rest = trim(tostring(rest or ""))

        if qol.regen ~= "" and type(db.items[qol.regen]) == "table" then
            qol.watchWear = true
            if qol.watchTimer ~= nil then pcall(removeTimer, qol.watchTimer) end
            qol.watchTimer = later(4000, function()
                qol.watchTimer = nil
                qol.watchWear = false
            end)
            send("wear " .. qol.regen)
        end
        send(trim("sleep " .. rest))
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
            if n > 0 then later(900, function() refresh(false) end) end

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
                if n > 0 then later(900, function() refresh(false) end) end
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
                    local cur = ids.stats[serial].tags
                    if type(cur) ~= "string" then cur = "" end
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
                later(600, function() refresh(false) end)
            end

        elseif low == "wear" or string.sub(low, 1, 5) == "wear " then
            --[[
                Put on the best set this profile can build. The ranking was
                always there; this is the command that acts on it.
            ]]
            local lvArg = tonumber(trim(string.sub(low, 5)))
            local lv = (lvArg ~= nil) and math.floor(lvArg) or char_level()
            local rows = best_set(lv)
            if #rows == 0 then
                utilprint(TAGR .. "nothing to wear - identify your gear first "
                    .. "('/awinv build').")
            else
                local nOff, nOn = wear_rows(rows)
                if nOn == 0 then
                    utilprint(TAG .. "already wearing the best set for "
                        .. prof.active .. " at level " .. lv .. ".")
                else
                    utilprint(TAG .. "wearing the " .. prof.active .. " set for level "
                        .. lv .. ": " .. nOn .. " on, " .. nOff .. " off.")
                    later(1500, function() refresh(false) end)
                end
            end

        elseif low == "snap" or string.sub(low, 1, 5) == "snap " then
            local rest = trim(string.sub(a, 5))
            local restLow = string.lower(rest)
            local sp = pfind(restLow, " ")
            local op = (sp ~= nil) and string.sub(restLow, 1, sp - 1) or restLow
            local nm = (sp ~= nil) and trim(string.sub(rest, sp + 1)) or ""
            nm = string.gsub(string.lower(nm), "[^a-z0-9_-]", "")

            if op == "save" and nm ~= "" then
                local n = snap_take(nm)
                utilprint(TAG .. "outfit '" .. nm .. "' saved - " .. n .. " item(s).")
                render()
            elseif op == "wear" and nm ~= "" and type(snaps[nm]) == "string" then
                local rows = snap_rows(nm)
                local nOff, nOn = wear_rows(rows)
                utilprint(TAG .. "wearing outfit '" .. nm .. "': " .. nOn
                    .. " on, " .. nOff .. " off.")
                if nOn > 0 then later(1500, function() refresh(false) end) end
            elseif op == "del" and nm ~= "" then
                snaps[nm] = nil
                save_snaps()
                render()
                utilprint(TAG .. "outfit '" .. nm .. "' deleted.")
            else
                local names = {}
                for k, _v in pairs(snaps) do table.insert(names, k) end
                table.sort(names)
                if #names == 0 then
                    utilprint(TAG .. "no saved outfits. '/awinv snap save <name>' "
                        .. "records what you are wearing now.")
                else
                    utilprint(TAG .. "outfits: " .. table.concat(names, ", "))
                    utilprint("$w  /awinv snap save|wear|del <name>")
                end
            end

        elseif string.sub(low, 1, 6) == "store " or low == "store" then
            --[[
                Send things back where they came from. The home bag is
                recorded when a scan finds an item inside one, so this
                undoes a 'get' without you naming the container.
            ]]
            local hits = q_find(trim(string.sub(a, 6)))
            local n = 0
            for _, serial in ipairs(hits) do
                local r = ids.stats[serial]
                local home = (type(r) == "table") and tostring(r.home or "") or ""
                local it = db.items[serial]
                if home ~= "" and type(db.items[home]) == "table"
                    and it.where ~= "c:" .. home then
                    if it.where == "eq" then send("remove " .. serial) end
                    send("put " .. serial .. " " .. home)
                    n = n + 1
                end
            end
            utilprint(TAG .. n .. " item(s) returned to their bags.")
            if n > 0 then later(1200, function() refresh(false) end) end

        elseif string.sub(low, 1, 6) == "ignore" then
            local rest = trim(string.sub(low, 7))
            local sp = pfind(rest, " ")
            local op = (sp ~= nil) and string.sub(rest, 1, sp - 1) or rest
            local who = (sp ~= nil) and trim(string.sub(rest, sp + 1)) or ""

            if op == "on" and who ~= "" then
                if pfind(" " .. cfg.ignored .. " ", " " .. who .. " ") == nil then
                    cfg.ignored = trim(cfg.ignored .. " " .. who)
                    save_cfg()
                end
                render()
                utilprint(TAG .. who .. " ignored - not scanned, ranked or moved.")
            elseif op == "off" and who ~= "" then
                local keep = {}
                for wd in string.gmatch(cfg.ignored, "%S+") do
                    if wd ~= who then table.insert(keep, wd) end
                end
                cfg.ignored = table.concat(keep, " ")
                save_cfg()
                render()
                utilprint(TAG .. who .. " no longer ignored.")
            else
                if cfg.ignored == "" then
                    utilprint(TAG .. "nothing ignored. '/awinv ignore on <serial>' "
                        .. "leaves a bag or item alone.")
                else
                    utilprint(TAG .. "ignored: " .. cfg.ignored)
                end
            end

        elseif low == "analyze" or string.sub(low, 1, 8) == "analyze " then
            local n = tonumber(trim(string.sub(low, 8)))
            ana_start(n)

        elseif string.sub(low, 1, 6) == "usage " then
            if ana.prof == "" then
                utilprint(TAGR .. "no analysis yet - run '/awinv analyze' first.")
            else
                local hits = q_find(trim(string.sub(a, 6)))
                utilprint(TAG .. "usage under " .. ana.prof .. ":")
                local shown = 0
                for _, serial in ipairs(hits) do
                    if shown < 30 then
                        local lv = ana_usage(serial)
                        local it = db.items[serial]
                        local txt = (#lv > 0) and ("$Glevels " .. ana_ranges(lv))
                            or "$Kunused"
                        utilprint("$w  " .. it.name .. "$w  " .. txt .. "$w")
                        shown = shown + 1
                    end
                end
                if shown == 0 then utilprint("$K  nothing matched.$w") end
            end

        elseif string.sub(low, 1, 5) == "plan " then
            --[[
                dinv's 'analyze display <position>': the upgrade path for
                one slot. Only the levels where the pick CHANGES are worth
                printing — that is where you act.
            ]]
            if ana.prof == "" then
                utilprint(TAGR .. "no analysis yet - run '/awinv analyze' first.")
            else
                local slot = trim(string.sub(low, 5))
                utilprint(TAG .. "upgrade path for " .. slot
                    .. " under " .. ana.prof .. ":")
                local prev, lv, shown = "", 1, 0
                while lv <= ana.max do
                    local serial = ana.rows[ana_key(lv, slot)]
                    local cur = (serial ~= nil) and serial or ""
                    if cur ~= prev then
                        if cur == "" then
                            utilprint("$w  level " .. lv .. ": $Knothing$w")
                        else
                            local it = db.items[cur]
                            utilprint("$w  level " .. lv .. ": $C"
                                .. ((type(it) == "table") and it.name or cur) .. "$w")
                        end
                        prev = cur
                        shown = shown + 1
                    end
                    lv = lv + ana.step
                end
                if shown == 0 then
                    utilprint("$K  nothing ranks for that slot. Slot names: "
                        .. "head eyes ear neck back medal torso body waist arms "
                        .. "wrist hands finger legs feet shield wield hold float$w")
                end
            end

        elseif string.sub(low, 1, 8) == "compare " then
            --[[
                What one item is worth: how many slot-levels it wins, and
                what would take its place if you lost it.
            ]]
            if ana.prof == "" then
                utilprint(TAGR .. "no analysis yet - run '/awinv analyze' first.")
            else
                local who = trim(string.sub(a, 8))
                local serial = who
                if tonumber(who) == nil then
                    local hits = q_find(who)
                    serial = (hits[1] ~= nil) and hits[1] or ""
                end
                local it = db.items[serial]
                if type(it) ~= "table" then
                    utilprint(TAGR .. "no item matching '" .. who .. "'.")
                else
                    local lv = ana_usage(serial)
                    local sc = score_of(serial)
                    utilprint(TAG .. it.name .. " (" .. serial .. ")")
                    utilprint("$w  scores " .. tostring(sc) .. " under "
                        .. prof.active .. " at your level")
                    if #lv == 0 then
                        utilprint("$w  $Knever the best choice for its slot - safe to "
                            .. "sell or store.$w")
                    else
                        utilprint("$w  best in slot at $Glevels " .. ana_ranges(lv)
                            .. "$w (" .. #lv .. " of " .. math.floor(ana.max / ana.step)
                            .. " sampled levels)")
                    end
                end
            end

        elseif low == "stats" then
            -- ask the MUD for the spell bonuses that set the stat ceilings
            sb.asked = true
            send("stats")
            utilprint(TAG .. "reading your spell bonuses to learn how much room "
                .. "equipment still has at level " .. char_level() .. "...")

        elseif string.sub(low, 1, 8) == "organize" then
            --[[
                Per-bag filing rules. 'organize add <bag> <query>' teaches a
                container what belongs in it; 'organize' files everything
                carried according to those rules. Worn gear is left alone —
                dinv's bare form sweeps that too, and undressing yourself by
                typing one word is not a feature.
            ]]
            local rest = trim(string.sub(a, 9))
            local restLow = string.lower(rest)

            if string.sub(restLow, 1, 4) == "add " then
                local body = trim(string.sub(rest, 5))
                local sp = pfind(body, " ")
                local con = (sp ~= nil) and string.sub(body, 1, sp - 1) or ""
                local q = (sp ~= nil) and trim(string.sub(body, sp + 1)) or ""
                if type(db.items[con]) ~= "table" or q == "" then
                    utilprint(TAGR .. "usage: /awinv organize add <bag serial> <query>")
                else
                    rules[con] = q
                    save_rules()
                    utilprint(TAG .. db.items[con].name .. " now takes: " .. q)
                end

            elseif string.sub(restLow, 1, 6) == "clear " then
                local con = trim(string.sub(restLow, 7))
                rules[con] = nil
                save_rules()
                utilprint(TAG .. "rule cleared for " .. con .. ".")

            elseif restLow == "" or restLow == "list" then
                local any = false
                for con, q in pairs(rules) do
                    local it = db.items[con]
                    utilprint("$w  " .. ((type(it) == "table") and it.name or con)
                        .. " $K(" .. con .. ")$w  <- " .. q)
                    any = true
                end
                if not any then
                    utilprint(TAG .. "no filing rules yet. "
                        .. "'/awinv organize add <bag serial> <query>'")
                    utilprint("$K  e.g. organize add 12345 type potion || type pill$w")
                else
                    utilprint("$K  '/awinv organize run' files everything carried.$w")
                end

            elseif restLow == "run" then
                local moved = 0
                for con, q in pairs(rules) do
                    if type(db.items[con]) == "table" then
                        for _, serial in ipairs(q_find(q)) do
                            local it = db.items[serial]
                            if it.where == "inv" and serial ~= con then
                                send("put " .. serial .. " " .. con)
                                moved = moved + 1
                            end
                        end
                    end
                end
                utilprint(TAG .. moved .. " item(s) filed.")
                if moved > 0 then later(1200, function() refresh(false) end) end
            else
                utilprint(TAG .. "usage: /awinv organize [list | add <bag> <query> "
                    .. "| clear <bag> | run]")
            end

        elseif string.sub(low, 1, 6) == "weapon" then
            --[[
                dinv's weapon sets: rank only weapons whose damage type you
                want, so you can answer "this thing resists slash" without
                editing a profile. The types are the identify box's own
                Damage Type words.
            ]]
            local want = trim(string.sub(low, 7))

            if want == "wish" then
                cfg.weapwish = (cfg.weapwish ~= true)
                save_cfg()
                if cfg.weapwish == true then
                    utilprint(TAG .. "Weapons wish recorded - weapon-skill "
                        .. "gating is off, every type is fair game.")
                else
                    utilprint(TAG .. "Weapons wish cleared - rankings only "
                        .. "offer types a class of yours can wield.")
                end
                return
            end

            local pool = {}
            for serial, r in pairs(ids.stats) do
                if type(r) == "table" and slot_of(serial) == "wield"
                    and usable(serial, char_level()) then
                    local dt = string.lower(tostring(r.dam_type or ""))
                    local ok = (want == "" or want == "all")
                    if not ok and dt ~= "" then
                        if want == "phys" or want == "physical" then
                            ok = pfind(dt, "slash") ~= nil or pfind(dt, "pierce") ~= nil
                                or pfind(dt, "bash") ~= nil
                        else
                            ok = pfind(dt, want) ~= nil
                        end
                    end
                    if ok then
                        local sc = score_of(serial)
                        table.insert(pool, { serial = serial,
                            sc = (sc ~= nil) and sc or 0, dt = dt })
                    end
                end
            end
            table.sort(pool, function(x, y) return x.sc > y.sc end)

            if #pool == 0 then
                utilprint(TAGR .. "no identified weapon matches '"
                    .. (want ~= "" and want or "any") .. "'. Damage types come "
                    .. "from the identify box; without the identify wish many "
                    .. "weapons never report one.")
            else
                utilprint(TAG .. "weapons" .. ((want ~= "") and (" (" .. want .. ")") or "")
                    .. ", best first:")
                local i = 1
                while i <= #pool and i <= 10 do
                    local e = pool[i]
                    local it = db.items[e.serial]
                    utilprint("$w  " .. e.sc .. "pt  $C" .. it.name .. "$w  "
                        .. ((e.dt ~= "") and ("$K" .. e.dt .. "$w") or "$Kdam type unknown$w"))
                    i = i + 1
                end
                utilprint("$K  '/awinv do wear " .. pool[1].serial
                    .. "' wields the top one.$w")

                --[[
                    What the set builder would actually put in your hands,
                    dual wield included — the ranking above is per-weapon,
                    this is the pairing decision.
                ]]
                local prim, offh = nil, nil
                for _, e in ipairs(best_set(char_level())) do
                    if e.slot == "wield" then
                        if e.off == true then offh = e else prim = e end
                    end
                end
                if prim ~= nil and offh ~= nil then
                    local i1 = db.items[prim.serial]
                    local i2 = db.items[offh.serial]
                    utilprint(TAG .. "the set builder dual wields: $C"
                        .. ((type(i1) == "table") and i1.name or prim.serial)
                        .. "$w + $C"
                        .. ((type(i2) == "table") and i2.name or offh.serial)
                        .. "$w (offhand). '/awinv wear' puts both on.")
                elseif prim ~= nil then
                    if ability_at("dualwield", char_level()) then
                        utilprint("$K  one weapon: no legal offhand beats "
                            .. "shield + held item (offhand must weigh half "
                            .. "the primary or less).$w")
                    else
                        utilprint("$K  no dual wield at your level - one "
                            .. "weapon plus shield and held item.$w")
                    end
                end
            end

        elseif string.sub(low, 1, 7) == "consume" then
            local rest = trim(string.sub(a, 8))
            local restLow = string.lower(rest)

            if string.sub(restLow, 1, 4) == "add " then
                local body = trim(string.sub(rest, 5))
                local sp = pfind(body, " ")
                local nm = (sp ~= nil) and string.lower(string.sub(body, 1, sp - 1)) or ""
                local kw = (sp ~= nil) and trim(string.sub(body, sp + 1)) or ""
                if nm == "" or kw == "" then
                    utilprint(TAGR .. "usage: /awinv consume add <name> <keyword>")
                else
                    cons[nm] = kw
                    save_cons()
                    utilprint(TAG .. "'" .. nm .. "' means items matching '" .. kw
                        .. "'. Use with: /awinv consume " .. nm)
                end

            elseif string.sub(restLow, 1, 3) == "rm " then
                cons[trim(string.sub(restLow, 4))] = nil
                save_cons()
                utilprint(TAG .. "category removed.")

            elseif string.sub(restLow, 1, 5) == "shop " then
                --[[
                    Record a shop entry: stand at the shopkeeper, name the
                    category and the keyword the shop sells. The appraise
                    box supplies level and full name, GMCP the room.
                ]]
                local body = trim(string.sub(rest, 6))
                local sp = pfind(body, " ")
                local nm = (sp ~= nil) and string.lower(string.sub(body, 1, sp - 1)) or ""
                local kw = (sp ~= nil) and string.lower(trim(string.sub(body, sp + 1))) or ""
                if nm == "" or kw == "" then
                    utilprint(TAGR .. "usage: /awinv consume shop <category> <keyword> "
                        .. "- run it standing at the shopkeeper.")
                elseif ids.pending ~= "" or #ids.q > 0 then
                    utilprint(TAGR .. "the identify queue is busy - try again "
                        .. "in a moment.")
                else
                    cshop.cat = nm
                    cshop.kw = kw
                    ids.pending = "@shop"
                    id_trigs(true)
                    send("appraise " .. kw)
                    id_guard_off()
                    ids.guard = later(8000, function()
                        ids.guard = nil
                        if ids.pending == "@shop" and type(ids.rec) ~= "table" then
                            ids.pending = ""
                            id_trigs(false)
                            cshop.cat = ""
                            cshop.kw = ""
                            utilprint(TAGR .. "no appraise box for '" .. kw
                                .. "' - are you at a shopkeeper that sells it?")
                        end
                    end)
                end

            elseif restLow == "shops" then
                local names = {}
                for nm, _ in pairs(cshop.tab) do table.insert(names, nm) end
                table.sort(names)
                if #names == 0 then
                    utilprint(TAG .. "no shop entries. Stand at a shopkeeper and "
                        .. "run '/awinv consume shop <category> <keyword>'.")
                end
                for _, nm in ipairs(names) do
                    utilprint("$w  $C" .. nm .. "$w:")
                    for _, e in ipairs(cshop.tab[nm]) do
                        utilprint("$w    L" .. e.lv .. "  " .. e.kw .. "  $Kroom "
                            .. tostring(e.room)
                            .. ((e.full ~= "") and ("  " .. e.full) or "") .. "$w")
                    end
                end

            elseif string.sub(restLow, 1, 7) == "unshop " then
                local body = trim(string.sub(restLow, 8))
                local sp = pfind(body, " ")
                local nm = (sp ~= nil) and string.sub(body, 1, sp - 1) or body
                local kw = (sp ~= nil) and trim(string.sub(body, sp + 1)) or ""
                if type(cshop.tab[nm]) ~= "table" then
                    utilprint(TAGR .. "no shop category '" .. nm .. "'.")
                elseif kw == "" then
                    cshop.tab[nm] = nil
                    save_cshop()
                    utilprint(TAG .. "shop category '" .. nm .. "' removed.")
                else
                    local list = cshop.tab[nm]
                    local kept = {}
                    for _, e in ipairs(list) do
                        if e.kw ~= kw then table.insert(kept, e) end
                    end
                    if #kept == 0 then
                        cshop.tab[nm] = nil
                    else
                        cshop.tab[nm] = kept
                    end
                    save_cshop()
                    utilprint(TAG .. "'" .. kw .. "' removed from '" .. nm .. "'.")
                end

            elseif string.sub(restLow, 1, 4) == "buy " then
                local body = trim(string.sub(restLow, 5))
                local sp = pfind(body, " ")
                local nm = (sp ~= nil) and string.sub(body, 1, sp - 1) or body
                local n = (sp ~= nil) and tonumber(trim(string.sub(body, sp + 1))) or 1
                if n == nil or n < 1 then n = 1 end
                if n > 99 then n = 99 end
                cshop_buy(nm, math.floor(n))

            elseif string.sub(restLow, 1, 6) == "small "
                or string.sub(restLow, 1, 4) == "big " then
                local size = (string.sub(restLow, 1, 3) == "big") and "big" or "small"
                local body = trim(string.sub(restLow, (size == "big") and 5 or 7))
                local sp = pfind(body, " ")
                local nm = (sp ~= nil) and string.sub(body, 1, sp - 1) or body
                local n = (sp ~= nil) and tonumber(trim(string.sub(body, sp + 1))) or 1
                if n == nil or n < 1 then n = 1 end
                cshop_drink(nm, size, math.floor(n))

            elseif restLow == "" or restLow == "list" then
                local any = false
                for nm, kw in pairs(cons) do
                    local held = q_find(kw .. " carried")
                    utilprint("$w  " .. nm .. "  $K" .. kw .. "$w  "
                        .. #held .. " held")
                    any = true
                end
                for nm, list in pairs(cshop.tab) do
                    if type(list) == "table" and list[1] ~= nil then
                        utilprint("$w  " .. nm .. "  $K" .. #list
                            .. " shop entr" .. ((#list == 1) and "y" or "ies")
                            .. ", top L" .. list[#list].lv .. "$w")
                        any = true
                    end
                end
                if not any then
                    utilprint(TAG .. "no categories. Stand at a shopkeeper and "
                        .. "'/awinv consume shop heal <keyword>' records where to "
                        .. "buy; '/awinv consume buy heal' restocks; "
                        .. "'/awinv consume heal' drinks the best one.")
                end

            else
                -- bare '/awinv consume <cat>' stays dinv's 'big', one item
                cshop_drink(restLow, "big", 1)
            end

        elseif low == "bags" then
            --[[
                What the scan believes about containers, and why none were
                found if none were. A bag lives in inventory or is worn; a
                scan can only see what invdata/eqdata listed.
            ]]
            local bagList = container_list()
            utilprint(TAG .. #bagList .. " container(s) known.")
            for _, it in ipairs(bagList) do
                utilprint("$w  " .. it.serial .. "  $C" .. it.name
                    .. "$w  (" .. it.where .. ")  "
                    .. count_where("c:" .. it.serial) .. " item(s) inside")
            end
            if #bagList == 0 then
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
            save_db_force()
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
                    --[[
                        Accept everything score_at can actually read: the
                        stat mods, the effect names it looks up via aff_,
                        the derived weapon/pool keys, the max<stat> cap
                        bonuses and the ~<slot> bans. The old check allowed
                        only STAT_MAP values, so weights visible in
                        'prio list' could not be edited.
                    ]]
                    local known = false
                    for _, v in pairs(STAT_MAP) do
                        if v == stat then known = true end
                    end
                    for _, v in ipairs({ "ave_dam", "offhand_dam", "score",
                        "weight", "worth", "sanctuary", "haste", "flying",
                        "invis", "regeneration", "detectinvis", "detecthidden",
                        "detectevil", "detectgood", "detectmagic", "dualwield",
                        "irongrip", "shield" }) do
                        if v == stat then known = true end
                    end
                    for _, v in ipairs(STAT6) do
                        if stat == "max" .. v then known = true end
                    end
                    if string.sub(stat, 1, 1) == "~" then known = true end
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

            elseif string.sub(restLow, 1, 6) == "clone " then
                -- the deep dive's day-one advice: start from a class default
                local body = trim(string.sub(restLow, 7))
                local sp = pfind(body, " ")
                local src = (sp ~= nil) and string.sub(body, 1, sp - 1) or ""
                local dst = (sp ~= nil) and trim(string.sub(body, sp + 1)) or ""
                dst = string.gsub(dst, "[^a-z0-9_-]", "")
                if type(prof.sets[src]) ~= "table" or dst == "" then
                    utilprint(TAGR .. "usage: /awinv prio clone <from> <to>")
                else
                    local copy = {}
                    for k, v in pairs(prof.sets[src]) do copy[k] = v end
                    prof.sets[dst] = copy
                    prof.active = dst
                    save_prof()
                    render()
                    utilprint(TAG .. "'" .. dst .. "' cloned from " .. src
                        .. " and made active. Tune it with "
                        .. "'/awinv prio set " .. dst .. " <stat> <weight>'.")
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

                later(1200, function()
                    if home ~= "" then send("put " .. serial .. " " .. home) end
                    if held ~= "" then send("wear " .. held) end
                    later(600, function() refresh(false) end)
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
                later(secs * 1000, function()
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
            utilprint("$w  /awinv wear [level]        put that set on")
            utilprint("$w  /awinv snap save|wear|del <name>   saved outfits")
            utilprint("$w  /awinv stats               learn stat ceilings from spell bonuses")
            utilprint("$w  /awinv analyze [step]      what you'd wear at every level")
            utilprint("$w  /awinv plan <slot>         upgrade path for one slot")
            utilprint("$w  /awinv usage <query>       where these items get used")
            utilprint("$w  /awinv compare <item>      is this item worth keeping")
            utilprint("$w  /awinv store <query>       put things back in their bags")
            utilprint("$w  /awinv ignore on|off <serial>      leave a bag alone")
            utilprint("$w  /awinv organize add <bag> <query>  teach a bag what it takes")
            utilprint("$w  /awinv organize run        file everything carried")
            utilprint("$w  /awinv weapon [type]       weapons ranked by damage type, plus the dual-wield pick")
            utilprint("$w  /awinv weapon wish         toggle the Weapons wish (skip skill gating)")
            utilprint("$w  /awinv consume add <name> <keyword>   name a potion you buy")
            utilprint("$w  /awinv consume <name>      drink the best one you can use")
            utilprint("$w  /awinv consume shop <name> <kw>   at a shopkeeper: record where to buy")
            utilprint("$w  /awinv consume buy <name> [n]     walk to the shop and restock")
            utilprint("$w  /awinv consume small|big <name> [n]  drink lowest / highest usable")
            utilprint("$w  /awinv consume shops       every recorded shop entry")
            utilprint("$w  /awinv prio clone <from> <to>      start from a class default")
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
    --[[
        Release everything init() created. The client tidies widgets and
        timers, but a trigger left behind keeps firing into a dead plugin,
        and a re-enable then registers a second copy of each.
    ]]
    for _, id in ipairs(trigs) do pcall(removeTrigger, id) end
    trigs = {}
    for _, id in ipairs(ids.trigs) do pcall(removeTrigger, id) end
    ids.trigs = {}
    pcall(drop_handlers, widget, "action")
    pcall(drop_handlers, widget, "submit")

    if rowTrig ~= nil then pcall(removeTrigger, rowTrig); rowTrig = nil end
    if st.blockTimer ~= nil then pcall(removeTimer, st.blockTimer); st.blockTimer = nil end
    if st.pokeTimer ~= nil then pcall(removeTimer, st.pokeTimer); st.pokeTimer = nil end
    if ids.timer ~= nil then pcall(removeTimer, ids.timer); ids.timer = nil end
    if ids.guard ~= nil then pcall(removeTimer, ids.guard); ids.guard = nil end
    if qol.watchTimer ~= nil then pcall(removeTimer, qol.watchTimer); qol.watchTimer = nil end
end
