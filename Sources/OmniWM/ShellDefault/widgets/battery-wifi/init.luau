-- SPDX-License-Identifier: GPL-2.0-only

local look = require("../lib/look")
local battery = require("../lib/battery")
local wifi = require("../lib/wifi")

-- Leave the top quarter of the charge ring open for the four signal dots.
local function point(angle)
    local radians = math.rad(angle)
    return 12 + 10 * math.cos(radians), 12 + 10 * math.sin(radians)
end

local function arc(size, fraction, color)
    local x, y = point(-45)
    local sweep = 270 * fraction
    local endX, endY = point(-45 + sweep)
    return ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 },
        d = string.format("M%.3f %.3f A10 10 0 %d 1 %.3f %.3f", x, y, if sweep > 180 then 1 else 0, endX, endY),
        border = color, borderWidth = size / 12 }
end

local function gauge(size, charge, network)
    local stack = { w = size, h = size }
    if charge then
        stack[#stack + 1] = arc(size, 1, "foreground/0.2")
        if charge.level > 0 then
            local color = if charge.plugged or charge.charging then "success"
                elseif charge.low then "error" else "foreground"
            stack[#stack + 1] = arc(size, math.min(charge.level, 100) / 100, color)
        end
    end
    if network then
        local lit = if network.wired then 4 elseif network.connected and network.rssi then network.level + 1 else 0
        for i = 1, 4 do
            local x, y = point(-135 + i * 18)
            stack[#stack + 1] = ui.box{ w = size / 10, h = size / 10, radius = size / 20,
                dx = (x - 12) * size / 24, dy = (y - 12) * size / 24,
                fill = if i <= lit then "foreground" else "foreground/0.2" }
        end
        stack[#stack + 1] = look.glyph{ name = if network.wired then "network" elseif network.power then "wifi" else "wifi.slash",
            size = size * 0.46, color = if network.wired or network.connected then "foreground" else "secondaryForeground" }
    elseif charge then
        stack[#stack + 1] = look.glyph{ name = charge.symbol, size = size * 0.46 }
    end
    return ui.stack(stack)
end

function render(ctx)
    local charge, network = battery.state(ctx), wifi.state(ctx)
    if not charge and not network then
        return ui.box{ w = 0, h = 0 }
    end
    local labels = {}
    if charge then
        table.insert(labels, charge.help)
    end
    if network then
        table.insert(labels, network.help)
    end
    local glyph = gauge(22 * look.scale(ctx), charge, network)
    return battery.animateBar(look.bar(ctx, { onClick = ui.popout, help = table.concat(labels, " · "),
        battery.withMode(ctx, charge, glyph) }))
end

function popout(ctx)
    local charge, network = battery.model(ctx), wifi.model(ctx)
    if not charge and not network then
        return ui.box{ w = 0, h = 0 }
    end
    local panel = { w = look.width + 28, ui.row{ w = look.width, gauge(44, charge, network) } }
    if charge then
        panel[#panel + 1] = battery.content(ctx, look.width, charge)
    end
    if network then
        panel[#panel + 1] = wifi.content(ctx, look.width, network)
    end
    return look.panel(ctx, panel)
end
