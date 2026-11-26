-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("./look")
local actions = require("./actions")

local effects = require("./effects")
local resize = { duration = 0.24, curve = "easeInOut" }

local battery = { boltContrastLevel = 55 }

local modeSymbols = { low = "leaf.fill", high = "chevron.up.2" }

local function modeLabel(mode)
    if mode == "low" then return omniwm.l10n("Low Power Mode") end
    if mode == "high" then return omniwm.l10n("High Power Mode") end
    if mode == "automatic" then return omniwm.l10n("Automatic Power Mode") end
    return nil
end

function battery.modeGlyph(symbol, size, color)
    return ui.symbol(effects.motion("pop", { key = symbol, name = symbol, size = size, color = color, weight = "semibold" }))
end

function battery.withMode(ctx, state, glyph)
    local scale = look.scale(ctx)
    local items = { key = "battery-gauge", gap = 2 * scale, animate = resize, glyph }
    local symbol = state and modeSymbols[state.activeMode]
    if symbol then
        items[2] = battery.modeGlyph(symbol, 11 * scale, if state.activeMode == "low" then "yellow" else "purple")
    end
    return if ctx.data.bar.style.vertical then ui.column(items) else ui.row(items)
end

function battery.animateBar(button)
    button.animate = resize
    for _, child in ipairs(button) do
        child.animate = child.animate or resize
    end
    return button
end

local function tint(level: number, charging: boolean): string
    if charging then
        return "success"
    end
    if level <= 10 then
        return "error"
    end
    return if level <= 20 then "warning" else "foreground"
end

local function duration(minutes: number): string
    return omniwm.l10n("%lldh %lldm", minutes // 60, minutes % 60)
end

function battery.state(ctx)
    local level = ctx.data.battery
    if not level then
        return nil
    end
    local charging = ctx.data.charging == true
    local power = ctx.data.power or {}
    local activeMode = power.mode or (if power.lowPower then "low" else nil)
    local percent = ctx.format.percent(level / 100)
    local label = modeLabel(activeMode)
    local help = omniwm.l10n("Battery") .. " " .. percent
    local plugged = power.source == "ac"
    return { level = level, charging = charging, plugged = plugged, low = level <= 20 and not charging,
        tint = tint(level, charging), symbol = look.batterySymbol(level, charging or plugged), text = tostring(level),
        percent = percent, activeMode = activeMode, help = if label then help .. " · " .. label else help,
        reserve = ctx.format.percent(1),
        mode = (ctx.data.settings or {}).percent or "beside" }
end

function battery.model(ctx)
    local m = battery.state(ctx)
    if not m then
        return nil
    end
    local power = ctx.data.power or {}
    m.status = if power.charged then omniwm.l10n("Fully charged")
        elseif m.charging then omniwm.l10n("Charging")
        elseif power.source == "ac" then omniwm.l10n("Not charging")
        else omniwm.l10n("On battery")
    m.details = {}
    if power.source then
        m.details[#m.details + 1] = { label = omniwm.l10n("Power Source"),
            value = if power.source == "ac" then omniwm.l10n("Power Adapter") else omniwm.l10n("Battery") }
    end
    if not m.charging and power.remaining then
        m.details[#m.details + 1] = { label = omniwm.l10n("Time Remaining"), value = duration(power.remaining) }
    elseif m.charging and power.full then
        m.details[#m.details + 1] = { label = omniwm.l10n("Time to Full"), value = duration(power.full) }
    end
    m.powerMode = power.mode
    m.supportsHighPower = power.supportsHighPower
    if not m.powerMode and power.lowPower ~= nil then
        m.details[#m.details + 1] = { label = omniwm.l10n("Low Power Mode"),
            symbol = modeSymbols[m.activeMode], value = if power.lowPower then omniwm.l10n("On") else omniwm.l10n("Off") }
    end
    m.settings = "battery settings"
    return m
end

function battery.cell(state, w: number, h: number, inside: string?)
    local body = { w = w, h = h, radius = h * 0.3, border = "foreground/0.45", borderWidth = 1,
        ui.box{ align = "leading", dx = 2, w = math.max(1.5, (w - 4) * state.level / 100), h = h - 4,
            radius = (h - 4) * 0.3, fill = if inside then state.tint .. "/0.22" else state.tint } }
    if inside then
        body[#body + 1] = look.text{ text = inside, size = h * 0.72, weight = "semibold" }
    elseif state.charging or state.plugged then
        body[#body + 1] = look.glyph{ name = "bolt.fill", size = h * 0.78,
            color = if state.level >= battery.boltContrastLevel then "background" else "foreground" }
    end
    return ui.row{ gap = 1,
        ui.stack(body),
        ui.box{ w = math.max(1.5, h * 0.14), h = h * 0.4, radius = h * 0.07, fill = "foreground/0.45" } }
end

function battery.modeSelector(m, width)
    local options = { { "automatic", omniwm.l10n("Automatic") }, { "low", omniwm.l10n("Low") } }
    if m.supportsHighPower then
        table.insert(options, { "high", omniwm.l10n("High") })
    end
    local row = { w = width, gap = 4 }
    for _, option in options do
        local selected = m.powerMode == option[1]
        local props = { key = option[1], animate = resize, grow = 1, pad = 5, gap = 3, radius = look.radius(6),
            fill = if selected then "accent" else "surface", hover = look.hover,
            onClick = "battery mode " .. option[1] }
        if selected and modeSymbols[m.powerMode] then
            props[#props + 1] = battery.modeGlyph(modeSymbols[m.powerMode], 11, "accentForeground")
        end
        props[#props + 1] = look.text{ key = "label", animate = resize, text = option[2], size = 12, color = if selected then "accentForeground" else "foreground" }
        row[#row + 1] = ui.row(props)
    end
    return ui.column{ w = width, gap = 5, center = false,
        look.text{ text = omniwm.l10n("Power Mode"), size = 13, weight = "medium" }, ui.row(row) }
end

function battery.content(ctx, width: number?, m)
    width = width or look.width
    m = m or battery.model(ctx)
    if not m then
        return actions.notice(omniwm.l10n("Unavailable"), width)
    end
    local rows = { w = width, gap = 12, center = false,
        look.group{ w = width,
            ui.row{ w = width - 24, gap = 16,
                battery.cell(m, 58, 28),
                ui.column{ gap = 3, center = false,
                    look.text{ text = m.percent, size = 28, weight = "medium" },
                    look.text{ text = m.status, size = 13, color = "secondaryForeground", maxWidth = width - 108 } } } } }
    if #m.details > 0 then
        local details = { w = width }
        for _, detail in m.details do
            details[#details + 1] = ui.row{ w = width - 24, gap = 8, animate = resize,
                look.text{ text = detail.label, size = 13, color = "secondaryForeground", grow = 1, maxWidth = 170 },
                look.text{ text = detail.value, size = 13, weight = "medium", maxWidth = 118, animate = resize },
                if detail.symbol then battery.modeGlyph(detail.symbol, 11, "yellow") else nil }
        end
        rows[#rows + 1] = look.group(details)
    end
    if m.powerMode then
        rows[#rows + 1] = battery.modeSelector(m, width)
    end
    rows[#rows + 1] = actions.row("gearshape", omniwm.l10n("Battery Settings…"), m.settings, width)
    return ui.column(rows)
end

function battery.background(m)
    if not m or not modeSymbols[m.activeMode] then return nil end
    local low = m.activeMode == "low"
    return ui.shader{ key = "hyperspace", source = "battery-hyperspace.metal", decorative = true,
        values = { if low then 1 else 0 }, fps = if low then 8 else 30, animateInLowPower = low }
end

function battery.popout(ctx)
    local m = battery.model(ctx)
    return look.batteryPanel and look.batteryPanel(ctx, m)
        or look.panel(ctx, { w = look.width + 28, backgroundShader = battery.background(m),
            look.heading(omniwm.l10n("Battery"), look.width), battery.content(ctx, nil, m) })
end

return table.freeze(battery)
