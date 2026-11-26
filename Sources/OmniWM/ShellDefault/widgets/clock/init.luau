-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")
local calendar = require("../lib/calendar")

local stats = require("../lib/stats")
local actions = require("../lib/actions")

interval = 60
local motion = { duration = 0.24, curve = "easeInOut" }
local tint = "#67DDB2"

local function eventsHidden(ctx)
    if ctx.state.eventsHidden == nil then
        ctx.state.eventsHidden = omniwm.store.get("eventsHidden") == true
    end
    return ctx.state.eventsHidden
end

local function toggleEvents(ctx)
    ctx.state.eventsHidden = not eventsHidden(ctx)
    omniwm.store.set("eventsHidden", ctx.state.eventsHidden)
end

local function duration(seconds)
    local minutes = math.ceil(seconds / 60)
    return if minutes < 60 then omniwm.l10n("%lldm", minutes)
        else omniwm.l10n("%lldh %lldm", math.floor(minutes / 60), minutes % 60)
end

local function localDay(ctx, seconds)
    local offsetSeconds = ctx.format.offset(seconds) or 0
    return math.floor((seconds + offsetSeconds) / 86400)
end

local function upcomingLabel(ctx, event, now)
    local remaining = event.start - now
    if remaining <= 2 * 3600 then return omniwm.l10n("in %@", duration(remaining)) end

    local time = event.time
    local spaced = string.gsub(time, "%s", "")
    spaced = string.gsub(spaced, "\u{202F}", "")
    spaced = string.gsub(spaced, "\u{00A0}", "")
    local hour, minute, period = string.match(spaced, "^(%d+):(%d%d)([AaPp][Mm])$")
    if hour then
        time = hour .. (if minute == "00" then "" else ":" .. minute) .. string.lower(period)
    end
    local days = localDay(ctx, event.start) - localDay(ctx, now)
    if days == 0 then return omniwm.l10n("at %@", time) end
    if days == 1 then return omniwm.l10n("tmrw at %@", time) end
    return omniwm.l10n("%@ at %@", ctx.format.date(event.start, "EEE") or event.day, time)
end

local function fittingTitle(ctx, event, slot, size, width, scale)
    local font = { size = size }
    if ctx.format.measure(event.title, font) <= width then return event.title end
    if event.compactTitle and ctx.format.measure(event.compactTitle, font) <= width then return event.compactTitle end

    -- Ask once per visible title and width, then retry transient model unavailability after five minutes.
    local budget = math.max(1, math.floor(width / scale) - 1)
    local previous = ctx.state[slot]
    local now = ctx.data.seconds
    if not previous or previous.id ~= event.id or previous.title ~= event.title
        or previous.budget > budget or math.abs(now - previous.requested) >= 300 then
        local id = event.id
        local timer = omniwm.after(0.01, function()
            omniwm.run("calendar fit-title " .. budget .. " " .. id)
        end)
        if timer then
            ctx.state[slot] = { id = id, title = event.title, budget = budget, requested = now }
        end
    end
    return event.title
end

local function eventRows(ctx, scale)
    if eventsHidden(ctx) then return nil end
    local data = ctx.data.calendar
    if not data or data.access ~= "full" or #data.events == 0 then return nil end
    local now = ctx.data.seconds
    local current, upcoming
    for _, event in data.events do
        if not event.allDay and event["end"] > now and event["end"] > event.start then
            if event.start > now then
                upcoming = event
                break
            end
            current = event
        end
    end
    if not current and not upcoming then return nil end

    local rows = { key = "events", gap = 0, center = false, animate = motion,
        appear = { opacity = 0, dx = -3 * scale, animate = motion },
        exit = { opacity = 0, animate = 0.14 } }
    local rowProps = {}
    local sharedWidth = 0
    local function add(event, marker, label, active)
        local size = 10 * scale
        local labelWidth = math.ceil(ctx.format.measure(label, { size = size, weight = "medium" }))
        local overhead = (if current and upcoming then 19 else 16) * scale
        -- Let longer start-time labels widen the row before they squeeze a short event name.
        local width = math.clamp(96 * scale + labelWidth + overhead, 146 * scale, 192 * scale)
        local titleWidth = math.max(1, width - labelWidth - overhead)
        local slot = if active then "current" else "next"
        local title = fittingTitle(ctx, event, slot, size, titleWidth, scale)
        local row = { key = slot, gap = 3 * scale,
            marker, look.text{ text = title, help = event.title, size = size, color = if active then "foreground" else "secondaryForeground",
                maxWidth = titleWidth } }
        if current and upcoming then
            local measuredTitle = math.min(titleWidth, math.ceil(ctx.format.measure(title, { size = size })))
            sharedWidth = math.max(sharedWidth, measuredTitle + labelWidth + overhead)
            row[#row + 1] = ui.box{ grow = 1, h = 1 }
        end
        row[#row + 1] = look.text{ text = label, size = size, weight = "medium",
            color = if active then tint else "secondaryForeground" }
        rowProps[#rowProps + 1] = row
    end
    if current then
        local elapsed = (now - current.start) / (current["end"] - current.start)
        add(current, stats.gauge(elapsed * 100, 10 * scale, tint),
            omniwm.l10n("%@ left", duration(current["end"] - now)), true)
    end
    if upcoming then
        add(upcoming, look.glyph{ name = "arrow.turn.down.right", size = 9 * scale, w = 10 * scale, color = "secondaryForeground" },
            upcomingLabel(ctx, upcoming, now), false)
    end
    for _, row in rowProps do
        if #rowProps == 2 then row.w = sharedWidth end
        rows[#rows + 1] = ui.row(row)
    end
    return ui.column(rows)
end

local function parts(ctx)
    local data = ctx.data
    local hour, minute, meridiem = string.match(string.gsub(data.clock, "\u{202F}", " "), "^(%d+)[:.](%d%d)%s*(%a*)$")
    if not hour then
        hour, minute, meridiem = os.date("%H"), os.date("%M"), ""
    end
    return { time = data.clock, date = data.date, hour = string.format("%02d", tonumber(hour)), minute = minute,
        meridiem = if meridiem ~= "" then string.lower(meridiem) else nil,
        showDate = ctx.select("settings", "date") ~= false, showIcon = ctx.select("settings", "icon") == true }
end

function render(ctx)
    local m = parts(ctx)
    local click = look.clockClick
    local behaviour = { onClick = click or ui.popout, onRightClick = if click then ui.popout else nil }
    local button = look.clockBar and look.clockBar(ctx, m)
    if not button then
        local scale = look.scale(ctx)
        local props = table.clone(behaviour)
        if ctx.data.bar.style.vertical then
            props.gap = 0
            props.pad = 2 * scale
            if m.showIcon then
                props[#props + 1] = look.glyph{ name = "calendar", size = 12 * scale }
            end
            props[#props + 1] = look.text{ text = m.hour, size = 11 * scale, weight = "medium" }
            props[#props + 1] = look.text{ text = m.minute, size = 11 * scale }
            if m.meridiem then
                props[#props + 1] = look.text{ text = m.meridiem, size = 9 * scale, color = "secondaryForeground" }
            end
        else
            props.gap = 8 * scale
            local events = eventRows(ctx, scale)
            props.animate = motion
            local clock = { key = "date-time", center = false, gap = if events then 0 else 8 * scale, animate = motion }
            if m.showDate then
                clock[#clock + 1] = look.text{ key = "date", text = m.date, size = (if events then 10 else 13) * scale,
                    color = "secondaryForeground" }
            end
            local time = look.text{ key = "time", text = m.time, size = 13 * scale,
                weight = if events then "semibold" else "medium", reserve = "00:00 PM" }
            local focus = ctx.data.focusSymbol
            clock[#clock + 1] = if focus then ui.row{ key = "focus-time", gap = 3 * scale,
                look.glyph{ key = "focus-mode", name = focus, size = 11 * scale }, time } else time
            if events then
                props.pad = 0
                props.gap = 5 * scale
                props[#props + 1] = events
                props[#props + 1] = ui.box{ key = "divider", w = scale, h = 20 * scale, fill = "foreground/0.18" }
            end
            if m.showIcon then
                props[#props + 1] = look.barGlyph(ctx, { name = "calendar" })
            end
            props[#props + 1] = if events then ui.column(clock) else ui.row(clock)
        end
        button = look.bar(ctx, props)
    end
    for key, value in behaviour do
        button[key] = value
    end
    return button
end

function popout(ctx)
    if look.clockBar then return calendar.popout(ctx) end
    if ctx.state.choosingFocus then
        local rows = { actions.row("chevron.left", omniwm.l10n("Back"), function(ctx)
            ctx.state.choosingFocus = false
        end, look.width, true) }
        local modes = ctx.data.focusModes or {}
        for _, mode in modes do
            local row = actions.row(mode.symbol, mode.name,
                "focus " .. (if mode.active then "disable " else "enable ") .. mode.id, look.width, true)
            if mode.active then
                row[#row + 1] = ui.box{ grow = 1, h = 1 }
                row[#row + 1] = look.glyph{ name = "checkmark", size = 12, color = "accent" }
            end
            rows[#rows + 1] = row
        end
        rows[#rows + 1] = actions.row("gearshape", omniwm.l10n("Focus Settings…"), "focus settings", look.width, true)
        return look.panel(ctx, rows)
    end
    local rows = { calendar.content(ctx) }
    if not ctx.data.bar.style.vertical then
        local hidden = eventsHidden(ctx)
        rows[#rows + 1] = actions.row(if hidden then "eye" else "eye.slash",
            if hidden then omniwm.l10n("Show upcoming events") else omniwm.l10n("Hide upcoming events"),
            toggleEvents, look.width, true)
    end
    rows[#rows + 1] = actions.row(ctx.data.focusSymbol or "moon.fill", omniwm.l10n("Focus"), function(ctx)
        ctx.state.choosingFocus = true
    end, look.width, true)
    return look.panel(ctx, rows)
end
