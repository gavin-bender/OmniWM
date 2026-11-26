-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")
local media = require("../lib/media")

function render(ctx)
    local m = media.state(ctx)
    if not m then
        return ui.box{ w = 0, h = 0 }
    end
    local behaviour = { onClick = ui.popout, onRightClick = m.toggle, help = m.help }
    local button = look.mediaBar and look.mediaBar(ctx, m)
    if not button then
        local scale = look.scale(ctx)
        local props = table.clone(behaviour)
        local style = ctx.data.bar.style
        local resize = if style.vertical then nil else { duration = 0.24, curve = "easeInOut" }
        props.animate = resize
        local artwork = ctx.select("media", "artwork")
        local height = 18 * scale
        local ratio = ctx.select("media", "artworkAspectRatio") or 1
        local width = height * math.clamp(ratio, 0.6, if style.vertical then 1 else 16 / 9)
        local art = if artwork then ui.image{ key = "artwork", image = artwork, w = width, h = height, radius = 4 * scale }
            else ui.icon{ app = ctx.select("media", "bundle"), w = height, h = height, placeholder = "music.note" }
        props[1] = ui.stack{ key = "cover", w = if style.vertical then height else height * 16 / 9, h = height, art }
        if not style.vertical then
            local summary = ctx.select("media", "compactTitle")
            local title = summary or media.fittingTitle(ctx, m.title, ctx.select("media", "musicTitle"),
                160 * scale, 13 * scale, "medium")
            props[#props + 1] = ui.stack{ key = "caption", h = height, animate = resize,
                look.text{ key = if summary then "summary" else "original", text = title,
                    size = 13 * scale, weight = "medium", maxWidth = 160 * scale, align = "leading",
                    appear = if summary then { opacity = 0, scale = 0.97, dy = 3 * scale, animate = 0.24 } else nil,
                    exit = { opacity = 0, dy = -2 * scale, animate = 0.13 } } }
        end
        local slot = look.px(ctx, "barSymbol")
        props[#props + 1] = ui.stack{ key = "playback", w = slot, h = slot, animate = resize,
            onClick = m.toggle, onRightClick = m.toggle, cursor = "pointer",
            help = if m.playing then omniwm.l10n("Pause") else omniwm.l10n("Resume"),
            if m.playing then ui.shader{ key = "waveform", source = "media-waveform.metal",
                fps = 24, w = slot, h = slot }
            else look.barGlyph(ctx, { name = "play.fill", size = slot, color = "secondaryForeground" }) }
        button = look.bar(ctx, props)
        if style.backgrounds then
            button.radius = (style.height - 4) / 2
            button.fill = "surface"
            button.border = "border"
            button.borderWidth = 0.5
        end
    end
    for key, value in behaviour do
        button[key] = value
    end
    return button
end

function popout(ctx)
    local m = media.model(ctx)
    return look.mediaPanel and look.mediaPanel(ctx, m)
        or look.panel(ctx, { w = look.width + 28, look.heading(omniwm.l10n("Media")), media.content(ctx, false, nil, m) })
end
