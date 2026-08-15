--[[
    aw-bootpromo.lua
    Catdad — 2026-08-14

    Boot Lyceum promotion tracker, ported from the MUSHclient original
    (Boot_Promotion_Tracker.xml v1.9). Tracks the four promotion tiers from
    aardwolfboot.com/promotion-guide — time in clan, QP earned, campaigns
    (gquest wins count 1:1) and goals — in a panel of progress bars.

    Self-seeding the same way the original was: type 'whois' and the stats
    sync from the game's own ledger (Qp Earned, Campaigns Done, Gquests
    Won, Quests Complete); 'score' syncs Goals done. GMCP char.worth keeps
    QP live between checks — qpearned IS the official whois stat, confirmed
    identical in testing on the MUSHclient version — and campaign
    completions and your own gquest wins are counted as they land.

    The only manual input is the induction date: promo set joined YYYY-MM-DD.
    os.time exists here but its table form is not to be trusted on a
    restricted implementation, so the date becomes an epoch through plain
    days-from-civil arithmetic instead.

    The command is 'promo', matching ten years of muscle memory. It shadows
    no MUD command — clan leaders' 'promote' is a different first word, and
    registerCommand matches the word whole.
]]

plugin = {
    id          = "aw-bootpromo",
    name        = "Boot Promotion Tracker",
    version     = "2.1.0",
    author      = "Catdad",
    description = "Boot Lyceum promotion progress - days in clan, QP, campaigns and goals against each tier's bar.",
    settings    = { saveState = true },
}

-- @category widgets

local TAG  = "$w"
local TAGR = "$R! $w"

-- the tiers, per aardwolfboot.com/promotion-guide
local RANKS = {
    { name = "Neophyte > Acolyte",   days = 14,  qp = 2500,  cp = 30,  goals = 3  },
    { name = "Acolyte > Adept",      days = 42,  qp = 7500,  cp = 100, goals = 10 },
    { name = "Adept > Ascendant",    days = 90,  qp = 15000, cp = 200, goals = 15 },
    { name = "Ascendant > Savant",   days = 120, qp = 50000, cp = 350, goals = 30 },
}

--[[
    Counters all declared, zero included — an unset field is undefined on
    this client and undefined is truthy. joined is an epoch or 0.
]]
local ctr = {
    qp = 0, cp = 0, gq = 0, goals = 0, quests = 0,
    joined = 0, rank = 1,
}

local cfg = {
    fpx = 0,   -- suite font px from Core's "aw-font" broadcast
    fov = 0,   -- this panel's own font px; 0 = follow the suite
}

-- trigger ids, so cleanup can release them; a stranded trigger keeps
-- firing into a dead plugin and a re-enable registers a second copy
local trigs = {}

local function trig(pattern, fn, opts)
    local id = addTrigger(pattern, fn, opts)
    table.insert(trigs, id)
    return id
end

local widget    = nil
local view      = "bars"    -- "bars" | "settings"
local gmcpOk    = false
local whoisSelf = false

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

-- pinned px if set; otherwise scale with the panel itself (the iframe's
-- viewport is the widget, so vmin tracks a resize live), clamped readable
local function font_base()
    if cfg.fov >= 6 and cfg.fov <= 48 then return cfg.fov .. "px" end
    if cfg.fpx >= 6 and cfg.fpx <= 48 then return cfg.fpx .. "px" end
    -- floor of 14 by request; still grows with the panel past that
    return "clamp(14px, 3.4vmin, 22px)"
end

local function cap(c, w, n)
    if type(w) == "table" and type(w[tostring(n)]) == "string" then
        return w[tostring(n)]
    end
    if type(c) == "table" then
        if type(c[n]) == "string" then return c[n] end
        if type(c[n - 1]) == "string" then return c[n - 1] end
    end
    return ""
end

-- a GMCP field by name; pairs can see keys dot access cannot reach
local function gfield(t, name)
    if type(t) ~= "table" then return nil end
    -- type-tested, not `~= nil`: a key dot access cannot reach reads as
    -- undefined, and undefined ~= nil is TRUE here, which made the pairs
    -- walk below dead code and every GMCP read return nothing usable
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

local function my_name()
    local n = gfield(getGMCPData("char.base"), "name")
    return string.lower(trim(tostring(n or "")))
end

local function cur_rank()
    local n = ctr.rank
    if n < 1 then n = 1 end
    if n > #RANKS then n = #RANKS end
    return RANKS[n]
end

--[[
    Civil date to days since 1970-01-01, Hinnant's algorithm — pure
    arithmetic, nothing for the transpiler to disagree with. os.time's
    table form is exactly the kind of stdlib corner MUDFORGE-NOTES says
    not to lean on.
]]
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = m + 9
    if mp > 12 then mp = mp - 12 end
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function stamp()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then return t end
    return 0
end

local function days_in_clan()
    if ctr.joined <= 0 then return -1 end
    local t = stamp()
    if t <= 0 then return -1 end
    return math.floor((t - ctr.joined) / 86400)
end

local function save_ctr()
    saveTable("aw_bootpromo", {
        qp = ctr.qp, cp = ctr.cp, gq = ctr.gq, goals = ctr.goals,
        quests = ctr.quests, joined = ctr.joined, rank = ctr.rank,
        fpx = cfg.fpx, fov = cfg.fov,
    })
end

local function load_ctr()
    local saved = loadTable("aw_bootpromo")
    if type(saved) ~= "table" then return end
    for _, k in ipairs({ "qp", "cp", "gq", "goals", "quests", "joined", "rank" }) do
        local n = tonumber(saved[k])
        if n ~= nil and n >= 0 then ctr[k] = math.floor(n) end
    end
    local fp = tonumber(saved.fpx)
    if fp ~= nil and fp >= 6 and fp <= 48 then cfg.fpx = math.floor(fp) end
    fp = tonumber(saved.fov)
    if fp ~= nil and fp >= 6 and fp <= 48 then cfg.fov = math.floor(fp) end
end

---
-- paint
---

local CSS_HEAD = [==[
<style>
    .arc-p {
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
    .arc-p .bar {
        display: flex; align-items: center; gap: 5px;
        padding: 6px 9px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-p .ttl {
        font-size: 0.8em; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        white-space: nowrap;
    }
    .arc-p .sp { flex: 1; }
    .arc-p .tb {
        font-size: 0.75em; letter-spacing: 0.13em; text-transform: uppercase;
        padding: 3px 7px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; user-select: none; white-space: nowrap;
    }
    .arc-p .tb:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-p .body { flex: 1; min-height: 0; overflow: auto; padding: 8px 10px 10px; }
    .arc-p .req { margin: 0 0 8px; }
    .arc-p .lbl {
        display: flex; justify-content: space-between; gap: 6px;
        margin-bottom: 2px;
    }
    .arc-p .lbl .nm { color: hsl(var(--muted-foreground, 35 14% 52%)); }
    .arc-p .lbl .vl { white-space: nowrap; }
    .arc-p .vl.done { color: #3CB371; }
    .arc-p .pb {
        height: 8px; border-radius: 2px; overflow: hidden;
        background: hsl(var(--border, 0 22% 17%));
    }
    .arc-p .fill { height: 100%; }
    .arc-p .fill.prog { background: #CC7722; }
    .arc-p .fill.done { background: #3CB371; }
    .arc-p .note {
        font-size: 0.85em; line-height: 1.55; margin-top: 6px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-p .warn { color: #e0a95c; }
</style>
]==]

local function bar_html(name, have, need, unknown)
    local out = ""
    local doneClass = ""
    local valText = ""

    if unknown == true then
        valText = '<span class="warn">promo set joined YYYY-MM-DD</span>'
    else
        if have >= need then doneClass = " done" end
        valText = have .. " / " .. need
    end

    local pct = 0
    if unknown ~= true and need > 0 then
        pct = math.floor(math.min(1, have / need) * 100)
    end

    out = out .. '<div class="req"><div class="lbl"><span class="nm">' .. name
        .. '</span><span class="vl' .. doneClass .. '">' .. valText .. "</span></div>"
        .. '<div class="pb"><div class="fill' .. (doneClass ~= "" and " done" or " prog")
        .. '" style="width:' .. pct .. '%"></div></div></div>'
    return out
end

local render = nil

render = function()
    if widget == nil then return end

    local R = cur_rank()
    local body = ""

    if view == "settings" then
        body = '<div class="note">Tier: <b>' .. esc(R.name) .. "</b> ("
            .. ctr.rank .. " of " .. #RANKS .. ") &#8212; the &#9664; &#9654; "
            .. "buttons change it.<br><br>"
            .. "Sync: type <code>whois</code> (QP earned, campaigns, gquest "
            .. "wins, quests) and <code>score</code> (goals done). GMCP keeps "
            .. "QP live in between &#8212; currently "
            .. (gmcpOk and "<b>linked</b>" or '<span class="warn">not seen yet</span>')
            .. ".<br><br>Induction date: "
            .. (ctr.joined > 0 and ("set (" .. days_in_clan() .. " days ago)")
                or '<span class="warn">not set</span>')
            .. " &#8212; <code>promo set joined YYYY-MM-DD</code>.<br><br>"
            .. "<code>promo note</code> drafts the request text for the board; "
            .. "<code>promo help</code> lists everything.</div>"
    else
        local d = days_in_clan()
        body = bar_html("Days in clan", d, R.days, d < 0)
            .. bar_html("QP earned", ctr.qp, R.qp, false)
            .. bar_html("Campaigns (+" .. ctr.gq .. " gq)", ctr.cp + ctr.gq, R.cp, false)
            .. bar_html("Goals done", ctr.goals, R.goals, false)
            .. '<div class="note">' .. (gmcpOk and "gmcp live" or "text sync")
            .. " &#183; quests " .. ctr.quests
            .. " &#183; whois / score to sync</div>"
    end

    local bar = '<span class="ttl">' .. esc(R.name) .. "</span>"
        .. '<span class="sp"></span>'
        .. '<div class="tb" data-mud-action="rankdn" title="previous tier">&#9664;</div>'
        .. '<div class="tb" data-mud-action="rankup" title="next tier">&#9654;</div>'
        .. '<div class="tb" data-mud-action="note" title="draft the request text">note</div>'
        .. '<div class="tb" data-mud-action="close" title="put the panel away">hide</div>'
        .. '<div class="tb' .. (view == "settings" and " on" or "")
        .. '" data-mud-action="view" title="settings">&#9881;</div>'

    setWidgetProperty(widget, "content", CSS_HEAD
        .. '<div class="arc-p" style="font-size:' .. font_base() .. '">'
        .. '<div class="bar">' .. bar .. "</div>"
        .. '<div class="body">' .. body .. "</div></div>")
end

---
-- reports
---

local function req_line(label, have, need)
    local okc = (have >= need) and "$G" or "$Y"
    utilprint("$w  " .. (have >= need and "$G[DONE]$w " or "$Y[....]$w ")
        .. label .. ": " .. okc .. have .. "$w / " .. need)
end

local function report()
    local R = cur_rank()
    utilprint(TAG .. "tier " .. ctr.rank .. ": " .. R.name)
    local d = days_in_clan()
    if d >= 0 then
        req_line("Days in clan", d, R.days)
    else
        utilprint("$w  $Y[ ?? ]$w Days in clan: set with 'promo set joined YYYY-MM-DD'")
    end
    req_line("QP earned", ctr.qp, R.qp)
    req_line("Campaigns (gq count)", ctr.cp + ctr.gq, R.cp)
    req_line("Goals completed", ctr.goals, R.goals)
    utilprint("$w  quests " .. ctr.quests .. " | qp source: "
        .. (gmcpOk and "GMCP live" or "text sync") .. " | final step: leader task")
end

local function draft_note()
    local R = cur_rank()
    local d = days_in_clan()
    utilprint(TAG .. "draft promotion note (board personal, to Boot):")
    utilprint("$wRequesting promotion (" .. R.name .. "). My numbers:")
    utilprint("$w  Days in clan: " .. (d >= 0 and tostring(d) or "SET JOINED DATE"))
    utilprint("$w  QP earned: " .. ctr.qp)
    utilprint("$w  Campaigns completed: " .. ctr.cp .. " (plus " .. ctr.gq .. " gquest wins)")
    utilprint("$w  Goals completed: " .. ctr.goals .. " - list them here (see 'goals')")
    utilprint("$wReady for a leader task whenever convenient. Thanks!")
end

local function show_help()
    utilprint(TAG .. "Boot Lyceum promotion tracker.")
    utilprint("$w  promo                    progress report")
    utilprint("$w  promo show / hide        the progress panel")
    utilprint("$w  promo note               draft promotion-request text")
    utilprint("$w  promo rank <1-4>         which promotion to track")
    utilprint("$w  promo set joined <YYYY-MM-DD>")
    utilprint("$w  promo set qp|cp|gq|goals|quests <n>")
    utilprint("$w  promo add qp <n> | add cp | add gq | add goal")
    utilprint("$w  promo font <px>|auto     this panel's text size")
    utilprint("$w  (auto-sync: 'whois' for qp/cp/gq/quests, 'score' for goals)")
end

---
-- sync
---

local function poll_qp()
    local qe = tonumber(gfield(getGMCPData("char.worth"), "qpearned"))
    if qe == nil then return end
    gmcpOk = true
    if math.floor(qe) ~= ctr.qp then
        ctr.qp = math.floor(qe)
        save_ctr()
        render()
    end
end

local function set_counter(key, n, label)
    if n ~= nil and n ~= ctr[key] then
        ctr[key] = n
        save_ctr()
        render()
        utilprint(TAG .. label .. " synced: " .. n)
    end
end

local function whois_capture(c, w, key, label)
    if whoisSelf ~= true then return end
    set_counter(key, tonumber(cap(c, w, 1)), label)
end

local function on_whois_header(c, line, w)
    local who = string.lower(trim(cap(c, w, 1)))
    local me = my_name()
    whoisSelf = (who ~= "" and me ~= "" and who == me)
end

local function on_quest_done(c, line, w)
    ctr.quests = ctr.quests + 1
    if gmcpOk ~= true then
        local n = tonumber(cap(c, w, 1))
        if n ~= nil then ctr.qp = ctr.qp + math.floor(n) end
    end
    save_ctr()
    render()
end

local function on_cp_done(c, line, w)
    ctr.cp = ctr.cp + 1
    save_ctr()
    render()
    utilprint(TAG .. "campaign logged (total " .. ctr.cp .. ").")
end

local function on_gq_won(c, line, w)
    local winner = string.lower(trim(cap(c, w, 1)))
    local me = my_name()
    if me ~= "" and winner == me then
        ctr.gq = ctr.gq + 1
        save_ctr()
        render()
        utilprint(TAG .. "GQ WIN logged! (total " .. ctr.gq .. ")")
    end
end

---
-- setup
---

function init()
    broadcastPlugin("aw-gmcp", "Char,Comm")

    widget = createWidget({
        type     = "html",
        name     = "promo",
        title    = "Boot Promotion",
        position = { x = 220, y = 160 },
        size     = { width = 300, height = 220 },
        appearance = {
            showTitleBar        = false,
            autoHideSettingsCog = true,
            zIndex              = 9999,
        },
    })

    load_ctr()

    onPluginBroadcast(function(senderId, message, data)
        if tostring(message or "") ~= "aw-font" then return end
        local px = tonumber(data)
        px = (px ~= nil and px >= 6 and px <= 48) and math.floor(px) or 0
        if px == cfg.fpx then return end
        cfg.fpx = px
        save_ctr()
        render()
    end)

    onGMCPUpdate("char.worth", poll_qp)

    -- whois: the header line says whose whois it is; the stat lines follow
    trig("^\\[\\s*\\d+\\s+T\\d+.*?\\]\\s+(\\w+)", on_whois_header,
        { type = "regex", keepEvaluating = true })
    trig("^Qp Earned\\s*:\\s*\\[\\s*(\\d+)\\s*\\]", function(c, line, w)
        whois_capture(c, w, "qp", "QP earned")
    end, { type = "regex", keepEvaluating = true })
    trig("Campaigns Done\\s*:\\s*\\[\\s*(\\d+)\\s*\\]", function(c, line, w)
        whois_capture(c, w, "cp", "Campaigns")
    end, { type = "regex", keepEvaluating = true })
    trig("Gquests Won\\s*:\\s*\\[\\s*(\\d+)\\s*\\]", function(c, line, w)
        whois_capture(c, w, "gq", "GQuest wins")
    end, { type = "regex", keepEvaluating = true })
    trig("Quests Complete\\s*:\\s*\\[\\s*(\\d+)\\s*\\]", function(c, line, w)
        whois_capture(c, w, "quests", "Quests")
    end, { type = "regex", keepEvaluating = true })

    -- goals sync straight off 'score'; no self-check needed, score is yours
    trig("Goals done\\s*:\\s*\\[\\s*(\\d+)\\s*\\]", function(c, line, w)
        set_counter("goals", tonumber(cap(c, w, 1)), "Goals")
    end, { type = "regex", keepEvaluating = true })

    trig("As a reward, I am giving you (\\d+) quest points", on_quest_done,
        { type = "regex", keepEvaluating = true })
    trig("You have completed your campaign", on_cp_done,
        { type = "regex", keepEvaluating = true })
    trig("Global Quest.*has been won by (\\w+)", on_gq_won,
        { type = "regex", keepEvaluating = true })

    drop_handlers(widget, "action")
    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")

        if act == "close" then
            hideWidget(widget)
            return
        elseif act == "view" then
            view = (view ~= "settings") and "settings" or "bars"
        elseif act == "rankup" then
            if ctr.rank < #RANKS then ctr.rank = ctr.rank + 1; save_ctr() end
        elseif act == "rankdn" then
            if ctr.rank > 1 then ctr.rank = ctr.rank - 1; save_ctr() end
        elseif act == "note" then
            draft_note()
        end
        render()
    end)

    render()
    poll_qp()

    registerCommand("promo", function(args)
        local a = args
        if type(a) == "table" then a = table.concat(a, " ") end
        a = trim(tostring(a or ""))
        local low = string.lower(a)

        if low == "" then
            report()

        elseif low == "show" then
            showWidget(widget)
            render()

        elseif low == "hide" then
            hideWidget(widget)

        elseif low == "note" then
            draft_note()

        elseif low == "help" then
            show_help()

        elseif low == "sync" then
            poll_qp()
            utilprint(TAG .. "GMCP " .. (gmcpOk and "linked - QP earned: " .. ctr.qp
                or "not seen yet; whois still syncs everything."))

        elseif string.sub(low, 1, 5) == "rank " then
            local n = tonumber(trim(string.sub(low, 5)))
            if n ~= nil and RANKS[n] ~= nil then
                ctr.rank = n
                save_ctr()
                render()
                utilprint(TAG .. "tracking tier " .. n .. ": " .. RANKS[n].name)
            else
                utilprint(TAGR .. "usage: promo rank <1-4>")
            end

        elseif string.sub(low, 1, 11) == "set joined " then
            local ds = trim(string.sub(low, 11))
            local y, m, d = string.match(ds,
                "^([0-9][0-9][0-9][0-9])-([0-9][0-9]?)-([0-9][0-9]?)$")
            if y ~= nil then
                ctr.joined = days_from_civil(tonumber(y), tonumber(m), tonumber(d)) * 86400
                save_ctr()
                render()
                utilprint(TAG .. "joined date set to " .. ds
                    .. " (" .. days_in_clan() .. " days ago).")
            else
                utilprint(TAGR .. "format: promo set joined YYYY-MM-DD")
            end

        elseif string.sub(low, 1, 4) == "set " then
            local rest = trim(string.sub(low, 4))
            --[[
                string.find's (start, end) pair arrives as ONE array when
                assigned to a single local on this runtime (measured in
                aw-inv) - extract the start element before using it.
            ]]
            local p = string.find(rest, " ", 1, true)
            if p ~= nil and type(p) ~= "number" then
                local v = p[0]
                if v == nil then v = p["0"] end
                if v == nil then v = p[1] end
                if v == nil then v = p["1"] end
                p = tonumber(v)
            end
            local key = (p ~= nil) and string.sub(rest, 1, p - 1) or ""
            local n = (p ~= nil) and tonumber(trim(string.sub(rest, p + 1))) or nil
            if n ~= nil and (key == "qp" or key == "cp" or key == "gq"
                or key == "goals" or key == "quests") then
                ctr[key] = math.floor(n)
                save_ctr()
                render()
                utilprint(TAG .. key .. " set to " .. ctr[key] .. ".")
            else
                utilprint(TAGR .. "usage: promo set qp|cp|gq|goals|quests <n>")
            end

        elseif string.sub(low, 1, 7) == "add qp " then
            local n = tonumber(trim(string.sub(low, 7)))
            if n ~= nil then
                ctr.qp = ctr.qp + math.floor(n)
                save_ctr()
                render()
                utilprint(TAG .. "+" .. math.floor(n) .. " qp (total " .. ctr.qp .. ").")
            else
                utilprint(TAGR .. "usage: promo add qp <n>")
            end

        elseif low == "add cp" or low == "add gq" then
            local key = string.sub(low, 5)
            ctr[key] = ctr[key] + 1
            save_ctr()
            render()
            utilprint(TAG .. key .. " count: " .. ctr[key])

        elseif low == "add goal" then
            ctr.goals = ctr.goals + 1
            save_ctr()
            render()
            utilprint(TAG .. "goals: " .. ctr.goals)

        elseif string.sub(low, 1, 4) == "font" then
            local how = trim(string.sub(low, 5))
            local n = tonumber(how)
            if how == "auto" or how == "off" then
                cfg.fov = 0
            elseif how ~= "" and n ~= nil and n >= 6 and n <= 48 then
                cfg.fov = math.floor(n)
            else
                utilprint(TAG .. "usage: promo font <6-48> | auto")
                return
            end
            save_ctr()
            render()
            utilprint(TAG .. "font "
                .. (cfg.fov >= 6 and (cfg.fov .. "px for this panel.")
                    or "auto - scales with the panel (/awcore font can still pin the suite size)."))

        else
            show_help()
        end
    end, "Boot Lyceum promotion tracker - progress, sync and request drafting")
end

--[[
    Release what init registered. The client tidies widgets, but triggers
    outlive a disabled plugin and would double up on re-enable.
]]
function cleanup()
    for _, id in ipairs(trigs) do pcall(removeTrigger, id) end
    trigs = {}
    pcall(drop_handlers, widget, "action")
end
