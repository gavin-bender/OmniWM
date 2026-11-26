-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
interval = 1

local look = require("../lib/look")
local stats = require("../lib/stats")
local notion = require("@self/notion")
local timer = require("@self/timer")
local motion = { duration = 0.24, curve = "easeInOut" }
local appear = { opacity = 0, scale = 0.97, dy = 3, animate = 0.20 }
local exit = { opacity = 0, scale = 0.97, dy = -2, animate = 0.14 }

local function animated(key, element)
    element.key, element.animate, element.appear, element.exit = key, motion, appear, exit
    return element
end

local function button(key, title, action, width, selected)
    return animated(key, ui.stack{ w = width, h = 27, radius = 9, hover = look.hover,
        fill = if selected then "accent" else "surface", onClick = action, help = title,
        animated(title, look.text{ text = title, size = 12, color = if selected then "accentForeground" else "foreground" }) })
end

local function totals(rows)
    local done = 0
    for _, task in rows or {} do if task.checked then done += 1 end end
    return done, if rows then #rows else 0
end

local function clock(seconds)
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function trigger(ctx, event)
    if event.source == "host" and event.name == "reloaded" then
        timer.restore()
        notion.start(ctx)
    elseif event.name == "status" then
        local rows, message = notion.snapshot(ctx)
        local done, count = totals(rows)
        omniwm.log("Productivity sync", message or string.format("%d of %d done", done, count))
    end
end

function render(ctx)
    local rows = notion.snapshot(ctx)
    local done, count = totals(rows)
    local record, seconds = timer.read(ctx)
    local scale = look.scale(ctx)
    local props = { key = "productivity", animate = motion, help = omniwm.l10n("Productivity"), onClick = ui.popout,
        if rows then animated("progress", stats.gauge(if count > 0 then 100 * done / count else 0, 15 * scale, "accent"))
        else animated("checklist", look.glyph{ name = "checklist", size = 15 * scale }) }
    if not ctx.data.bar.style.vertical then
        if rows then table.insert(props, animated("tasks", look.text{ text = done .. "/" .. count, size = 13 * scale })) end
        if record.deadline or record.remaining then
            if record.mode == "Pomodoro" and record.phase ~= "Focus" then
                table.insert(props, animated("break", look.glyph{ name = "cup.and.saucer", size = 12 * scale }))
            end
            table.insert(props, animated("countdown", look.text{ text = clock(seconds), reserve = "180:00",
                size = 12 * scale, style = "mono" }))
            if record.remaining then table.insert(props, animated("paused", look.glyph{ name = "pause.fill", size = 10 * scale })) end
        end
    end
    return look.bar(ctx, props)
end

local function tasks(ctx)
    local rows, message, busy = notion.snapshot(ctx)
    local done, count = totals(rows)
    local list = { gap = 4, center = false,
        ui.row{ w = 284, gap = 8, look.text{ text = omniwm.l10n("Today in Notion"), size = 14, weight = "semibold" },
            ui.box{ grow = 1 }, rows and look.text{ text = omniwm.l10n("%lld of %lld done", done, count), size = 11 } or ui.box{ w = 0 },
            ui.box{ pad = 4, radius = 5, hover = look.hover, help = omniwm.l10n("Refresh checklist"), onClick = notion.refresh,
                look.glyph{ name = "arrow.clockwise", size = 12 } } } }
    if count > 0 then
        table.insert(list, animated("progress", ui.stack{ w = 284, h = 4, radius = 2, fill = "border",
            ui.box{ align = "leading", w = 284 * done / count, h = 4, radius = 2, fill = "accent", animate = motion } }))
        local pages = math.ceil(count / 5)
        local page = math.clamp(ctx.state.taskPage or 1, 1, pages)
        for index = 5 * page - 4, math.min(5 * page, count) do
            local task = rows[index]
            table.insert(list, animated(task.id, ui.row{ gap = 7, h = 22, hover = look.hover, radius = 4,
                help = task.title, opacity = if busy then 0.65 else 1,
                onClick = function(next) notion.toggle(next, task) end,
                animated(tostring(task.checked), look.glyph{ name = if task.checked then "checkmark.square.fill" else "square", color = if task.checked then "accent" else "secondaryForeground", size = 14 }),
                look.text{ text = task.title, maxWidth = 254, size = 13, role = if task.checked then "secondary" else nil } }))
        end
        if pages > 1 then
            table.insert(list, animated("pages", ui.row{ gap = 8,
                button("prev", "‹", function(next) next.state.taskPage = math.max(1, page - 1) end, 30),
                look.text{ text = page .. " / " .. pages, size = 11 },
                button("next", "›", function(next) next.state.taskPage = math.min(pages, page + 1) end, 30) }))
        end
    elseif rows and not message then message = omniwm.l10n("No checkboxes on this page.") end
    if message then table.insert(list, animated(message, look.text{ text = message, size = 12, role = "secondary", maxWidth = 284, lines = 2 })) end
    return animated("notion", ui.column(list))
end

local function timerControls(ctx)
    local record, seconds = timer.read(ctx)
    local pomo = record.mode == "Pomodoro"
    local label = if record.deadline then omniwm.l10n("Pause") elseif record.remaining then omniwm.l10n("Resume") else omniwm.l10n("Start")
    local phaseName = if record.phase == "Focus" then omniwm.l10n("Focus") elseif record.phase == "Break" then omniwm.l10n("Break") else omniwm.l10n("Long break")
    local phase = if pomo then omniwm.l10n("%@ · Round %lld of 4", phaseName, record.round)
        elseif record.done then omniwm.l10n("Timer complete") else omniwm.l10n("Countdown")
    return animated("timer", ui.column{ gap = 7, center = false,
        ui.row{ gap = 4, button("pomodoro", omniwm.l10n("Pomodoro"), function() timer.mode("Pomodoro") end, 140, pomo),
            button("standard", omniwm.l10n("Timer"), function() timer.mode("Timer") end, 140, not pomo) },
        animated(phase, look.text{ text = phase, size = 11, role = "secondary" }),
        ui.row{ w = 284, look.text{ text = clock(if record.done then 0 else seconds), size = 36, style = "mono", weight = "medium" },
            ui.box{ grow = 1 }, button("action", label, timer.toggle, 72, true) } })
end

local function radio(ctx)
    local playingStation = string.lower(ctx.select("media", "bundle") or "") == "com.sertacozercan.kaset"
        and string.find(string.lower(ctx.select("media", "title") or ""), "lofi hip hop radio", 1, true) ~= nil
    local pause = playingStation and ctx.select("media", "playing") == true
    local function play(next)
        next.state.radioError = nil
        if playingStation then omniwm.run("media toggle"); return end
        local handle = omniwm.open("kaset://play?v=rFZHOHl-L8A", function(result)
            if not result.ok then next.state.radioError = omniwm.l10n("Couldn’t open Kaset.") end
        end)
        if not handle then next.state.radioError = omniwm.l10n("Couldn’t open Kaset.") end
    end
    return animated("radio", ui.row{ w = 284, gap = 9, pad = 8, radius = 10, fill = "surface", onClick = play,
        look.glyph{ name = "radio", size = 16 }, ui.column{ gap = 2, center = false,
            look.text{ text = omniwm.l10n("Lofi hip hop radio"), size = 13, weight = "medium" },
            look.text{ text = ctx.state.radioError or "Kaset", size = 11, color = if ctx.state.radioError then "error" else "secondaryForeground" } },
        ui.box{ grow = 1 }, animated(if pause then "pause" else "play", look.glyph{ name = if pause then "pause.fill" else "play.fill", size = 13 }) })
end

function popout(ctx)
    return animated("panel", look.panel(ctx, { w = 318, pad = 17, gap = 12, fill = "background/0.90", enter = { opacity = 0, dy = -4, scale = 0.98 },
        animated("title", look.heading(omniwm.l10n("Productivity"))), tasks(ctx), timerControls(ctx), radio(ctx) }))
end
