-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- compositor (System://Services): Nexus display server, modelled on Wayland.
--
--   * Clients own their surfaces. A surface is a cell buffer (chars + fg/bg
--     colour indices, 3 bytes per cell) living in the shared Lua world, so
--     "sending a buffer" is just handing over a reference.
--   * Clients draw, then commit(). Only committed damage is composited, and
--     frames are paced by the compositor (config.fps); clients may ask for a
--     "frame" event to animate without busy-looping.
--   * Roles: "toplevel" (a window) and "layer" (background / panel / overlay,
--     with anchor + exclusive zone, like wlr-layer-shell).
--   * Policy is a plug-in: placement, tiling/floating and keybinds are
--     decided by a replaceable table (built-in "floating" / "tiling", or any
--     Lua file returning a policy). Theme, autostart and binds live in
--     System://Config/gui.lua.
--   * Input goes to the compositor only (router.grab_input); it handles
--     binds / decorations itself and forwards the rest to the focused client.
--   * Access is capability based: gui_conn / gui_surface are revoked with
--     the client process, which destroys its windows automatically.

local PALETTE_MAX = 255

local DEFAULT_CONFIG = {
    policy    = "floating",
    fps       = 20,
    autostart = { "System://Exec/gui-panel.lua" },
    theme     = {
        desktop       = 0x1B1F2A,
        title_fg      = 0xFFFFFF, title_bg      = 0x3B6EA5,
        title_fg_idle = 0xA0A8B8, title_bg_idle = 0x2E3440,
        border        = 0x3B6EA5, border_idle   = 0x2E3440,
        close_fg      = 0xFFFFFF, close_bg      = 0xB04050,
        hchar = "-", vchar = "|",
    },
    -- "mod" is the compositor modifier. Plain Alt+<key> collides with the
    -- host / game system keys, so the default is Alt+Shift.
    mod = "alt+shift",
    binds = {
        ["mod+j"]     = "focus_next",
        ["mod+k"]     = "focus_prev",
        ["mod+q"]     = "close",
        ["mod+m"]     = "maximize",
        ["mod+e"]     = "quit",
        ["mod+enter"] = { spawn = "System://Exec/gui-term.lua" },
        ["mod+d"]     = { spawn = "System://Exec/gui-hello.lua" },
        ["mod+t"]     = { policy = "tiling" },
        ["mod+f"]     = { policy = "floating" },
    },
}

-- ------------------------------------------------------------
--  Colour palette (cells store 1-byte indices)
-- ------------------------------------------------------------

local pal, pal_idx = {}, {}

local function color_index(rgb)
    local i = pal_idx[rgb]
    if i then return i end
    if #pal < PALETTE_MAX then
        pal[#pal + 1] = rgb
        pal_idx[rgb] = #pal
        return #pal
    end
    local r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
    local best, best_d
    for k, c in ipairs(pal) do
        local dr, dg, db = ((c >> 16) & 255) - r, ((c >> 8) & 255) - g, (c & 255) - b
        local d = dr * dr + dg * dg + db * db
        if not best_d or d < best_d then best, best_d = k, d end
    end
    pal_idx[rgb] = best
    return best
end

-- ------------------------------------------------------------
--  Cell buffers. Rows are immutable triples { chars, fg, bg } that are
--  replaced (never edited in place), so blank rows can be shared.
-- ------------------------------------------------------------

local function blank_row(w, fi, bi)
    return { string.rep(" ", w), string.rep(string.char(fi), w), string.rep(string.char(bi), w) }
end

local function buf_new(w, h, fi, bi)
    local rows, blank = {}, blank_row(w, fi, bi)
    for y = 1, h do rows[y] = blank end
    return { w = w, h = h, rows = rows }
end

local function buf_set(b, x, y, text, fi, bi)
    if y < 1 or y > b.h then return end
    text = text:gsub("%c", " ")
    if x < 1 then
        text = text:sub(2 - x)
        x = 1
    end
    local n = math.min(#text, b.w - x + 1)
    if n <= 0 then return end
    text = text:sub(1, n)
    local r = b.rows[y]
    local after = x + n
    b.rows[y] = {
        r[1]:sub(1, x - 1) .. text .. r[1]:sub(after),
        r[2]:sub(1, x - 1) .. string.rep(string.char(fi), n) .. r[2]:sub(after),
        r[3]:sub(1, x - 1) .. string.rep(string.char(bi), n) .. r[3]:sub(after),
    }
end

local function buf_fill(b, x, y, w, h, ch, fi, bi)
    if w <= 0 then return end
    local line = string.rep(ch:sub(1, 1), math.min(w, b.w))
    for yy = y, y + h - 1 do buf_set(b, x, yy, line, fi, bi) end
end

local function buf_resize(b, nw, nh, fi, bi)
    local blank = blank_row(nw, fi, bi)
    local rows = {}
    for y = 1, nh do
        local r = b.rows[y]
        if not r then
            rows[y] = blank
        elseif nw <= b.w then
            rows[y] = { r[1]:sub(1, nw), r[2]:sub(1, nw), r[3]:sub(1, nw) }
        else
            local pad = nw - b.w
            rows[y] = {
                r[1] .. string.rep(" ", pad),
                r[2] .. string.rep(string.char(fi), pad),
                r[3] .. string.rep(string.char(bi), pad),
            }
        end
    end
    b.w, b.h, b.rows = nw, nh, rows
end

-- ------------------------------------------------------------
--  State
-- ------------------------------------------------------------

local config
local theme
local policy
local gpu, screen_addr
local W, H = 80, 25
local comp_pid = process_manager.self()

local wins = {}            -- every window, creation order
local z_top = {}           -- toplevel windows, bottom -> top
local order = {}           -- render order (rebuilt on change)
local focused              -- focused toplevel window
local next_id = 1
local damage = {}
local dirty, last_frame, wake_pending = false, 0, false
local mods = { shift = false, ctrl = false, alt = false }
local pointer_grab         -- { win, mode = "move"|"resize"|"client", ox, oy }
local quit_flag = false
local usable = { x = 1, y = 1, w = 80, h = 25 }
local ctx

local LAYER_RANK = { background = 1, bottom = 2, top = 4, overlay = 5 }

local function wake()
    if not wake_pending then
        wake_pending = true
        router.push_to(comp_pid, { type = "gui_wake" })
    end
end

local function add_damage(x1, y1, x2, y2)
    x1, y1 = math.max(1, x1), math.max(1, y1)
    x2, y2 = math.min(W, x2), math.min(H, y2)
    if x1 > x2 or y1 > y2 then return end
    damage[#damage + 1] = { x1, y1, x2, y2 }
    dirty = true
    wake()
end

local function damage_window(win)
    add_damage(win.x, win.y, win.x + win.ow - 1, win.y + win.oh - 1)
end

local function send(core, kind, fields)
    local ev = fields or {}
    ev.type, ev.kind, ev.surface = "gui", kind, core.id
    router.push_to(core.pid, ev)
end

local function rebuild_order()
    order = {}
    for rank = 1, 2 do
        for _, w in ipairs(wins) do
            if w.kind == "layer" and w.rank == rank then order[#order + 1] = w end
        end
    end
    for _, w in ipairs(z_top) do order[#order + 1] = w end
    for rank = 4, 5 do
        for _, w in ipairs(wins) do
            if w.kind == "layer" and w.rank == rank then order[#order + 1] = w end
        end
    end
end

-- ------------------------------------------------------------
--  Window geometry
-- ------------------------------------------------------------

local function update_outer(win)
    local b = win.core.buf
    if win.deco then
        win.ow, win.oh = b.w + 2, b.h + 2
    else
        win.ow, win.oh = b.w, b.h
    end
    win.deco_cache = nil
end

local function set_geometry(win, x, y, cw, ch)
    cw, ch = math.max(1, math.floor(cw)), math.max(1, math.floor(ch))
    x, y = math.floor(x), math.floor(y)
    if x == win.x and y == win.y and cw == win.core.buf.w and ch == win.core.buf.h then return end
    if win.mapped then damage_window(win) end
    win.x, win.y = math.floor(x), math.floor(y)
    local b = win.core.buf
    if b.w ~= cw or b.h ~= ch then
        buf_resize(b, cw, ch, win.core.bg_i, win.core.bg_i)
        send(win.core, "configure", { w = cw, h = ch, focused = win.focused })
    end
    update_outer(win)
    if win.mapped then damage_window(win) end
end

local function recompute_usable()
    local u = { x = 1, y = 1, w = W, h = H }
    for _, w in ipairs(wins) do
        if w.kind == "layer" and w.exclusive then
            if w.anchor == "top" then
                u.y, u.h = u.y + w.size, u.h - w.size
            elseif w.anchor == "bottom" then
                u.h = u.h - w.size
            elseif w.anchor == "left" then
                u.x, u.w = u.x + w.size, u.w - w.size
            elseif w.anchor == "right" then
                u.w = u.w - w.size
            end
        end
    end
    usable = u
    return u
end

local function layer_geometry(win)
    local s, a = win.size, win.anchor
    if a == "fill" then return 1, 1, W, H end
    if a == "top" then return 1, 1, W, s end
    if a == "bottom" then return 1, H - s + 1, W, s end
    if a == "left" then return 1, 1, s, H end
    return W - s + 1, 1, s, H   -- right
end

local function layout_layers()
    for _, w in ipairs(wins) do
        if w.kind == "layer" then
            local x, y, cw, ch = layer_geometry(w)
            set_geometry(w, x, y, cw, ch)
        end
    end
    recompute_usable()
end

-- ------------------------------------------------------------
--  Focus / stacking
-- ------------------------------------------------------------

local function mark_deco(win)
    win.deco_cache = nil
    if win.mapped and win.deco then
        add_damage(win.x, win.y, win.x + win.ow - 1, win.y)
    end
end

local function focus(win)
    if win == focused then return end
    local old = focused
    focused = win
    if old then
        old.focused = false
        mark_deco(old)
        send(old.core, "focus", { focused = false })
    end
    if win then
        win.focused = true
        mark_deco(win)
        send(win.core, "focus", { focused = true })
    end
end

local function raise(win)
    for i, w in ipairs(z_top) do
        if w == win then
            if i ~= #z_top then
                table.remove(z_top, i)
                z_top[#z_top + 1] = win
                rebuild_order()
                damage_window(win)
            end
            return
        end
    end
end

local function mapped_toplevels()
    local out = {}
    for _, w in ipairs(z_top) do
        if w.mapped then out[#out + 1] = w end
    end
    return out
end

local function focus_cycle(dir)
    local list = {}
    for _, w in ipairs(wins) do
        if w.kind == "toplevel" and w.mapped then list[#list + 1] = w end
    end
    if #list == 0 then return end
    local idx = 0
    for i, w in ipairs(list) do if w == focused then idx = i end end
    local nxt = list[((idx - 1 + dir) % #list) + 1]
    raise(nxt)
    focus(nxt)
end

-- ------------------------------------------------------------
--  Policies
-- ------------------------------------------------------------

local policies = {}

policies.floating = {
    name = "floating",
    floating = true,
    place = function(c, win, rw, rh)
        local u = c.usable()
        local n = #c.toplevels()
        local cw = math.min(rw, u.w - 2)
        local ch = math.min(rh, u.h - 2)
        local x = u.x + (n * 3) % math.max(1, u.w - cw - 1)
        local y = u.y + (n * 2) % math.max(1, u.h - ch - 1)
        return x, y, cw, ch
    end,
    arrange = function(c)
        -- keep windows inside the usable area (e.g. after a panel appeared)
        local u = c.usable()
        for _, w in ipairs(c.toplevels()) do
            local nx = math.max(u.x, math.min(w.x, u.x + u.w - w.ow))
            local ny = math.max(u.y, math.min(w.y, u.y + u.h - w.oh))
            if nx ~= w.x or ny ~= w.y then c.set_geometry(w, nx, ny, w.core.buf.w, w.core.buf.h) end
        end
    end,
}

policies.tiling = {
    name = "tiling",
    floating = false,
    place = function(c, win, rw, rh)
        local u = c.usable()
        return u.x, u.y, u.w - 2, u.h - 2
    end,
    -- master (left, ~55%) + stack (right, split vertically)
    arrange = function(c)
        local u = c.usable()
        local list = c.toplevels()
        local n = #list
        if n == 0 then return end
        if n == 1 then
            c.set_geometry(list[1], u.x, u.y, u.w - 2, u.h - 2)
            return
        end
        local mw = math.floor(u.w * 0.55)
        c.set_geometry(list[1], u.x, u.y, mw - 2, u.h - 2)
        local rest = n - 1
        local sw = u.w - mw
        local hh = math.floor(u.h / rest)
        for i = 2, n do
            local y = u.y + (i - 2) * hh
            local h = (i == n) and (u.y + u.h - y) or hh
            c.set_geometry(list[i], u.x + mw, y, sw - 2, h - 2)
        end
    end,
}

local function load_policy(spec)
    if type(spec) == "table" then return spec end
    if policies[spec] then return policies[spec] end
    local src = fs.read_file(spec)
    if not src then return nil, "cannot read policy '" .. tostring(spec) .. "'" end
    local fn, err = load(src, "@" .. spec, "t", _ENV)
    if not fn then return nil, err end
    local ok, res = pcall(fn)
    if not ok then return nil, res end
    if type(res) ~= "table" then return nil, "policy file must return a table" end
    return res
end

local function arrange()
    if policy.arrange then
        local ok, err = pcall(policy.arrange, ctx)
        if not ok then log.warn("[compositor] policy.arrange failed: %s", tostring(err)) end
    end
end

-- ------------------------------------------------------------
--  Rendering
-- ------------------------------------------------------------

local function deco_pieces(win)
    local c = win.deco_cache
    if c then return c end
    local ow = win.ow
    local f = win.focused
    local tfg = color_index(f and theme.title_fg or theme.title_fg_idle)
    local tbg = color_index(f and theme.title_bg or theme.title_bg_idle)
    local bfg = color_index(f and theme.border or theme.border_idle)
    local cfg, cbg = color_index(theme.close_fg), color_index(theme.close_bg)

    local text = (" " .. (win.core.title or "")):sub(1, ow - 3)
    text = text .. string.rep(" ", ow - 3 - #text)
    c = {
        title = {
            text .. "[x]",
            string.rep(string.char(tfg), ow - 3) .. string.rep(string.char(cfg), 3),
            string.rep(string.char(tbg), ow - 3) .. string.rep(string.char(cbg), 3),
        },
        bottom = {
            string.rep(theme.hchar, ow),
            string.rep(string.char(bfg), ow),
            string.rep(string.char(color_index(theme.desktop)), ow),
        },
        side_fg = string.char(bfg),
        side_bg = string.char(color_index(theme.desktop)),
    }
    win.deco_cache = c
    return c
end

-- chars / fg / bg strings for screen columns a..b of row y inside `win`
local function sample(win, y, a, b)
    local rx1, rx2 = a - win.x + 1, b - win.x + 1
    local ry = y - win.y + 1
    local buf = win.core.buf
    if not win.deco then
        local r = buf.rows[ry]
        return r[1]:sub(rx1, rx2), r[2]:sub(rx1, rx2), r[3]:sub(rx1, rx2)
    end
    local d = deco_pieces(win)
    if ry == 1 then
        return d.title[1]:sub(rx1, rx2), d.title[2]:sub(rx1, rx2), d.title[3]:sub(rx1, rx2)
    elseif ry == win.oh then
        return d.bottom[1]:sub(rx1, rx2), d.bottom[2]:sub(rx1, rx2), d.bottom[3]:sub(rx1, rx2)
    end
    local r = buf.rows[ry - 1]
    local v = theme.vchar
    return (v .. r[1] .. v):sub(rx1, rx2),
           (d.side_fg .. r[2] .. d.side_fg):sub(rx1, rx2),
           (d.side_bg .. r[3] .. d.side_bg):sub(rx1, rx2)
end

local cur_fg, cur_bg

local function gpu_text(x, y, text, fi, bi)
    if fi ~= cur_fg then
        gpu.set_fg(pal[fi])
        cur_fg = fi
    end
    if bi ~= cur_bg then
        gpu.set_bg(pal[bi])
        cur_bg = bi
    end
    gpu.set(x, y, text)
end

-- composite screen row y, columns x1..x2, and send it to the GPU
local function draw_span(y, x1, x2)
    local pieces = {}
    local segs = { { x1, x2 } }
    for i = #order, 1, -1 do
        local w = order[i]
        if w.mapped and y >= w.y and y <= w.y + w.oh - 1 then
            local wx1, wx2 = w.x, w.x + w.ow - 1
            local nsegs = {}
            for _, s in ipairs(segs) do
                local a, b = math.max(s[1], wx1), math.min(s[2], wx2)
                if a <= b then
                    local ch, fg, bg = sample(w, y, a, b)
                    pieces[#pieces + 1] = { a, ch, fg, bg }
                    if s[1] < a then nsegs[#nsegs + 1] = { s[1], a - 1 } end
                    if b < s[2] then nsegs[#nsegs + 1] = { b + 1, s[2] } end
                else
                    nsegs[#nsegs + 1] = s
                end
            end
            segs = nsegs
            if #segs == 0 then break end
        end
    end
    if #segs > 0 then
        local di = color_index(theme.desktop)
        for _, s in ipairs(segs) do
            local n = s[2] - s[1] + 1
            pieces[#pieces + 1] = { s[1], string.rep(" ", n), string.rep(string.char(di), n), string.rep(string.char(di), n) }
        end
    end
    table.sort(pieces, function(p, q) return p[1] < q[1] end)

    -- split into same-colour runs, merging neighbours, then draw
    local run
    local function flush()
        if run then gpu_text(run.x, y, table.concat(run.parts), run.fg, run.bg) end
        run = nil
    end
    for _, p in ipairs(pieces) do
        local ch, fgs, bgs = p[2], p[3], p[4]
        local n = #ch
        local fb, bb = { fgs:byte(1, n) }, { bgs:byte(1, n) }
        local start = 1
        for i = 2, n + 1 do
            if i > n or fb[i] ~= fb[start] or bb[i] ~= bb[start] then
                local x = p[1] + start - 1
                local text = ch:sub(start, i - 1)
                if run and run.next == x and run.fg == fb[start] and run.bg == bb[start] then
                    run.parts[#run.parts + 1] = text
                    run.next = x + #text
                else
                    flush()
                    run = { x = x, parts = { text }, fg = fb[start], bg = bb[start], next = x + #text }
                end
                start = i
            end
        end
    end
    flush()
end

local function merge_damage()
    if #damage > 6 then
        local x1, y1, x2, y2 = W, H, 1, 1
        for _, r in ipairs(damage) do
            x1, y1 = math.min(x1, r[1]), math.min(y1, r[2])
            x2, y2 = math.max(x2, r[3]), math.max(y2, r[4])
        end
        damage = { { x1, y1, x2, y2 } }
    end
    local rects = damage
    damage = {}
    return rects
end

local function render_frame()
    dirty = false
    last_frame = computer.uptime()
    local rects = merge_damage()
    if not gpu or not capability.is_valid(gpu) then return end
    cur_fg, cur_bg = nil, nil
    local ok, err = pcall(function()
        for _, r in ipairs(rects) do
            for y = r[2], r[4] do draw_span(y, r[1], r[3]) end
        end
    end)
    if not ok then log.warn("[compositor] render failed: %s", tostring(err)) end
    for _, w in ipairs(wins) do
        if w.core.frame_requested then
            w.core.frame_requested = false
            send(w.core, "frame", { time = last_frame })
        end
    end
end

local function full_redraw()
    damage = {}
    add_damage(1, 1, W, H)
end

-- ------------------------------------------------------------
--  Window lifecycle
-- ------------------------------------------------------------

local function remove_window(win)
    for i, w in ipairs(wins) do if w == win then table.remove(wins, i) break end end
    for i, w in ipairs(z_top) do if w == win then table.remove(z_top, i) break end end
    rebuild_order()
    if win.mapped then damage_window(win) end
    if pointer_grab and pointer_grab.win == win then pointer_grab = nil end
    if focused == win then
        focused = nil
        local top = z_top[#z_top]
        if top then focus(top) end
    end
    if win.kind == "layer" then layout_layers() end
    arrange()
end

local function create_window(core, role, opts)
    opts = opts or {}
    local win = {
        id = core.id, core = core, kind = role, mapped = false, focused = false,
        x = 1, y = 1, ow = 1, oh = 1,
    }
    core.win = win
    if role == "toplevel" then
        win.deco = opts.decorations ~= false
        win.rank = 3
        core.title = opts.title or core.title or "window"
        wins[#wins + 1] = win
        z_top[#z_top + 1] = win
        rebuild_order()
        local rw, rh = opts.w or 40, opts.h or 12
        local x, y, cw, ch = policy.place(ctx, win, rw, rh)
        set_geometry(win, x, y, cw, ch)
        send(core, "configure", { w = core.buf.w, h = core.buf.h, focused = false })
        arrange()
    else
        win.deco = false
        win.rank = LAYER_RANK[opts.layer or "top"] or 4
        win.anchor = opts.anchor or "top"
        win.size = opts.size or 1
        win.exclusive = opts.exclusive == true
        wins[#wins + 1] = win
        rebuild_order()
        layout_layers()
        arrange()
        send(core, "configure", { w = core.buf.w, h = core.buf.h, focused = false })
    end
    return win
end

local function map_window(win)
    win.mapped = true
    update_outer(win)
    damage_window(win)
    if win.kind == "toplevel" then
        raise(win)
        focus(win)
    end
end

-- ------------------------------------------------------------
--  Policy context
-- ------------------------------------------------------------

local function close_window(win)
    send(win.core, "close")
end

local function maximize(win)
    if win.kind ~= "toplevel" then return end
    local u = recompute_usable()
    if win.saved then
        local s = win.saved
        win.saved = nil
        set_geometry(win, s.x, s.y, s.cw, s.ch)
    else
        win.saved = { x = win.x, y = win.y, cw = win.core.buf.w, ch = win.core.buf.h }
        local d = win.deco and 2 or 0
        set_geometry(win, u.x, u.y, u.w - d, u.h - d)
    end
end

local function spawn(path, args)
    local ok, pid = pcall(process_manager.spawn, { path = path, args = args or {}, detached = false })
    if not ok then log.warn("[compositor] spawn %s failed: %s", tostring(path), tostring(pid)) end
    return ok and pid or nil
end

local function set_policy(spec)
    local p, err = load_policy(spec)
    if not p then
        log.warn("[compositor] policy not loaded: %s", tostring(err))
        return false, err
    end
    policy = p
    for _, w in ipairs(z_top) do
        if w.saved then w.saved = nil end
    end
    log.info("[compositor] policy: %s", tostring(p.name or spec))
    arrange()
    full_redraw()
    return true
end

local function quit()
    quit_flag = true
    wake()
end

ctx = {
    usable        = function() return usable end,
    toplevels     = mapped_toplevels,
    set_geometry  = set_geometry,
    focus         = function(w) raise(w) focus(w) end,
    focused       = function() return focused end,
    close         = close_window,
    maximize      = maximize,
    spawn         = spawn,
    set_policy    = set_policy,
    quit          = quit,
    output        = function() return W, H end,
    mods          = mods,
}

-- ------------------------------------------------------------
--  Input
-- ------------------------------------------------------------

local KEY_NAMES = {
    [15] = "tab", [28] = "enter", [57] = "space", [1] = "escape", [14] = "backspace",
    [203] = "left", [205] = "right", [200] = "up", [208] = "down",
    [16] = "q", [17] = "w", [18] = "e", [19] = "r", [20] = "t", [21] = "y", [22] = "u", [23] = "i",
    [24] = "o", [25] = "p", [30] = "a", [31] = "s", [32] = "d", [33] = "f", [34] = "g", [35] = "h",
    [36] = "j", [37] = "k", [38] = "l", [44] = "z", [45] = "x", [46] = "c", [47] = "v", [48] = "b",
    [49] = "n", [50] = "m",
    [2] = "1", [3] = "2", [4] = "3", [5] = "4", [6] = "5", [7] = "6", [8] = "7", [9] = "8", [10] = "9", [11] = "0",
    [59] = "f1", [60] = "f2", [61] = "f3", [62] = "f4", [63] = "f5", [64] = "f6",
    [65] = "f7", [66] = "f8", [67] = "f9", [68] = "f10",
}

local MOD_CODES = {
    [42] = "shift", [54] = "shift", [29] = "ctrl", [157] = "ctrl", [56] = "alt", [184] = "alt",
}

-- "Mod+Return", "alt+shift+E" ... -> "alt+shift+enter" (fixed modifier order).
-- "mod" expands to config.mod.
local KEY_ALIASES = { ["return"] = "enter", esc = "escape" }

local function canonical_bind(spec, mod_spec)
    local flags, key = {}, nil
    local function add(part)
        part = part:lower()
        if part == "ctrl" or part == "alt" or part == "shift" then
            flags[part] = true
        elseif part ~= "" then
            key = KEY_ALIASES[part] or part
        end
    end
    for part in spec:gmatch("[^+]+") do
        if part:lower() == "mod" and mod_spec then
            for p in mod_spec:gmatch("[^+]+") do add(p) end
        else
            add(part)
        end
    end
    if not key then return nil end
    local out = {}
    for _, m in ipairs({ "ctrl", "alt", "shift" }) do
        if flags[m] then out[#out + 1] = m end
    end
    out[#out + 1] = key
    return table.concat(out, "+")
end

local function bind_name(code)
    local key = KEY_NAMES[code]
    if not key then return nil end
    local parts = {}
    if mods.ctrl then parts[#parts + 1] = "ctrl" end
    if mods.alt then parts[#parts + 1] = "alt" end
    if mods.shift then parts[#parts + 1] = "shift" end
    parts[#parts + 1] = key
    return table.concat(parts, "+")
end

local function run_action(action)
    if type(action) == "function" then
        local ok, err = pcall(action, ctx)
        if not ok then log.warn("[compositor] bind failed: %s", tostring(err)) end
    elseif action == "focus_next" then focus_cycle(1)
    elseif action == "focus_prev" then focus_cycle(-1)
    elseif action == "close" then if focused then close_window(focused) end
    elseif action == "maximize" then if focused then maximize(focused) end
    elseif action == "quit" then quit()
    elseif type(action) == "table" then
        if action.spawn then spawn(action.spawn, action.args) end
        if action.policy then set_policy(action.policy) end
    end
end

local function handle_key(ev, down)
    local char, code = ev.data[3], ev.data[4]
    local m = MOD_CODES[code]
    if m then mods[m] = down end

    if down then
        local name = bind_name(code)
        local action = name and config.binds[name]
        if action then
            run_action(action)
            return
        end
        if policy.key then
            local ok, handled = pcall(policy.key, ctx, ev)
            if ok and handled then return end
        end
    end
    if focused then
        send(focused.core, "key", {
            down = down, char = char, code = code,
            shift = mods.shift, ctrl = mods.ctrl, alt = mods.alt,
        })
    end
end

local function hit_test(x, y)
    for i = #order, 1, -1 do
        local w = order[i]
        if w.mapped and w.rank ~= 1 and x >= w.x and x < w.x + w.ow and y >= w.y and y < w.y + w.oh then
            local dx, dy = x - w.x, y - w.y
            if w.deco then
                if dy == 0 then
                    return w, (dx >= w.ow - 3) and "close" or "title", 0, 0
                elseif dy == w.oh - 1 then
                    return w, (dx >= w.ow - 2) and "resize" or "border", 0, 0
                elseif dx == 0 or dx == w.ow - 1 then
                    return w, "border", 0, 0
                end
                return w, "content", dx, dy
            end
            return w, "content", dx + 1, dy + 1
        end
    end
    return nil
end

-- a minus b (rectangles {x1, y1, x2, y2}); returns up to 4 rectangles
local function rect_subtract(a, b)
    if b[1] > a[3] or b[3] < a[1] or b[2] > a[4] or b[4] < a[2] then return { a } end
    local out = {}
    if b[2] > a[2] then out[#out + 1] = { a[1], a[2], a[3], b[2] - 1 } end
    if b[4] < a[4] then out[#out + 1] = { a[1], b[4] + 1, a[3], a[4] } end
    local y1, y2 = math.max(a[2], b[2]), math.min(a[4], b[4])
    if b[1] > a[1] then out[#out + 1] = { a[1], y1, b[1] - 1, y2 } end
    if b[3] < a[3] then out[#out + 1] = { b[3] + 1, y1, a[3], y2 } end
    return out
end

local function rects_intersect(a, b)
    return not (b[1] > a[3] or b[3] < a[1] or b[2] > a[4] or b[4] < a[2])
end

-- Move a window. When nothing is stacked above it, the already-rendered pixels
-- are moved with one gpu.copy and only the newly exposed / newly visible
-- strips are composited again (instead of redrawing the whole window twice).
local function move_window(win, nx, ny)
    if nx == win.x and ny == win.y then return end
    local dx, dy = nx - win.x, ny - win.y
    local old = { win.x, win.y, win.x + win.ow - 1, win.y + win.oh - 1 }
    local new = { nx, ny, nx + win.ow - 1, ny + win.oh - 1 }

    local blit = win.mapped and gpu and capability.is_valid(gpu)
    if blit then
        local above = false
        for i = #order, 1, -1 do
            local w = order[i]
            if w == win then break end
            if w.mapped and (rects_intersect(old, { w.x, w.y, w.x + w.ow - 1, w.y + w.oh - 1 })
                or rects_intersect(new, { w.x, w.y, w.x + w.ow - 1, w.y + w.oh - 1 })) then
                above = true
                break
            end
        end
        blit = not above
    end

    if blit then
        if dirty then render_frame() end            -- screen must match the buffers
        local sx1, sy1 = math.max(1, old[1], 1 - dx), math.max(1, old[2], 1 - dy)
        local sx2, sy2 = math.min(W, old[3], W - dx), math.min(H, old[4], H - dy)
        if sx1 <= sx2 and sy1 <= sy2 then
            gpu.copy(sx1, sy1, sx2 - sx1 + 1, sy2 - sy1 + 1, dx, dy)
            win.x, win.y = nx, ny
            local dest = { sx1 + dx, sy1 + dy, sx2 + dx, sy2 + dy }
            for _, r in ipairs(rect_subtract({ math.max(1, old[1]), math.max(1, old[2]), math.min(W, old[3]), math.min(H, old[4]) }, new)) do
                add_damage(r[1], r[2], r[3], r[4])
            end
            for _, r in ipairs(rect_subtract({ math.max(1, new[1]), math.max(1, new[2]), math.min(W, new[3]), math.min(H, new[4]) }, dest)) do
                add_damage(r[1], r[2], r[3], r[4])
            end
            return
        end
    end

    damage_window(win)
    win.x, win.y = nx, ny
    damage_window(win)
end

local function send_pointer(win, action, lx, ly, button, extra)
    local ev = { action = action, x = lx, y = ly, button = button }
    if extra then for k, v in pairs(extra) do ev[k] = v end end
    send(win.core, "pointer", ev)
end

local function handle_pointer(ev)
    local kind = ev.type
    local x, y = math.floor(ev.data[3] or 0), math.floor(ev.data[4] or 0)

    if kind == "scroll" then
        local win, region, lx, ly = hit_test(x, y)
        log.debug("[compositor] scroll at %d,%d dir=%s -> %s/%s", x, y, tostring(ev.data[5]),
            win and tostring(win.core.title) or "none", tostring(region))
        if win and region == "content" then
            send_pointer(win, "scroll", lx, ly, nil, { dir = ev.data[5] })
        end
        return
    end

    local button = ev.data[5]
    if kind == "touch" then
        local win, region, lx, ly = hit_test(x, y)
        if not win then return end
        if policy.pointer then
            local ok, handled = pcall(policy.pointer, ctx, ev, win, region)
            if ok and handled then return end
        end
        if win.kind == "toplevel" then
            raise(win)
            focus(win)
        end
        if region == "close" then
            close_window(win)
        elseif region == "title" and policy.floating then
            pointer_grab = { win = win, mode = "move", ox = x - win.x, oy = y - win.y }
        elseif region == "resize" and policy.floating then
            pointer_grab = { win = win, mode = "resize" }
        elseif region == "content" then
            pointer_grab = { win = win, mode = "client", button = button }
            send_pointer(win, "down", lx, ly, button)
        end
    elseif kind == "drag" then
        local g = pointer_grab
        if not g then return end
        local win = g.win
        if g.mode == "move" then
            local u = usable
            local nx = math.max(1 - win.ow + 4, math.min(x - g.ox, W - 3))
            local ny = math.max(u.y, math.min(y - g.oy, H))
            move_window(win, nx, ny)
        elseif g.mode == "resize" then
            local cw = math.max(8, x - win.x)        -- keep room for the title bar
            local ch = math.max(3, y - win.y - 1)
            set_geometry(win, win.x, win.y, cw, ch)
        elseif g.mode == "client" then
            local lx = x - win.x + (win.deco and 0 or 1)
            local ly = y - win.y + (win.deco and 0 or 1)
            send_pointer(win, "drag", lx, ly, g.button)
        end
    elseif kind == "drop" then
        local g = pointer_grab
        pointer_grab = nil
        if g and g.mode == "client" then
            local win = g.win
            local lx = x - win.x + (win.deco and 0 or 1)
            local ly = y - win.y + (win.deco and 0 or 1)
            send_pointer(win, "up", lx, ly, g.button)
        end
    end
end

-- ------------------------------------------------------------
--  Client API (capabilities)
-- ------------------------------------------------------------

local function surface_damage(core, x1, y1, x2, y2)
    local d = core.pending
    d[#d + 1] = { x1, y1, x2, y2 }
end

local function resolve_colors(core, fg, bg)
    return fg and color_index(fg) or core.fg_i, bg and color_index(bg) or core.bg_i
end

local function destroy_surface(core)
    if core.dead then return end
    core.dead = true
    if core.win then remove_window(core.win) end
end

capability.register("gui_surface", {
    ops = {
        "id", "size", "set", "fill", "clear", "scroll", "colors", "title", "role", "commit",
        "request_frame", "destroy", "maximize",
        draw = { "size", "set", "fill", "clear", "scroll", "colors", "commit" },
    },
    new = function(core)
        local api = {}
        function api.id() return core.id end
        function api.size() return core.buf.w, core.buf.h end
        function api.colors(fg, bg)
            if fg then core.fg_i = color_index(fg) end
            if bg then core.bg_i = color_index(bg) end
        end
        function api.set(x, y, text, fg, bg)
            local fi, bi = resolve_colors(core, fg, bg)
            text = tostring(text)
            buf_set(core.buf, x, y, text, fi, bi)
            surface_damage(core, x, y, x + #text - 1, y)
        end
        function api.fill(x, y, w, h, ch, fg, bg)
            local fi, bi = resolve_colors(core, fg, bg)
            buf_fill(core.buf, x, y, w, h, ch or " ", fi, bi)
            surface_damage(core, x, y, x + w - 1, y + h - 1)
        end
        function api.clear(bg)
            if bg then core.bg_i = color_index(bg) end
            buf_fill(core.buf, 1, 1, core.buf.w, core.buf.h, " ", core.fg_i, core.bg_i)
            surface_damage(core, 1, 1, core.buf.w, core.buf.h)
        end
        -- scroll the content up by n lines (down if n < 0); new lines are blank
        function api.scroll(n)
            n = math.floor(tonumber(n) or 1)
            local b = core.buf
            if n == 0 then return end
            if math.abs(n) >= b.h then
                api.clear()
                return
            end
            local blank = blank_row(b.w, core.fg_i, core.bg_i)
            local rows = b.rows
            if n > 0 then
                for i = 1, b.h - n do rows[i] = rows[i + n] end
                for i = b.h - n + 1, b.h do rows[i] = blank end
            else
                for i = b.h, 1 - n, -1 do rows[i] = rows[i + n] end
                for i = 1, -n do rows[i] = blank end
            end
            surface_damage(core, 1, 1, b.w, b.h)
        end
        function api.title(t)
            core.title = tostring(t)
            if core.win then mark_deco(core.win) end
        end
        function api.role(role, opts)
            if core.win then error("surface already has a role", 2) end
            if role ~= "toplevel" and role ~= "layer" then
                error("unknown role '" .. tostring(role) .. "'", 2)
            end
            create_window(core, role, opts)
        end
        function api.commit()
            local win = core.win
            if not win then return end
            if not win.mapped then
                core.pending = {}
                map_window(win)
                return
            end
            local ox, oy = win.x, win.y
            if win.deco then ox, oy = ox + 1, oy + 1 end
            for _, r in ipairs(core.pending) do
                add_damage(ox + r[1] - 1, oy + r[2] - 1, ox + r[3] - 1, oy + r[4] - 1)
            end
            core.pending = {}
        end
        function api.request_frame()
            core.frame_requested = true
            wake()
        end
        function api.maximize()
            if core.win then maximize(core.win) end
        end
        function api.destroy()
            capability.revoke(api._mt)
        end
        api._core = core
        return api
    end,
    dispose = function(api)
        destroy_surface(api._core)
    end,
})

local function new_surface(pid)
    local core = {
        id = next_id, pid = pid, title = "", pending = {},
        fg_i = color_index(0xFFFFFF), bg_i = color_index(0x000000),
        buf = nil, frame_requested = false, dead = false,
    }
    next_id = next_id + 1
    core.buf = buf_new(1, 1, core.fg_i, core.bg_i)
    local cap, mt = capability.create("gui_surface", nil, core)
    core.mt = mt
    return cap, core
end

local connections = {}   -- pid -> conn core

capability.register("gui_conn", {
    ops = { "globals", "output", "create_surface", "toplevels", "disconnect" },
    new = function(pid)
        local conn = { pid = pid, surfaces = {} }
        connections[pid] = conn
        local api = { _conn = conn }
        function api.globals()
            return { "surface", "toplevel", "layer", "output" }
        end
        function api.output()
            return W, H
        end
        function api.create_surface()
            local cap, core = new_surface(pid)
            conn.surfaces[#conn.surfaces + 1] = core
            return cap
        end
        function api.toplevels()
            local out = {}
            for _, w in ipairs(wins) do
                if w.kind == "toplevel" and w.mapped then
                    out[#out + 1] = { id = w.id, title = w.core.title, focused = w.focused, pid = w.core.pid }
                end
            end
            return out
        end
        function api.disconnect()
            capability.revoke(api._mt)
        end
        return api
    end,
    dispose = function(api)
        local conn = api._conn
        connections[conn.pid] = nil
        for _, core in ipairs(conn.surfaces) do
            if core.mt and not core.dead then
                capability.revoke(core.mt)
            end
        end
    end,
})

compositor = compositor or {}

function compositor.connect()
    if not compositor.running then
        error("no compositor running (start it with 'gui')", 2)
    end
    local pid = process_manager.self()
    if connections[pid] then return connections[pid].cap end
    local cap, mt = capability.create("gui_conn", nil, pid)
    connections[pid].cap = cap
    connections[pid].mt = mt
    return cap
end

function compositor.quit() quit() end
function compositor.set_policy(spec) return set_policy(spec) end

function compositor.list()
    local out = {}
    for _, w in ipairs(wins) do
        out[#out + 1] = {
            id = w.id, kind = w.kind, title = w.core.title, x = w.x, y = w.y,
            w = w.core.buf.w, h = w.core.buf.h, mapped = w.mapped, focused = w.focused, pid = w.core.pid,
        }
    end
    return out
end

function compositor.policy_name() return policy and policy.name end

---Repaint everything (debugging / recovery after a corrupted screen).
function compositor.redraw() full_redraw() end

-- ------------------------------------------------------------
--  Start-up / main loop
-- ------------------------------------------------------------

local function load_config()
    config = {}
    for k, v in pairs(DEFAULT_CONFIG) do config[k] = v end
    config.theme = {}
    for k, v in pairs(DEFAULT_CONFIG.theme) do config.theme[k] = v end
    config.binds = {}
    for k, v in pairs(DEFAULT_CONFIG.binds) do config.binds[k] = v end

    local src = fs.read_file("System://Config/gui.lua")
    if src then
        local fn, err = load(src, "@System://Config/gui.lua", "t", _ENV)
        if fn then
            local ok, user = pcall(fn)
            if ok and type(user) == "table" then
                for k, v in pairs(user) do
                    if k == "theme" or k == "binds" then
                        for k2, v2 in pairs(v) do config[k][k2] = v2 end
                    else
                        config[k] = v
                    end
                end
            else
                log.warn("[compositor] gui.lua error: %s", tostring(user))
            end
        else
            log.warn("[compositor] gui.lua syntax error: %s", tostring(err))
        end
    end
    theme = config.theme

    -- canonicalise bind names ("mod+Return" -> "alt+shift+enter")
    local binds = {}
    for spec, action in pairs(config.binds) do
        local name = canonical_bind(spec, config.mod)
        if name then
            binds[name] = action
        else
            log.warn("[compositor] ignoring bind '%s'", tostring(spec))
        end
    end
    config.binds = binds
end

local function acquire_display()
    local g = system.open("display")
    local s = system.open("screen")
    if not g or not s then return false end
    g.bind(s.addr())
    g.set_depth(g.max_depth())
    local nw, nh = g.max_resolution()
    g.set_resolution(nw, nh)
    gpu = g
    W, H = nw, nh
    return true
end

-- Several drag events can pile up while a frame is being drawn; only the
-- latest position matters.
local function coalesce_drags(ev)
    local q = process_manager.current_proc().event_queue
    while q[1] and q[1].type == "drag" do
        ev = table.remove(q, 1)
    end
    return ev
end

local function run()
    load_config()
    local err
    policy, err = load_policy(config.policy)
    if not policy then
        log.warn("[compositor] %s, using floating", tostring(err))
        policy = policies.floating
    end

    if not acquire_display() then
        error("no display available")
    end
    log.info("[compositor] started %dx%d, policy=%s", W, H, tostring(policy.name))

    term.suspend()
    router.grab_input(comp_pid)
    compositor.running = true
    compositor.pid = comp_pid
    recompute_usable()
    full_redraw()

    for _, path in ipairs(config.autostart or {}) do
        spawn(path)
    end

    local interval = 1 / (config.fps or 20)
    while not quit_flag do
        local timeout
        if dirty then
            timeout = math.max(0, last_frame + interval - computer.uptime())
        end
        local ev = event.pull(nil, timeout)
        if ev then
            local t = ev.type
            if t == "key_down" then handle_key(ev, true)
            elseif t == "key_up" then handle_key(ev, false)
            elseif t == "drag" then handle_pointer(coalesce_drags(ev))
            elseif t == "touch" or t == "drop" or t == "scroll" then handle_pointer(ev)
            elseif t == "clipboard" then
                if focused then send(focused.core, "paste", { text = ev.data[3] }) end
            elseif t == "gui_wake" then wake_pending = false
            elseif t == "device_removed" and (ev.nexus_type == "display" or ev.nexus_type == "screen") then
                gpu = nil
            elseif t == "device_added" and (ev.nexus_type == "display" or ev.nexus_type == "screen") then
                if (not gpu or not capability.is_valid(gpu)) and acquire_display() then
                    layout_layers()
                    arrange()
                    full_redraw()
                end
            end
        end
        if dirty and computer.uptime() - last_frame >= interval then
            render_frame()
        end
    end
end

local ok, err = pcall(run)

-- shutdown: always give the console back
compositor.running = false
router.release_input(comp_pid)
for _, conn in pairs(connections) do
    if conn.mt then pcall(capability.revoke, conn.mt) end
end
pcall(term.resume)
if not ok then
    log.error("[compositor] crashed: %s", tostring(err))
else
    log.info("[compositor] stopped")
end
